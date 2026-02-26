# Troubleshooting

## Quick log commands
```bash
docker compose ps
docker logs vllm-qwen3-coder-next --tail 50
docker logs openclaw-gateway --tail 50
docker logs openclaw-gateway --since 30m 2>&1 | tail -50
```

---

## vLLM / GPU

**`unknown or invalid runtime name: nvidia`**
```bash
sudo nvidia-ctk runtime configure --runtime=docker && sudo systemctl restart docker
```

**`CUDA error` or `SM version not supported`**
```bash
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
```

**OOM during model load**
Reduce `--gpu-memory-utilization` from `0.8` to `0.7` in `qwen3-coder-next/docker-compose.yml`.

**Slow first start (~2 min)**
Normal — vLLM compiles Triton kernels on first run. Subsequent starts are faster.

**Confirm model fully downloaded**
```bash
du -sh ~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/
# Expected: ~46GB
```

---

## OpenClaw gateway crash loop

**Symptom:** `docker ps` shows container restarting every ~60 seconds.

**Most common cause:** `gateway.auth.mode: "password"` without a `password` field — often introduced by an agent editing openclaw.json.

**Diagnose without a running container:**
```bash
docker run --rm -v openclaw_openclaw-config:/data alpine cat /data/openclaw.json | grep -A4 '"auth"'
```

**Fix — write corrected config directly to volume:**
```bash
docker run --rm -v openclaw_openclaw-config:/data alpine sh -c 'cat > /data/openclaw.json << '"'"'EOF'"'"'
{ ... corrected config with "mode": "token" and "token": "your-token" ... }
EOF'
docker compose restart openclaw-gateway
docker logs openclaw-gateway --tail 20
```

**Note:** OpenClaw's `doctor` runs on startup and may rewrite the config. Always verify what is actually in the volume after a restart, not just what you wrote.

---

## OpenClaw onboarding

**`EACCES: permission denied`**
```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw_openclaw-config/_data
```

**Wrong workspace path pre-filled**
Enter `/home/node/agents/main` — docker-compose.yml mounts `OPENCLAW_WORKSPACE` at `/home/node/agents`.

**Wrong vLLM URL pre-filled**
Enter `http://nim:8000/v1` — `nim` is the vLLM service name on the shared Docker network.

**Health check failure at end of onboarding**
Expected — gateway is not running yet. Start it after onboarding completes.

---

## OpenClaw dashboard

**"control ui requires HTTPS or localhost"**
Set up Tailscale Serve (README Step 7).

**"pairing required" after Tailscale Serve is set up**
Run the config patch in README Step 7 and restart.

**Token lost**
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli dashboard --no-open
```

**Config shows "invalid" after editing**
Common causes:
- `channels.slack.channels` must be an object, not an array: `{ "C123": { "allow": true } }` not `["C123"]`
- `gateway.auth.mode: "password"` requires a `"password"` field — use `"token"` mode instead
- `webhookPath` must be present even in Socket Mode — keep it as `/slack/events`
- `channels` section must be at the top level of openclaw.json, not nested inside `gateway`

---

## Slack

**"Sending messages to this app has been turned off"**
Go to **App Home → Messages Tab** — enable it and check "Allow users to send messages". Reinstall the app after any scope or feature change.

**Agent shows thinking but never delivers a message**
Set `"streaming": false` in the `channels.slack` config block. Do not add `assistant:write` scope — it enables Slack's native AI streaming API which silently drops messages with `missing_recipient_team_id` errors in this setup.

**`missing_recipient_team_id` in logs**
Caused by `assistant:write` scope and/or Agents & AI Apps feature being enabled. Remove `assistant:write` from Bot Token Scopes, disable Agents & AI Apps in Slack app settings, reinstall app, and set `"streaming": false`.

**`missing_scope` warning in logs**
Bot cannot resolve channel names from IDs — cosmetic, does not affect message delivery.

**Agent not responding in a channel**
Check in order:
1. Bot invited: `/invite @BotName`
2. Channel ID listed in `channels.slack.channels` with `"allow": true`
3. `groupPolicy: "allowlist"` with an empty `channels` object blocks everything
4. `@BotName` mention included (required when `requireMention: true`)
5. Check logs: `docker logs openclaw-gateway --tail 50`

**DMs not working**
Ensure `im:read` and `im:write` scopes are present. Reinstall the app after adding scopes.

**Multi-agent routing not working**
The `channels.slack.channels` allowlist controls access; `bindings` controls which agent handles a channel. Both must be configured — a channel in `bindings` but not in the allowlist will be silently ignored.

---

## Networking

**OpenClaw cannot reach vLLM**
vLLM must start before OpenClaw so the shared network exists:
```bash
docker network ls | grep nim_net
docker run --rm --network qwen3-coder-next_nim_net curlimages/curl:latest http://nim:8000/v1/models
```

**iptables rules lost after reboot**
```bash
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```

---

## Security verification

```bash
ss -ltnp | grep :8000 || echo "OK"              # vLLM not exposed to host
ss -tlnp | grep 18789                            # must show TAILSCALE_IP, not 0.0.0.0
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file
sudo iptables -L DOCKER-USER -n | grep DROP      # must show 3 DROP rules
```
