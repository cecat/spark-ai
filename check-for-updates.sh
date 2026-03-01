#!/usr/bin/env bash
# check-for-updates.sh — Check for OpenClaw and model updates on the Spark
# Run from anywhere on the Spark. No arguments needed.

set -uo pipefail

echo "=== OpenClaw ==="
echo "Pulling latest image..."
pull_output=$(docker pull ghcr.io/openclaw/openclaw:latest 2>&1)
echo "$pull_output"

if echo "$pull_output" | grep -q "Downloaded newer image"; then
    echo ""
    echo "*** New OpenClaw image available. Restart with:"
    echo "    cd ~/code/spark-ai/openclaw && docker compose down && docker compose up -d"
    echo "    Then recreate sandboxes:"
    echo "    docker stop \$(docker ps -q --filter name=openclaw-sbx)"
    echo "    docker rm \$(docker ps -aq --filter name=openclaw-sbx)"
    echo "    docker compose restart openclaw-gateway"
else
    echo "OpenClaw is up to date."
fi

echo ""
echo "=== Qwen3-Coder-Next-FP8 ==="
python3 -c "
from huggingface_hub import repo_info, scan_cache_dir
info = repo_info('Qwen/Qwen3-Coder-Next-FP8')
print(f'Remote last modified: {info.last_modified}')
cache = scan_cache_dir()
found = False
for r in cache.repos:
    if 'Qwen3-Coder-Next-FP8' in r.repo_id:
        found = True
        print(f'Local last accessed:  {r.last_accessed}')
        print(f'Local size:           {r.size_on_disk_str}')
if not found:
    print('Model not found in local cache!')
"
