#!/usr/bin/env bash
# check-for-updates.sh — Check for OpenClaw and model updates on the Spark
# Run from anywhere on the Spark. No arguments needed.

set -uo pipefail

echo "=== OpenClaw ==="
echo "Pulling latest image (may take 30-60s to check layers)..."
docker pull ghcr.io/openclaw/openclaw:latest 2>&1 | tee /tmp/.openclaw-pull-output
pull_output=$(cat /tmp/.openclaw-pull-output)
rm -f /tmp/.openclaw-pull-output

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
from datetime import datetime, timezone
from huggingface_hub import repo_info, scan_cache_dir

repo = 'Qwen/Qwen3-Coder-Next-FP8'
info = repo_info(repo)
remote_sha = info.sha
remote_date = info.last_modified
if isinstance(remote_date, (int, float)):
    remote_date = datetime.fromtimestamp(remote_date, tz=timezone.utc)
print(f'Remote commit:  {remote_sha[:12]}  ({remote_date.strftime(\"%Y-%m-%d\")})')  

cache = scan_cache_dir()
found = False
for r in cache.repos:
    if 'Qwen3-Coder-Next-FP8' in r.repo_id:
        found = True
        local_shas = {rev.commit_hash for rev in r.revisions}
        local_latest = sorted(r.revisions, key=lambda v: v.last_modified if isinstance(v.last_modified, float) else v.last_modified.timestamp(), reverse=True)[0]
        lm = local_latest.last_modified
        if isinstance(lm, (int, float)):
            lm = datetime.fromtimestamp(lm, tz=timezone.utc)
        print(f'Local commit:   {local_latest.commit_hash[:12]}  (downloaded {lm.strftime(\"%Y-%m-%d\")})')  
        print(f'Local size:     {r.size_on_disk_str}')  
        if remote_sha in local_shas:
            print('Model is up to date.')
        else:
            print(f'*** Remote has a newer commit. Check https://huggingface.co/{repo}/commits/main')
            print('    (May be just a README change — review before re-downloading.)')
        break

if not found:
    print('Model not found in local cache!')
"
