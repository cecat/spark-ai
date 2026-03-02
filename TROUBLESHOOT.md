# Troubleshooting

> **Upgrading OpenClaw?** See `openclaw/UPGRADE-2026.2.26.md` for a full guide to breaking
> changes introduced in the 2026.2.26 release, including the new `allowedOrigins` requirement,
> device pairing, sandbox bind-mount restrictions, and session snapshot caching.

## Quick log commands
```bash
docker compose ps
docker logs vllm-qwen3-coder-next --tail 50
docker logs openclaw-gateway --tail 50
docker logs openclaw-gateway --since 30m 2>&1 | tail -50
```

---

## Qwen / vLLM

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

## OpenClaw — Gateway

**Gateway crash loop**
Symptom: `docker ps` shows container restarting every ~60 seconds.
Most common cause: `gateway.auth.mode: "password"` without a `password` field — often
introduced by an agent editing openclaw.json.

Diagnose without a running container:
```bash
docker run --rm -v openclaw_openclaw-config:/data alpine cat /data/openclaw.json | grep -A4 '"auth"'
```

Fix — write corrected config directly to volume:
```bash
docker run --rm -v openclaw_openclaw-config:/data alpine sh -c 'cat > /data/openclaw.json << '"'"'EOF'"'"'
{ ... corrected config with "mode": "token" and "token": "your-token" ... }
EOF'
docker compose restart openclaw-gateway
docker logs openclaw-gateway --tail 20
```

Note: OpenClaw's `doctor` runs on startup and may rewrite the config. Always verify what
is actually in the volume after a restart.

**`EACCES: permission denied` during onboarding**
```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw_openclaw-config/_data
```

**Wrong workspace or vLLM URL pre-filled during onboarding**
- Workspace: `/home/node/agents/main`
- vLLM URL: `http://nim:8000/v1` (`nim` is the vLLM service name on the shared Docker network)

**Health check failure at end of onboarding**
Expected — gateway is not running yet. Start it after onboarding completes.

**"control ui requires HTTPS or localhost"**
Set up Tailscale Serve (README Step 7).

**Gateway crash loop: `non-loopback Control UI requires gateway.controlUi.allowedOrigins`**
The `allowedOrigins` field is required in v2026.2.26+. Add it to `gateway.controlUi` in
`openclaw.json` (see README Step 7 for the full config patch) and restart.

**Dashboard shows "pairing required" after Tailscale Serve is set up**
Two separate causes — check which applies:

1. *Gateway config not patched yet* — run the config patch in README Step 7 and restart.
2. *Control UI device pairing (v2026.2.26+)* — the dashboard now requires the browser to
   be registered as a paired device. Approve it via:
   ```bash
   docker exec openclaw-gateway node dist/index.js devices list
   docker exec openclaw-gateway node dist/index.js devices approve <uuid>
   ```
   Note: use `devices list/approve` (for the Control UI), not `pairing list/approve`
   (which is for Slack DM pairing).

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

## OpenClaw — Slack

**"Sending messages to this app has been turned off"**
Go to **App Home → Messages Tab** — enable it and check "Allow users to send messages".
Reinstall the app after any scope or feature change.

**Agent shows thinking but never delivers a message**
Set `"streaming": false` in the `channels.slack` config block. Do not add `assistant:write`
scope — it enables Slack's native AI streaming API which silently drops messages with
`missing_recipient_team_id` errors in this setup.

**`missing_recipient_team_id` in logs**
Caused by `assistant:write` scope and/or Agents & AI Apps feature being enabled. Remove
`assistant:write` from Bot Token Scopes, disable Agents & AI Apps in Slack app settings,
reinstall app, and set `"streaming": false`.

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
The `channels.slack.channels` allowlist controls access; `bindings` controls which agent
handles a channel. Both must be configured — a channel in `bindings` but not in the
allowlist will be silently ignored.

---

## OpenClaw — Google / gog

**`exec denied: allowlist miss` (host exec approach — dead end)**
Do not attempt to use `tools.exec.host: "gateway"` for gog. OpenClaw wraps all shell
strings in `/bin/sh -c "..."`, so the exec-approvals allowlist sees `/bin/sh` — not the
target binary — and blocks it. The exec-approvals CLI also fails with "pairing required"
in self-hosted installs and cannot be used to modify the allowlist at runtime.
Use sandbox exec instead — see `openclaw/GOG.md`.

**gog auth fails silently in sandbox — wrong env var**
`GOG_KEYRING=file` is the host env var convention but does NOT work inside the sandbox
container. Use `GOG_KEYRING_BACKEND=file`. Also `GOG_KEYRING_PASSWORD` must be set —
the file-based keyring is encrypted and will fail silently without the password.

**gog fails in sandbox with file not found or permission errors**
The sandbox rootfs is read-only. Bind mount targets must use `/tmp` prefix, and `HOME`
must be set to `/tmp` in the sandbox env. Correct bind mounts:
```
/home/catlett/.config/gogcli:/tmp/.config/gogcli:rw
/home/catlett/.local/share/keyrings:/tmp/.local/share/keyrings:rw
```
Incorrect (will fail): `/home/catlett/.config/gogcli:/home/node/.config/gogcli:rw`

**gog skill not loading / "skill not found"**
The skill must be mounted into the gateway container, not just the sandbox. Add to
docker-compose.yml volumes:
```yaml
- /home/catlett/.agents:/home/node/.agents:ro
```

**Google Cloud project suspended / "project not found"**
The original GCP project tpc26-488714 was disabled by Google for a Terms of Service
violation (exact cause unclear — possibly related to OAuth consent screen configuration).
A new project (TPC26-Forms-Triage) was created and re-auth was performed. If this happens
again: create a new GCP project, re-configure OAuth consent screen and credentials, run
`gog auth login` again, and update openclaw.json with the new project details if needed.

**gog auth tokens expire / need re-authentication**
On the host:
```bash
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=sparkagent2026
gog auth login --account chattpc26@gmail.com
```
Tokens auto-refresh when the sandbox has network access and the credentials are mounted
read-write. If token refresh fails, re-auth on the host as above.

---

## Security verification

```bash
ss -ltnp | grep :8000 || echo "OK"              # vLLM not exposed to host
ss -tlnp | grep 18789                            # must show TAILSCALE_IP, not 0.0.0.0
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file
sudo iptables -L DOCKER-USER -n | grep DROP      # must show 3 DROP rules
```
