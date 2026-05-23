#!/usr/bin/env bash
set -euo pipefail

SPARK_AI_DIR="$HOME/code/spark-ai"
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[…]${NC} $*"; }
fail()  { echo -e "${RED}[✗]${NC} $*"; }

# ── Step 1: OpenClaw gateway ────────────────────────────────────────────

echo ""
echo "=== Step 1/4: OpenClaw gateway ==="

if docker ps --format '{{.Names}}' | grep -q '^openclaw-gateway$'; then
    warn "Stopping OpenClaw gateway..."
    docker compose -f "$SPARK_AI_DIR/openclaw/docker-compose.yml" down \
        && info "OpenClaw gateway stopped" \
        || fail "Failed to stop OpenClaw gateway"
else
    info "OpenClaw gateway is not running"
fi

# ── Step 2: OpenClaw sandbox containers ────────────────────────────────

echo ""
echo "=== Step 2/4: OpenClaw sandbox containers ==="

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

# ── Step 3: vLLM Qwen server ────────────────────────────────────────────

echo ""
echo "=== Step 3/4: vLLM Qwen server ==="

if docker ps --format '{{.Names}}' | grep -q '^vllm-qwen3-coder-next$'; then
    warn "Stopping vLLM container..."
    docker compose -f "$SPARK_AI_DIR/qwen3-coder-next/docker-compose.yml" down \
        && info "vLLM container stopped" \
        || fail "Failed to stop vLLM container"
else
    info "vLLM container is not running"
fi

# ── Step 4: Argo SSH tunnel ─────────────────────────────────────────────

echo ""
echo "=== Step 4/4: Argo SSH tunnel ==="

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
echo "=== All services stopped ==="
info "Ready for reboot"
echo ""
