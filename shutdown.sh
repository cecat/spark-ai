#!/usr/bin/env bash
set -euo pipefail
#
# Graceful shutdown for the spark-ai layer: OpenClaw, vLLM, the Argo tunnel,
# and OpenClaw's "luoji" tenant in the shared FALDA/Sibline memory layer.
#
# PREFER ~/shutdown.sh — the host-wide orchestrator (DGX-Spark) that calls this
# script, Spark-Hermes's, and then stops the shared memory substrate in order.
# Running this one alone is correct but partial.
#
# Scope note: FALDA / Sibline / Ollama are multi-tenant. This script stops only
# the LUOJI tenant units (step 1). The gandalf tenant belongs to
# Spark-Hermes/ops/shutdown.sh, and the shared substrate they both use
# (falda-gateway :8077, ollama :11434, sibline-broker :4222, ump-memory :4100)
# belongs to the orchestrator, which stops it after BOTH tenants are down.

SPARK_AI_DIR="$HOME/code/spark-ai"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[…]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; }

# stop_unit <unit> <description>
# systemd user units, all WantedBy=default.target with linger on, so `stop` is
# not `disable` — they come back by themselves at next boot.
stop_unit() {
    local unit=$1 desc=$2
    if ! systemctl --user is-active "$unit" >/dev/null 2>&1; then
        info "$unit already stopped"
        return 0
    fi
    warn "Stopping $unit ($desc)..."
    if systemctl --user stop "$unit" 2>/dev/null; then
        info "$unit stopped"
    else
        fail "Failed to stop $unit"
    fi
}

# ── Step 1: luoji tenant (FALDA writers + Sibline client) ───────────────
#
# Stopped BEFORE the OpenClaw containers they observe, so neither is mid-pass
# when its data source goes away. Not a correctness requirement — the tap reads
# session .jsonl files on the HOST (~/.openclaw-sessions/luoji) with a byte-
# offset checkpoint, and the distiller checkpoints atomically after a successful
# write — so the worst case either way is lag, never loss. It is just tidier
# than leaving them polling a frozen source.

echo ""
echo "=== Step 1/5: luoji tenant (FALDA + Sibline) ==="

stop_unit falda-tap-luoji.service       "OpenClaw sessions → FALDA"
stop_unit falda-distiller-luoji.service "T0→T3 synthesis, luoji tenant"
stop_unit sibline-bridge-luoji.service  "NATS → /workspace mailbox"

# ── Step 2: OpenClaw gateway ────────────────────────────────────────────

echo ""
echo "=== Step 2/5: OpenClaw gateway ==="

if docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$'; then
    warn "Stopping OpenClaw gateway..."
    docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" down \
        && info "OpenClaw gateway stopped" \
        || fail "Failed to stop OpenClaw gateway"
else
    info "OpenClaw gateway is not running"
fi

# ── Step 3: OpenClaw sandbox containers ────────────────────────────────

echo ""
echo "=== Step 3/5: OpenClaw sandbox containers ==="

SBX_CONTAINERS=$(docker ps -q --filter 'label=openclaw.sandbox' 2>/dev/null || true)
if [ -n "$SBX_CONTAINERS" ]; then
    SBX_COUNT=$(echo "$SBX_CONTAINERS" | wc -l)
    warn "Stopping $SBX_COUNT sandbox container(s)..."
    docker stop $SBX_CONTAINERS >/dev/null 2>&1 \
        && docker rm $SBX_CONTAINERS >/dev/null 2>&1 \
        && info "$SBX_COUNT sandbox container(s) stopped and removed" \
        || fail "Failed to stop some sandbox containers"
else
    info "No OpenClaw sandbox containers running"
fi

# ── Step 4: vLLM Qwen server ────────────────────────────────────────────

echo ""
echo "=== Step 4/5: vLLM Qwen server ==="

if docker ps --format '{{.Names}}' | grep -q '^vllm-qwen3-coder-next$'; then
    warn "Stopping vLLM container..."
    docker compose -f "$SPARK_AI_DIR/qwen3-coder-next/docker-compose.yml" down \
        && info "vLLM container stopped" \
        || fail "Failed to stop vLLM container"
else
    info "vLLM container is not running"
fi

# ── Step 5: Argo SSH tunnel ─────────────────────────────────────────────

echo ""
echo "=== Step 5/5: Argo SSH tunnel ==="

if ssh -O check argo-tunnel 2>/dev/null; then
    warn "Closing Argo tunnel..."
    ssh -O exit argo-tunnel 2>/dev/null \
        && info "Argo tunnel closed" \
        || fail "Failed to close Argo tunnel"
else
    info "Argo tunnel is not running"
fi

# ── Summary ─────────────────────────────────────────────────────────────

echo ""
echo "=== spark-ai layer stopped ==="

# Only claim the host is ready when run standalone. Under ~/shutdown.sh the
# orchestrator still has the shared memory substrate to stop after this.
if [ -z "${SHUTDOWN_ORCHESTRATED:-}" ]; then
    info "Ready for reboot"
    warn "Still up — shared, not this script's to stop:"
    warn "  FALDA :8077 │ Ollama :11434 │ NATS :4222 │ UMP :4100"
    warn "  Use ~/shutdown.sh to stop those too (and the Gandalf layer)."
fi
echo ""
