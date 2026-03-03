#!/usr/bin/env bash
# check_model.sh — Check for a newer Qwen3-Coder-Next-FP8 model without downloading
#
# Default: compares local cache commit hash against HuggingFace remote.
#          Never downloads model weights (~46GB).
#
# --update: prompts for a HuggingFace token and downloads the full model.
#           Download is resumable — safe to interrupt and re-run.

set -uo pipefail

REPO="Qwen/Qwen3-Coder-Next-FP8"

UPDATE=false
for arg in "$@"; do
    [[ "$arg" == "--update" ]] && UPDATE=true
done

echo "=== Qwen3-Coder-Next-FP8 ==="

python3 << 'PYEOF'
import sys
from datetime import datetime, timezone

try:
    from huggingface_hub import repo_info, scan_cache_dir
except ImportError:
    print("huggingface_hub not installed — run: pip install huggingface_hub --break-system-packages")
    sys.exit(1)

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
    sys.exit(1)

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
            sys.exit(0)
        else:
            print('*** Newer version available.')
            print(f'    Review: https://huggingface.co/{repo}/commits/main')
            sys.exit(2)
        break
else:
    print('Model not found in local cache.')
    sys.exit(2)
PYEOF

PY_STATUS=$?

if [[ $PY_STATUS -eq 0 ]]; then
    exit 0
fi

if [[ $PY_STATUS -eq 1 ]]; then
    # Error (network failure, missing library, etc.) — message already printed
    exit 1
fi

# PY_STATUS=2: update available or not cached
if [[ "$UPDATE" == false ]]; then
    echo ""
    echo "Review changes before downloading 46GB:"
    echo "  https://huggingface.co/${REPO}/commits/main"
    echo ""
    echo "When ready:  $(basename "$0") --update"
    exit 0
fi

# ── --update: prompt for token and download ───────────────────────────────────
echo ""
read -s -p "HuggingFace token: " HF_TOKEN; echo
echo "Starting download (~46GB, resumable — safe to interrupt and re-run)..."
HF_TOKEN="$HF_TOKEN" python3 -c "
import os
from huggingface_hub import snapshot_download
snapshot_download(repo_id='Qwen/Qwen3-Coder-Next-FP8', token=os.environ['HF_TOKEN'])
"
unset HF_TOKEN
echo "Download complete."
