# Troubleshooting

> **Upgrading OpenClaw?** See `openclaw/UPGRADE-2026.2.26.md` for a full guide to breaking
> changes introduced in the 2026.2.26 release, including the new `allowedOrigins` requirement,
> device pairing, sandbox bind-mount restrictions, and session snapshot caching.

## Contents

- [Quick log commands](#quick-log-commands)
- [Qwen / vLLM](#qwen--vllm)
- [OpenClaw — Gateway](#openclaw--gateway)
- [OpenClaw — Gateway crash-loop and SSH freezing](#openclaw--gateway-crash-loop-and-ssh-freezing)
- [OpenClaw — Model configuration](#openclaw--model-configuration)
- [OpenClaw — Slack](#openclaw--slack)
- [OpenClaw — Slack latency and session management](#openclaw--slack-latency-and-session-management)
- [OpenClaw — Google / gog](#openclaw--google--gog)
- [Security verification](#security-verification)
- [openclaw.json — key config notes](#openclawjson--key-config-notes)
- [Sandbox gotchas](#sandbox-gotchas)

---

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

## OpenClaw — Gateway crash-loop and SSH freezing

**Symptom:** SSH sessions freeze mid-command or hang on connect. New SSH connections
time out or freeze after a few keystrokes. The console is responsive. `docker ps`
shows the openclaw-gateway container restarting repeatedly.

**Cause:** Docker rewrites its iptables NAT and FORWARD rules every time a container
starts or stops. This is normal Docker behavior and happens regardless of the security
rules in the DOCKER-USER chain (Step 9). During a crash-loop, these rewrites happen
dozens of times per minute, creating brief windows where packet routing breaks. Active
SSH sessions stall waiting for ACKs that can't get through during those windows. The
connection isn't dropped — it just freezes.

Docker's exponential backoff eventually slows the loop, which is why SSH may become
intermittently functional (you connect, type a few characters, then it freezes) rather
than completely dead.

**Diagnose:**
```bash
docker logs openclaw-gateway --tail 30    # look for repeated "Config invalid" or startup errors
docker ps                                  # check container status and restart count
```

**Fix:** Resolve whatever is making the gateway fail to start, then restart it cleanly.
The most common cause is a bad `openclaw.json` — use the emergency revert:

```bash
# Revert to local vLLM model and clear any bad remote-model config:
~/code/spark-ai/revert-to-local.sh

# Then verify the gateway came up cleanly:
docker logs openclaw-gateway --tail 20
```

`revert-to-local.sh` reads the current `openclaw.json` directly from the Docker volume
and removes Anthropic config in place — no snapshot or backup file needed. It works
as long as Docker is running.

If the gateway still won't start after reverting, see the crash loop entry in
[OpenClaw — Gateway](#openclaw--gateway) above.

---

## OpenClaw — Model configuration

See `README.md` → Model configuration for the full workflow. Quick reference:

**Switch agents to Anthropic:**
```bash
vim ~/code/spark-ai/config.yaml      # set model: anthropic/claude-sonnet-4-6
./apply-config.sh --dry-run          # verify before applying
./apply-config.sh
```

**Revert all agents to local vLLM (emergency):**
```bash
~/code/spark-ai/revert-to-local.sh
```

**After applying:** `apply-config.sh` watches gateway logs for 20 seconds automatically.
If it detects a crash-loop ("Config invalid" or similar), it invokes `revert-to-local.sh`
and exits non-zero. You'll see exactly what went wrong. No manual log-watching needed.

To check gateway health manually:
```bash
docker logs openclaw-gateway --tail 20
# Look for: [gateway] agent model: anthropic/... or vllm/...
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

## OpenClaw — Slack latency and session management

### Multi-minute response delays / silent 10-minute timeouts

**Symptom:** Agent responses take several minutes, or interactions go completely silent for 10+ minutes. May appear intermittent or agent-specific — the most-used channel is usually the worst affected. Fan noise on the Spark increases noticeably over time as the GPU works harder on each interaction.

**Hypothesis:** OpenClaw replays the full conversation history to the model on every new message. As history accumulates over days, each message requires the model to process a larger and larger prompt — and prefill time grows with context size. This happens well before the model's 128K token limit is reached: on a ~50 tps local model, a session that has grown to 1+ MB of history can cause multi-minute delays and eventually hit OpenClaw's built-in 10-minute inference timeout.

OpenClaw's `compaction: "safeguard"` setting (on by default) only fires when a session *approaches* the token limit — it protects against errors, not latency. At slow token rates, the session bogs down long before compaction ever triggers.

**Workaround:** Schedule a daily session reset so history never accumulates past a day's worth. Two scripts in `spark-ai-agents/scripts/` handle this:

- `reset-sessions.sh` — archives and clears session `.jsonl` files above 512 KB; run at 4am
- `monitor-sessions.sh` — logs session file sizes every 5 min for trend tracking

Add to crontab on Spark (`crontab -e`):
```
*/5 * * * * /home/catlett/code/spark-ai-agents/scripts/monitor-sessions.sh >> /home/catlett/code/spark-ai-agents/shared/sessions/cron.log 2>&1
0 4 * * * /home/catlett/code/spark-ai-agents/scripts/reset-sessions.sh >> /home/catlett/code/spark-ai-agents/shared/sessions/cron.log 2>&1
```

Manual reset if an agent is slow right now:
```bash
ssh spark-ts 'bash ~/code/spark-ai-agents/scripts/reset-sessions.sh'
```

See `README.md` Step 14 for first-time setup and `spark-ai-agents/RUNBOOK.md` → Session Management for operational details.

**Comment:** This explains why slowdowns appear agent-specific — whichever channel has the most accumulated conversation history is always the worst affected. Users on paid APIs will eventually hit a hard token-limit error that makes the problem visible (and may notice a mysterious jump in burn rate beforehand). On a local model with no billing signal, things just get quietly slower and slower until they time out. Higher throughput makes large contexts more tolerable, but daily session reset is good practice regardless — most conversations don't need the context of what someone asked the model yesterday.

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
`gog auth add --manual --force-consent` again, and update openclaw.json with the new project details if needed.

**gog auth tokens expire / need re-authentication**

Tokens expire every ~7 days because the Google Cloud OAuth consent screen is in
"Testing" mode. Gateway reboots do NOT cause expiry — this is a Google policy for
unverified apps using sensitive scopes (Gmail, Drive).

Re-auth requires an interactive SSH session (for paste-back). Use `OAuth-renew.sh`
on Spark — no port forwarding needed, `--manual` handles the browser step:

**Step 1** — open an interactive SSH session to Spark:
```bash
ssh -t spark-ts
```

**Step 2** — run the renewal script (no browser tunnel needed — `--manual` handles it):
```bash
bash ~/code/spark-ai-agents/OAuth-renew.sh
```
Or manually:
```bash
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw)
gog auth add tpc26agent@gmail.com \
  --services drive,sheets,docs,gmail,contacts \
  --manual --force-consent
```

**Step 3** — gog prints a Google authorization URL. Open it in your browser and
complete the Google login.

**Step 4** — when the browser redirects to a URL that fails to load, copy the full
URL from the browser address bar and paste it into the SSH terminal. gog reads it
from stdin and extracts the auth code.

> **Why -t matters:** Running `ssh ... 'bash OAuth-renew.sh'` non-interactively means
> gog cannot read your pasted input. The `-t` flag allocates a pseudo-terminal so the
> paste-back step works.

Tokens auto-refresh when the sandbox has network access and credentials are mounted
read-write. If auto-refresh fails (i.e. 7 days have passed), re-auth as above.

---

## Security verification

```bash
ss -ltnp | grep :8000 || echo "OK"              # vLLM not exposed to host
ss -tlnp | grep 18789                            # must show TAILSCALE_IP, not 0.0.0.0
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file
sudo iptables -L DOCKER-USER -n | grep DROP      # must show 3 DROP rules
```

---

## openclaw.json — key config notes

- `gateway.auth.mode` must be `"token"` with a `"token"` field — `"password"` mode requires a separate `"password"` field and will crash-loop the gateway if misconfigured
- `channels.slack.channels` is an **object** keyed by channel ID, not an array: `{ "C123": { "allow": true } }`
- `channels.slack.groupPolicy: "allowlist"` with an empty `channels` object means the bot responds nowhere
- `streaming: false` is required — Slack's native streaming API fails silently without `assistant:write`
- Do not add `assistant:write` scope to the Slack app
- `webhookPath: "/slack/events"` must be present even in Socket Mode
- When editing openclaw.json directly (e.g. to fix a crash loop when the container won't start):
```bash
docker run --rm -v openclaw_openclaw-config:/data alpine cat /data/openclaw.json
docker run --rm -v openclaw_openclaw-config:/data alpine sh -c 'cat > /data/openclaw.json << '"'"'EOF'"'"'
{ ... }
EOF'
```

---

## Sandbox gotchas

OpenClaw runs each agent inside a Docker sandbox container. These are created and managed by the gateway, not by docker-compose. Several non-obvious behaviors can cause hours of debugging:

### Sandbox container lifecycle

Sandbox containers (`openclaw-sbx-agent-*`) are **not** managed by docker-compose. Running `docker compose down && docker compose up` restarts the gateway but does **not** recreate existing sandbox containers. They keep their old mounts, env vars, and config.

To force-recreate sandboxes after a config change:
```bash
# Stop and remove stale sandbox containers
docker stop $(docker ps -q --filter name=openclaw-sbx)
docker rm $(docker ps -aq --filter name=openclaw-sbx)
# Then restart the gateway
cd ~/code/spark-ai/openclaw && docker compose restart openclaw-gateway
```
The gateway will create fresh sandbox containers (lazily, on first message to each agent).

### Per-agent sandbox config overrides defaults entirely

If an agent in `agents.list` has its own `sandbox` block, it **completely replaces** `agents.defaults.sandbox`. This means settings like `workspaceAccess: "rw"` from defaults are silently lost. Always re-declare `workspaceAccess` in each agent's sandbox config.

### Environment variable security filter

OpenClaw strips environment variables whose names contain security-sensitive keywords (e.g., `PASSWORD`, `SECRET`, `TOKEN`). If you set `GOG_KEYRING_PASSWORD` in `sandbox.docker.env`, the agent will never see it.

**Workaround:** Use a wrapper script that reads the value from a file at runtime:
1. Write the password to a file on the host (e.g., `~/.config/gogcli/.gog_pw`)
2. Create a wrapper script that reads the file and exports the variable before calling the real binary
3. Bind-mount the wrapper as the tool name and the real binary under a different name

See `GOG.md` for a worked example with gog.

### Shared directories between agents

Each sandbox only sees its own `/workspace`. To share files between agents (e.g., an email outbox), add explicit bind mounts in the agent's `sandbox.docker.binds`:
```json
"sandbox": {
  "docker": {
    "dangerouslyAllowExternalBindSources": true,
    "binds": [
      "/home/YOUR_USER/code/spark-ai-agents/shared:/shared:rw"
    ]
  }
}
```
The left side must be the **host path**. The right side is where it appears inside the sandbox.

> **Note (v2026.2.26+):** Bind targets under `/workspace` are now blocked — use a path
> outside `/workspace` (e.g. `/shared`). If the source path is outside the agent workspace
> directory, `dangerouslyAllowExternalBindSources: true` is also required.

### Absolute paths in agent markdown files

Agent `.md` files run inside the sandbox where the workspace is mounted at `/workspace/` and shared directories at `/shared/`. Always use **absolute container paths** — never relative paths.

**Wrong:** `../shared/outbox/` — silently resolves to the wrong directory inside the container.
**Right:** `/shared/outbox/` — always resolves correctly regardless of working directory.

Keep a `PATHS.md` in each agent workspace as the single source of truth for all paths referenced across markdown files. Other `.md` files should reference `PATHS.md` rather than hard-coding paths — this makes corrections a one-file change and prevents the same path from drifting to different values across files.
