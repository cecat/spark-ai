# OpenClaw Upgrade Guide: 2026.2.17 → 2026.2.26

---

## Part 1: General Breaking Changes

These affect any OpenClaw installation upgrading to 2026.2.26.

---

### 1. Control UI requires `allowedOrigins`

**Symptom**: Gateway crash loop on startup:
```
Gateway failed to start: Error: non-loopback Control UI requires gateway.controlUi.allowedOrigins
```

**Fix**: Add `allowedOrigins` to the `gateway.controlUi` section of `openclaw.json`:
```json
"controlUi": {
  "allowedOrigins": ["https://your-gateway-hostname"]
}
```

---

### 2. Dashboard requires device pairing

**Symptom**: Dashboard loads but shows "pairing required, health offline, version n/a". The
existing `#token=...` URL still handles authentication but the browser must now also be
registered as a paired device.

**Fix**: Approve the pending device pairing request via the CLI:
```bash
# List pending requests
node dist/index.js devices list

# Approve by Request UUID
node dist/index.js devices approve <request-uuid>
```

**Note**: `pairing list` / `pairing approve` are for Slack DM pairing, not the Control UI.
Use `devices list` / `devices approve` for the dashboard.

---

### 3. Sandbox blocks bind mounts targeting `/workspace`

**Symptom**: Agent fails with:
```
Sandbox security: bind mount "...:/workspace/shared:rw" targets reserved container path
"/workspace" (resolved target: "/workspace/shared"). This can shadow OpenClaw sandbox mounts.
```

**Fix**: Change the bind-mount target from any path under `/workspace` to a path outside it.
In `openclaw.json`, for each agent's `sandbox.docker.binds`:
```
BEFORE: "/host/path:/workspace/shared:rw"
AFTER:  "/host/path:/shared:rw"
```

Then update all agent instruction files (MEMORY.md, HEARTBEAT.md, etc.) to reference the new
path wherever the old one appeared.

---

### 4. Sandbox blocks bind-mount sources outside the agent workspace

**Symptom**: After fixing issue 3, agents may still fail with:
```
Sandbox security: bind mount source "/host/path" is outside allowed roots
(/path/to/agent-workspace). Use a dangerous override only when you fully trust this runtime.
```

The new version restricts bind-mount *sources* to paths within each agent's workspace
directory. Any shared or credential directory that lives outside the workspace root will
be blocked.

**Fix**: Add `dangerouslyAllowExternalBindSources: true` to each affected agent's
`sandbox.docker` section in `openclaw.json`:
```json
"sandbox": {
  "docker": {
    "dangerouslyAllowExternalBindSources": true
  }
}
```

This flag is undocumented as of 2026.2.26 — found by grepping the gateway source.

---

### Post-Upgrade Checklist (General)

1. Pull the new image and restart: `docker compose down && docker compose up -d`
2. If the gateway crashes on startup, add `allowedOrigins` to `controlUi` and restart (issue 1)
3. Open the dashboard — if it shows "pairing required", approve the device via CLI (issue 2)
4. If agents report sandbox bind-mount errors, update bind targets and/or add
   `dangerouslyAllowExternalBindSources` (issues 3 and 4)
5. Verify agents can use sandbox tools (read, write, exec) after any sandbox config changes

---

---

## Part 2: Setup-Specific Issues

These were specific to this install: NVIDIA DGX Spark ("spark-ts" via Tailscale SSH),
running two agents (`main` and `chattpc26`) with GOG credentials and a shared bind mount,
gateway exposed via Tailscale reverse proxy.

---

### 5. CLI container cannot reach gateway via WebSocket

**Symptom**: `docker compose run openclaw-cli devices list` fails with a WebSocket error.
The gateway binds to the Tailscale IP, which is not routable from inside the Docker network,
so the standalone CLI container can't connect.

**Workaround**: Run CLI commands from inside the *running gateway container* instead:
```bash
docker exec openclaw-gateway node dist/index.js <command>
```

This was needed for issue 2 (device pairing approval) specifically.

---

### 6. Stale session snapshot cached `sandbox.mode = "off"`

**Symptom**: The `main` agent reported "Tool exec not found" despite `exec` being available.
`chattpc26` was unaffected. Restarting the gateway and changing config had no effect.

**Root cause**: v2026.2.23 introduced **bootstrap file snapshot caching** per session key.
The `systemPromptReport` in `sessions.json` caches the sandbox mode and tool list from the
run that created the session. During debugging, `sandbox.mode` had been temporarily set to
`"off"` on the main agent. This caused the session `agent:main:main` to cache:
```json
"sandbox": { "mode": "off", "sandboxed": false }
```
When the config was changed back to `mode: "all"`, the cached snapshot persisted. The gateway
kept serving main as if sandbox were off — giving it direct-mode tools (browser, canvas, etc.)
but no sandbox tools (read, write, edit, exec), because the gateway runs in Docker and cannot
provide direct fs/exec access.

**Fix**:
1. Stop gateway: `docker compose stop`
2. Delete all main agent session data:
   ```bash
   docker run --rm -v openclaw_openclaw-config:/data alpine sh -c \
     "rm -f /data/agents/main/sessions/*.jsonl && echo {} > /data/agents/main/sessions/sessions.json"
   ```
3. Clear sandbox registry (forces fresh container):
   ```bash
   docker run --rm -v openclaw_openclaw-config:/data alpine sh -c \
     'echo {"entries":[]} > /data/sandbox/containers.json'
   docker rm -f $(docker ps -aq --filter name=openclaw-sbx-agent-main)
   ```
4. Start gateway: `docker compose start`

The new session correctly picked up `sandbox.mode = "all"` and received all sandbox tools.
Exec was tested successfully: `exec: ls /shared/outbox/` returned the expected directory
listing.

**Key lesson — `docker rm -f` is not enough to reset a sandbox.** OpenClaw persists sandbox
state in `containers.json` inside the config volume. To truly reset a sandbox, all three
of the following are required:

1. `docker rm -f <container>` — removes the Docker container
2. Clear `containers.json` — removes OpenClaw's internal sandbox tracking
3. Delete session files + `sessions.json` — removes cached tool-list snapshots

Without all three, OpenClaw will recreate the container from stale metadata and/or reuse
cached tool lists from previous runs.

---

### 7. Agent permissions were unequal

**Context**: `main` had been configured with a restricted tool set to limit what it could do.
After the upgrade, both agents were equalized so `main` has identical `sandbox.docker` config
to `chattpc26`. They now differ only in workspace path and `.md` instruction files.

**Final sandbox config (both agents)**:

| Setting | Value |
|---|---|
| sandbox.mode | `all` |
| sandbox.workspaceAccess | `rw` |
| sandbox.docker.network | `qwen3-coder-next_nim_net` |
| sandbox.docker.env | `GOG_KEYRING_BACKEND=file`, `GOG_ACCOUNT=tpc26agent@gmail.com`, `HOME=/tmp` |
| sandbox.docker.binds | GOG credentials + `shared:/shared:rw` |
| sandbox.docker.dangerouslyAllowExternalBindSources | `true` |
| tools.deny | `[]` (empty) |

---

### Operational Procedures (This Install)

#### How to edit `openclaw.json`

```bash
ssh spark-ts 'python3 << "PYEOF"
import json, subprocess
raw = subprocess.check_output(["docker", "run", "--rm", "-v",
    "openclaw_openclaw-config:/data", "alpine", "cat", "/data/openclaw.json"])
cfg = json.loads(raw)
# ... modify cfg ...
with open("/tmp/oc-fixed.json", "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
PYEOF
docker run --rm -v openclaw_openclaw-config:/data \
  -v /tmp/oc-fixed.json:/tmp/cfg.json alpine \
  cp /tmp/cfg.json /data/openclaw.json'
```

Then restart:
```bash
ssh spark-ts "cd ~/code/spark-ai/openclaw && docker compose restart"
```

#### How to run CLI commands

Always from inside the running gateway container:
```bash
ssh spark-ts "docker exec openclaw-gateway node dist/index.js <command>"
```

#### Config backup

A backup of the working post-upgrade config is saved at
`~/code/spark-ai-agents/2026-03-02-openclaw.json` on Spark.

---

### Full Config State (Post-Upgrade)

#### `main` agent

- **workspace**: `/home/catlett/code/spark-ai-agents/main`
- **default**: `true`
- **heartbeat**: every 1h, active 08:00–22:00 America/Chicago
- HEARTBEAT.md instructs agent to use `exec: ls /shared/outbox/`

#### `chattpc26` agent

- **workspace**: `/home/catlett/code/spark-ai-agents/chattpc26`

#### Gateway

| Setting | Value |
|---|---|
| port | `18789` |
| bind | `lan` |
| controlUi.allowedOrigins | `["https://spark-ts.barking-micro.ts.net"]` |
| controlUi.allowInsecureAuth | `true` |
| controlUi.dangerouslyAllowHostHeaderOriginFallback | `true` |
| auth.mode | `token` |
