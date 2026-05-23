#!/usr/bin/env bash
set -euo pipefail

# Idempotent restorer for the spark-ai stack.
# Safe to run any time: inspects each component, restarts only what's broken,
# cascades a vLLM restart to socat + gateway (because vLLM owns the nim_net
# network and 172.18.0.1 host interface).
#
# Stack (bottom-up):
#   vLLM (vllm-qwen3-coder-next)  ── creates nim_net + 172.18.0.1
#   argo-shim (127.0.0.1:44497)   ── self-manages its own ssh tunnel
#   socat   (172.18.0.1:44497 → 127.0.0.1:44497)
#   OpenClaw gateway (port 18789, talks to vLLM via nim_net, Argo via socat)
#
# Each ensure_X function does a DEEP health check (end-to-end curl through the
# layer) — not just "is the process listening".

SPARK_AI_DIR="$HOME/code/spark-ai"
ARGO_SHIM_LOG="$SPARK_AI_DIR/argo-shim.log"
SOCAT_LOG="$SPARK_AI_DIR/socat-bridge.log"
BRIDGE_IP="172.18.0.1"
ARGO_PORT="44497"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[…]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# Track whether vLLM was (re)started this run — drives cascade to socat+gateway
VLLM_RESTARTED=false

# ── Helpers ─────────────────────────────────────────────────────────────

wait_for() {
    # wait_for "<description>" <max_seconds> <command...>
    # Returns 0 when command succeeds, 1 on timeout.
    local desc=$1 max=$2
    shift 2
    local elapsed=0
    while [ "$elapsed" -lt "$max" ]; do
        if "$@" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        elapsed=$((elapsed + 2))
        printf "\r${YELLOW}[…]${NC} %s — %ds/%ds..." "$desc" "$elapsed" "$max"
    done
    echo ""
    return 1
}

# Curl Argo via a given host:port. Proves the shim accepts our model name and
# returns a 200 — catches "process up but rejecting requests" bugs.
argo_curl_ok() {
    local url=$1
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 \
        -X POST "${url}/v1/messages" \
        -H "Content-Type: application/json" \
        -d '{"model":"claudesonnet46","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null || echo "000")
    [ "$code" = "200" ]
}

vllm_health_ok() {
    local ip
    ip=$(docker inspect vllm-qwen3-coder-next \
        --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null) || return 1
    [ -n "$ip" ] || return 1
    curl -sf --max-time 5 "http://${ip}:8000/health" >/dev/null
}

gateway_health_ok() {
    # Gateway publishes 18789 on the Tailscale IP only. Easiest sanity check:
    # container is running AND it can reach Argo via socat from inside.
    docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$' || return 1
    docker exec openclaw-gateway curl -sS -o /dev/null -w '%{http_code}' \
        --max-time 8 "http://${BRIDGE_IP}:${ARGO_PORT}/v1/messages" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"model":"claudesonnet46","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
        2>/dev/null | grep -q '^200$'
}

# ── 1. vLLM ─────────────────────────────────────────────────────────────

ensure_vllm() {
    echo ""
    echo "=== vLLM Qwen server ==="

    if docker ps --format '{{.Names}}' | grep -q '^vllm-qwen3-coder-next$' && vllm_health_ok; then
        info "vLLM healthy (container running, /health OK)"
        return
    fi

    if docker ps --format '{{.Names}}' | grep -q '^vllm-qwen3-coder-next$'; then
        warn "vLLM container running but /health failed — restarting"
        docker compose -f "$SPARK_AI_DIR/qwen3-coder-next/docker-compose.yml" restart \
            || fail "Failed to restart vLLM container"
    else
        warn "Starting vLLM container..."
        docker compose -f "$SPARK_AI_DIR/qwen3-coder-next/docker-compose.yml" up -d \
            || fail "Failed to start vLLM container"
    fi
    VLLM_RESTARTED=true

    if wait_for "vLLM loading model (can take ~2 min)" 300 vllm_health_ok; then
        echo ""
        info "vLLM ready"
    else
        echo "Last 20 lines of vLLM logs:"
        docker logs vllm-qwen3-coder-next --tail 20 2>&1
        fail "vLLM did not become healthy within 300s"
    fi
}

# ── 2. argo-shim ────────────────────────────────────────────────────────

ensure_argo_shim() {
    echo ""
    echo "=== argo-shim (127.0.0.1:${ARGO_PORT}) ==="

    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${ARGO_PORT} " \
        && argo_curl_ok "http://127.0.0.1:${ARGO_PORT}"; then
        info "argo-shim healthy (listening, claudesonnet46 returns 200)"
        return
    fi

    # Listener present but unhealthy → kill it; otherwise just start.
    if ss -tlnp 2>/dev/null | grep -q "127.0.0.1:${ARGO_PORT} "; then
        warn "argo-shim listening but failing health check — restarting"
        pkill -f "argo-shim --port ${ARGO_PORT}" 2>/dev/null || true
        sleep 1
    fi

    if ! command -v argo-shim >/dev/null 2>&1; then
        fail "argo-shim not found on PATH (~/.local/bin/argo-shim)"
    fi

    warn "Starting argo-shim..."
    nohup argo-shim --port "${ARGO_PORT}" --no-auth >> "$ARGO_SHIM_LOG" 2>&1 &
    disown || true

    if wait_for "argo-shim warming up (incl. ssh tunnel)" 60 \
        argo_curl_ok "http://127.0.0.1:${ARGO_PORT}"; then
        echo ""
        info "argo-shim ready"
    else
        echo "Last 20 lines of $ARGO_SHIM_LOG:"
        tail -20 "$ARGO_SHIM_LOG" 2>&1 || true
        fail "argo-shim did not become healthy within 60s"
    fi
}

# ── 3. socat bridge ─────────────────────────────────────────────────────

ensure_socat() {
    echo ""
    echo "=== socat bridge (${BRIDGE_IP}:${ARGO_PORT} -> 127.0.0.1:${ARGO_PORT}) ==="

    # Cascade: if vLLM restarted, nim_net + 172.18.0.1 were recreated, so any
    # existing socat is bound to a stale interface. Kill and restart.
    if $VLLM_RESTARTED; then
        if pgrep -f "TCP-LISTEN:${ARGO_PORT},bind=${BRIDGE_IP}" >/dev/null; then
            warn "vLLM was restarted — killing stale socat bound to old ${BRIDGE_IP}"
            pkill -f "TCP-LISTEN:${ARGO_PORT},bind=${BRIDGE_IP}" 2>/dev/null || true
            sleep 1
        fi
    fi

    if ss -tlnp 2>/dev/null | grep -q "${BRIDGE_IP}:${ARGO_PORT} " \
        && argo_curl_ok "http://${BRIDGE_IP}:${ARGO_PORT}"; then
        info "socat bridge healthy (listening, claudesonnet46 returns 200)"
        return
    fi

    if ss -tlnp 2>/dev/null | grep -q "${BRIDGE_IP}:${ARGO_PORT} "; then
        warn "socat listening but health failed — restarting"
        pkill -f "TCP-LISTEN:${ARGO_PORT},bind=${BRIDGE_IP}" 2>/dev/null || true
        sleep 1
    fi

    # Bridge IP exists only after vLLM/nim_net is up
    if ! ip -4 addr | grep -q "inet ${BRIDGE_IP}/"; then
        if ! wait_for "waiting for ${BRIDGE_IP} (nim_net bridge)" 30 \
            sh -c "ip -4 addr | grep -q 'inet ${BRIDGE_IP}/'"; then
            fail "${BRIDGE_IP} never appeared — is vLLM up?"
        fi
        echo ""
    fi

    warn "Starting socat bridge..."
    nohup socat \
        "TCP-LISTEN:${ARGO_PORT},bind=${BRIDGE_IP},reuseaddr,fork" \
        "TCP:127.0.0.1:${ARGO_PORT}" \
        >> "$SOCAT_LOG" 2>&1 &
    disown || true

    if wait_for "socat warming up" 15 \
        argo_curl_ok "http://${BRIDGE_IP}:${ARGO_PORT}"; then
        echo ""
        info "socat bridge ready"
    else
        echo "Last 20 lines of $SOCAT_LOG:"
        tail -20 "$SOCAT_LOG" 2>&1 || true
        fail "socat bridge did not become healthy within 15s"
    fi
}

# ── 4. OpenClaw gateway ─────────────────────────────────────────────────

ensure_gateway() {
    echo ""
    echo "=== OpenClaw gateway ==="

    # Cascade: vLLM restart → nim_net recreated → gateway lost its network
    if $VLLM_RESTARTED; then
        warn "vLLM was restarted — restarting gateway to rejoin nim_net"
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" restart \
            >/dev/null 2>&1 || \
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" up -d \
            || fail "Failed to (re)start gateway"
    elif docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$' && gateway_health_ok; then
        info "gateway healthy (container running, can reach Argo via socat)"
        return
    elif docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$'; then
        warn "gateway container up but health failed — restarting"
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" restart \
            || fail "Failed to restart gateway"
    else
        warn "Starting gateway..."
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" up -d \
            || fail "Failed to start gateway"
    fi

    if wait_for "gateway warming up" 60 gateway_health_ok; then
        echo ""
        info "gateway ready"
    else
        echo "Last 20 lines of gateway logs:"
        docker logs openclaw-gateway --tail 20 2>&1
        fail "gateway did not become healthy within 60s"
    fi
}

# ── Main ────────────────────────────────────────────────────────────────

ensure_vllm
ensure_argo_shim
ensure_socat
ensure_gateway

echo ""
echo "=== All services healthy ==="
info "vLLM Qwen server: running (internal port 8000)"
info "argo-shim:        running (127.0.0.1:${ARGO_PORT})"
info "socat bridge:     running (${BRIDGE_IP}:${ARGO_PORT} -> 127.0.0.1:${ARGO_PORT})"
info "OpenClaw gateway: running (port 18789)"
echo ""
