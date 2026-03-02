#!/usr/bin/env bash
# check-for-updates.sh — Check for OpenClaw and model updates on the Spark
#
# Model:    Compares local vs. remote commit hash. Prints update instructions
#           if a newer version exists. No automatic download.
#
# OpenClaw: Pulls the latest image (small Node.js container — fast). If a new
#           version is downloaded, generates a prompt file for AI-assisted impact
#           analysis. Your running gateway is NOT changed until you explicitly
#           restart it.
#
# Run from anywhere on the Spark. No arguments needed.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_TEMPLATE="${SCRIPT_DIR}/openclaw/openclaw-upgrade-prompt.md"
PROMPT_OUTPUT="/tmp/openclaw-upgrade-prompt.md"
GITHUB_RELEASES="https://github.com/openclaw/openclaw/releases"

# ── Qwen3-Coder-Next-FP8 ─────────────────────────────────────────────────────
echo "=== Qwen3-Coder-Next-FP8 ==="
python3 << 'PYEOF'
from datetime import datetime, timezone
try:
    from huggingface_hub import repo_info, scan_cache_dir
except ImportError:
    print("huggingface_hub not installed — skipping model check")
    raise SystemExit(0)

repo = 'Qwen/Qwen3-Coder-Next-FP8'
try:
    info = repo_info(repo)
    remote_sha = info.sha
    remote_date = info.last_modified
    if isinstance(remote_date, (int, float)):
        remote_date = datetime.fromtimestamp(remote_date, tz=timezone.utc)
    print(f'Remote: {remote_sha[:12]}  ({remote_date.strftime("%Y-%m-%d")})')
except Exception as e:
    print(f'Could not reach HuggingFace: {e}')
    raise SystemExit(0)

cache = scan_cache_dir()
for r in cache.repos:
    if 'Qwen3-Coder-Next-FP8' in r.repo_id:
        local_latest = sorted(
            r.revisions,
            key=lambda v: v.last_modified if isinstance(v.last_modified, float)
                          else v.last_modified.timestamp(),
            reverse=True
        )[0]
        lm = local_latest.last_modified
        if isinstance(lm, (int, float)):
            lm = datetime.fromtimestamp(lm, tz=timezone.utc)
        print(f'Local:  {local_latest.commit_hash[:12]}  ({lm.strftime("%Y-%m-%d")})  {r.size_on_disk_str}')
        if info.sha in {rev.commit_hash for rev in r.revisions}:
            print('Up to date.')
        else:
            print('*** Newer version available.')
            print(f'    Review changes before downloading 46GB:')
            print(f'    https://huggingface.co/{repo}/commits/main')
            print(f'    To update:')
            print(f'      read -s -p "HF token: " HF_TOKEN; echo')
            print(f'      HF_TOKEN=$HF_TOKEN python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id=\'{repo}\')"')
            print(f'      unset HF_TOKEN')
        break
else:
    print('Model not found in local cache.')
PYEOF

echo ""

# ── OpenClaw ──────────────────────────────────────────────────────────────────
echo "=== OpenClaw ==="
echo "Checking for updates..."

pull_output=$(docker pull ghcr.io/openclaw/openclaw:latest 2>&1)

if echo "$pull_output" | grep -q "Image is up to date"; then
    echo "Up to date."
    exit 0
fi

if ! echo "$pull_output" | grep -q "Downloaded newer image"; then
    echo "Unexpected output — could not determine update status:"
    echo "$pull_output"
    exit 1
fi

echo "*** New version downloaded to local Docker cache."
echo "    Your running gateway is unchanged until you explicitly restart it."
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
