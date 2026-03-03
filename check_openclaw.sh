#!/usr/bin/env bash
# check_openclaw.sh — Check for a newer OpenClaw image without pulling
#
# Default: compares local image digest against GHCR registry metadata.
#          Never downloads image layers.
#
# --update: pulls the new image to local Docker cache, then generates an
#           upgrade analysis prompt. Your running gateway is unchanged
#           until you explicitly restart it.

set -uo pipefail

IMAGE="ghcr.io/openclaw/openclaw:latest"
REPO="openclaw/openclaw"
GITHUB_RELEASES="https://github.com/openclaw/openclaw/releases"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE="${SCRIPT_DIR}/openclaw/openclaw-upgrade-prompt.md"
PROMPT_OUTPUT="/tmp/openclaw-upgrade-prompt.md"

UPDATE=false
for arg in "$@"; do
    [[ "$arg" == "--update" ]] && UPDATE=true
done

echo "=== OpenClaw ==="

# ── Get local digest ──────────────────────────────────────────────────────────
LOCAL_DIGEST=""
if docker image inspect "$IMAGE" &>/dev/null; then
    LOCAL_FULL=$(docker inspect "$IMAGE" --format '{{index .RepoDigests 0}}' 2>/dev/null || true)
    LOCAL_DIGEST="${LOCAL_FULL##*@}"
fi

# ── Get remote digest via GHCR API (no image download) ───────────────────────
echo "Checking registry..."
TOKEN=$(curl -sf "https://ghcr.io/token?scope=repository:${REPO}:pull&service=ghcr.io" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])" 2>/dev/null || true)

if [[ -z "$TOKEN" ]]; then
    echo "Could not reach GHCR — check network."
    exit 1
fi

REMOTE_DIGEST=$(curl -sI \
    -H "Authorization: Bearer $TOKEN" \
    -H "Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json" \
    "https://ghcr.io/v2/${REPO}/manifests/latest" \
    | grep -i "^docker-content-digest:" \
    | awk '{print $2}' \
    | tr -d '\r\n')

if [[ -z "$REMOTE_DIGEST" ]]; then
    echo "Could not retrieve remote digest — check network or try again."
    exit 1
fi

# ── Compare ───────────────────────────────────────────────────────────────────
if [[ -z "$LOCAL_DIGEST" ]]; then
    echo "Remote: ${REMOTE_DIGEST:0:19}..."
    echo "Local:  (not cached)"
    echo "*** Not found locally — run with --update to pull."
elif [[ "$LOCAL_DIGEST" == "$REMOTE_DIGEST" ]]; then
    echo "Remote: ${REMOTE_DIGEST:0:19}..."
    echo "Local:  ${LOCAL_DIGEST:0:19}..."
    echo "Up to date."
    exit 0
else
    echo "Remote: ${REMOTE_DIGEST:0:19}..."
    echo "Local:  ${LOCAL_DIGEST:0:19}..."
    echo "*** Newer version available on GHCR."
fi

if [[ "$UPDATE" == false ]]; then
    echo ""
    echo "Review release notes before pulling:"
    echo "  $GITHUB_RELEASES"
    echo ""
    echo "When ready:  $(basename "$0") --update"
    exit 0
fi

# ── --update: pull + generate analysis prompt ─────────────────────────────────
echo ""
echo "Pulling new image to local cache..."
docker pull "$IMAGE"

echo ""
echo "─────────────────────────────────────────────────────────────────"
echo "BEFORE restarting, review the release notes and assess impact:"
echo ""
echo "  1. Open the releases page:"
echo "       $GITHUB_RELEASES"
echo ""
echo "  2. A prompt for your AI assistant has been generated:"
echo "       $PROMPT_OUTPUT"
echo ""
echo "     Open it, paste the release notes where indicated, and take it"
echo "     to Claude (or your preferred assistant) for impact analysis."
echo ""
echo "  3. When ready to apply the update:"
echo "       cd ~/code/spark-ai/openclaw"
echo "       docker compose down && docker compose up -d"
echo "       docker stop \$(docker ps -q --filter name=openclaw-sbx) 2>/dev/null || true"
echo "       docker rm \$(docker ps -aq --filter name=openclaw-sbx) 2>/dev/null || true"
echo "       docker compose restart openclaw-gateway"
echo "─────────────────────────────────────────────────────────────────"
echo ""

# ── Generate prompt with current config embedded ──────────────────────────────
CONFIG_FILE="/tmp/openclaw-current-config.json"
docker run --rm -v openclaw_openclaw-config:/data alpine cat /data/openclaw.json \
    > "$CONFIG_FILE" 2>/dev/null \
    || echo '{"error": "could not read config — is the openclaw volume present?"}' \
    > "$CONFIG_FILE"

cat > /tmp/_gen_prompt.py << 'PYEOF'
import sys, json
_, template_path, config_path, output_path = sys.argv
with open(template_path) as f:
    template = f.read()
with open(config_path) as f:
    raw = f.read()
try:
    config = json.dumps(json.loads(raw), indent=2)
except Exception:
    config = raw
with open(output_path, "w") as f:
    f.write(template.replace("{{OPENCLAW_JSON}}", config))
PYEOF

python3 /tmp/_gen_prompt.py "$PROMPT_TEMPLATE" "$CONFIG_FILE" "$PROMPT_OUTPUT"
rm -f /tmp/_gen_prompt.py "$CONFIG_FILE"

echo "Prompt ready: $PROMPT_OUTPUT"
