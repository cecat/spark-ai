#!/usr/bin/env bash
set -euo pipefail

# Ensure ~/.local/bin (argo-shim install location) is on PATH for non-interactive
# callers (cron, systemd). Login shells already add this via ~/.profile.
export PATH="$HOME/.local/bin:$PATH"

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
# Overridable so the argo-down path can be exercised against a dead port
# without touching the real shim on 44497.
ARGO_PORT="${ARGO_PORT:-44497}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[…]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; exit 1; }

# Distinct from the generic failure exit 1 so run-stack-health.sh can tell
# "argo-shim is down, a human must run ~/start-all.sh" apart from a real
# stack fault, and page once a day instead of every 6h.
EXIT_ARGO_DOWN=3

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
# Probe model/timeout match ~/start-all.sh's argo_healthy and Spark-Hermes.
# haiku is the cheapest and fastest round-trip; sonnet against an 8s timeout
# was the most false-positive-prone probe in the stack.
argo_curl_ok() {
    local url=$1
    local code
    code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 \
        -X POST "${url}/v1/messages" \
        -H "Content-Type: application/json" \
        -d '{"model":"claudehaiku45","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
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
        --max-time 10 "http://${BRIDGE_IP}:${ARGO_PORT}/v1/messages" \
        -H "Content-Type: application/json" \
        -X POST \
        -d '{"model":"claudehaiku45","max_tokens":5,"messages":[{"role":"user","content":"hi"}]}' \
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
        # Re-confirm before destroying: one failed sample is not proof of death.
        warn "vLLM /health failed — re-confirming for 20s before restarting"
        if wait_for "re-confirming vLLM" 20 vllm_health_ok; then
            echo ""
            info "vLLM healthy (recovered on re-probe — not restarting)"
            return
        fi
        echo ""
        warn "vLLM confirmed unhealthy — restarting"
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

# ── 2. argo-shim (VERIFY ONLY — this script does not own it) ────────────
#
# Layer 1 owner is ~/start-all.sh. This script used to start and pkill the shim
# itself, which was wrong for two reasons:
#
#   1. The probe is a live LLM round-trip over an SSH tunnel to Argonne, so
#      ordinary latency reads as "dead". A single failed sample was enough to
#      kill a perfectly healthy shim.
#   2. This script runs UNATTENDED from cron every 6h (run-stack-health.sh).
#      argo-shim's ssh uses BatchMode=yes and cannot re-auth on its own, and
#      argo_shim's own SSHAttemptTracker exists because CSPO blocks the source
#      IP after repeated failed auth. An unattended killer is the last thing
#      that should be pointed at it.
#
# That combination produced a month of self-inflicted 3:30am failures
# (34 in the 7 days to 2026-08-13). So: verify, never start, never kill.

ensure_argo_shim() {
    echo ""
    echo "=== argo-shim (127.0.0.1:${ARGO_PORT}) — verify only ==="

    if argo_curl_ok "http://127.0.0.1:${ARGO_PORT}"; then
        info "argo-shim healthy (claudehaiku45 returns 200)"
        return
    fi

    warn "argo-shim probe failed — re-confirming for 20s before declaring it down"
    if wait_for "re-confirming argo-shim" 20 \
        argo_curl_ok "http://127.0.0.1:${ARGO_PORT}"; then
        echo ""
        info "argo-shim healthy (recovered on re-probe — first sample was a blip)"
        return
    fi

    # Everything below this point (socat bridge, gateway health) probes Argo
    # THROUGH the shim, so continuing would report derived failures and
    # force-recreate a healthy gateway. Stop here instead.
    echo "Last 20 lines of $ARGO_SHIM_LOG:"
    tail -20 "$ARGO_SHIM_LOG" 2>&1 || true
    echo ""
    warn "argo-shim is DOWN, and this script is not its owner."
    warn "Run the Layer 1 owner from an interactive terminal:  ~/start-all.sh"
    exit "$EXIT_ARGO_DOWN"
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
        info "socat bridge healthy (listening, claudehaiku45 returns 200)"
        return
    fi

    if ss -tlnp 2>/dev/null | grep -q "${BRIDGE_IP}:${ARGO_PORT} "; then
        # Re-confirm before destroying: this probe crosses socat AND the shim,
        # so upstream latency can look like a dead bridge.
        warn "socat health failed — re-confirming for 20s before restarting"
        if wait_for "re-confirming socat bridge" 20 \
            argo_curl_ok "http://${BRIDGE_IP}:${ARGO_PORT}"; then
            echo ""
            info "socat bridge healthy (recovered on re-probe — not restarting)"
            return
        fi
        echo ""
        warn "socat confirmed unhealthy — restarting"
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

    # Cascade: vLLM restart → nim_net recreated → gateway lost its network.
    # Must be --force-recreate, not restart: restart reuses the existing network
    # sandbox, so a container orphaned from nim_net (loopback only, ENETUNREACH
    # on every outbound call) can never rejoin it and the restart loops forever.
    if $VLLM_RESTARTED; then
        warn "vLLM was restarted — recreating gateway to rejoin nim_net"
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" up -d \
            --force-recreate openclaw-gateway \
            || fail "Failed to (re)start gateway"
    elif docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$' && gateway_health_ok; then
        info "gateway healthy (container running, can reach Argo via socat)"
        return
    elif docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$'; then
        # Re-confirm before destroying: gateway_health_ok curls Argo from inside
        # the container, so it fails on upstream latency even when the container
        # is perfectly fine. Recreating on one bad sample throws away a healthy
        # gateway (and every in-flight agent session with it).
        warn "gateway health failed — re-confirming for 20s before recreating"
        if wait_for "re-confirming gateway" 20 gateway_health_ok; then
            echo ""
            info "gateway healthy (recovered on re-probe — not recreating)"
            return
        fi
        echo ""
        warn "gateway confirmed unhealthy — recreating"
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" up -d \
            --force-recreate openclaw-gateway \
            || fail "Failed to recreate gateway"
    else
        warn "Starting gateway..."
        docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" up -d \
            || fail "Failed to start gateway"
    fi

    if wait_for "gateway warming up" 180 gateway_health_ok; then
        echo ""
        info "gateway ready"
    else
        echo "Last 20 lines of gateway logs:"
        docker logs openclaw-gateway --tail 20 2>&1
        fail "gateway did not become healthy within 180s"
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
