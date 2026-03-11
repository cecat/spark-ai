# OpenClaw on NVIDIA DGX Spark

vLLM serving Qwen3-Coder-Next-FP8 + OpenClaw agent. Model API is Docker-internal only. OpenClaw is Tailscale-only. See `TROUBLESHOOT.md` for fixes, `PLAN.md` for project status, `openclaw/SLACK_README.md` for Slack integration.

---

## Architecture

```
[Your Mac via Tailscale]
    |
    v  port 18789, Tailscale IP only
[OpenClaw container]
    |
    v  http://nim:8000/v1, Docker-internal only
[vLLM container: Qwen3-Coder-Next-FP8]
    |
    v
[GB10 GPU + 128GB unified memory]
```

> **Model throughput note:** Qwen3-Coder-Next-FP8 runs at ~50 tps on the DGX Spark GB10.
> This is adequate for interactive chat and async workloads, but requires active session
> management: OpenClaw sends the full conversation history on every inference call, and
> prefill time grows with context size. Without daily session resets, a busy channel
> accumulates enough history to cause multi-minute delays within a few weeks.
> See Step 14 and `TROUBLESHOOT.md` → Slack latency for details.

---

## Repository structure

Two repos:

**`spark-ai`** (this repo, public) — infrastructure: Docker compose files, `.env.example`, docs.

**`spark-ai-agents`** (separate private repo) — agent workspaces: markdown files defining each agent's identity, personality, memory, and tools. Clone to `~/code/spark-ai-agents/` alongside this repo.

The entire `spark-ai-agents/` directory is mounted into the OpenClaw container. Each agent gets its own subdirectory there. Adding a new agent means creating a new subdirectory and registering it in the dashboard — no changes to `docker-compose.yml` needed.

```
~/code/
├── spark-vllm-docker/           # eugr community vLLM build (cloned separately)
├── spark-ai/                    # this repo
│   ├── README.md
│   ├── TROUBLESHOOT.md
│   ├── PLAN.md
│   ├── TODO-PLAN.md             # design rationale for agent self-scheduling
│   ├── config.yaml              # per-agent model assignments — see "Model configuration"
│   ├── secrets.yaml             # not committed — API keys; copy from secrets.yaml.example
│   ├── secrets.yaml.example     # template for secrets.yaml
│   ├── apply-config.sh          # apply config.yaml and restart gateway
│   ├── revert-to-local.sh       # emergency fallback to local vLLM model
│   ├── check_openclaw.sh        # check for OpenClaw updates (no pull without --update)
│   ├── check_model.sh           # check for model updates (no download without --update)
│   ├── qwen3-coder-next/
│   │   ├── docker-compose.yml
│   │   └── .env                 # not committed — see Step 3
│   └── openclaw/
│       ├── docker-compose.yml
│       ├── ONBOARDING.md        # onboarding log and decision rationale
│       ├── SLACK_README.md      # Step 11: Slack integration guide
│       ├── GOG.md               # Step 12: Google Workspace (gog) setup
│       ├── GMAIL.md             # email workflow (outbox, approval, cron sending)
│       ├── TODO-IMPLEMENTATION.md  # Step 13: agent self-scheduling via TODO.md
│       ├── UPGRADE-2026.2.26.md
│       ├── openclaw-upgrade-prompt.md
│       └── .env                 # not committed — see Step 3
└── spark-ai-agents/             # private repo
    ├── main/                    # default agent workspace
    │   ├── IDENTITY.md
    │   ├── SOUL.md
    │   ├── USER.md
    │   ├── AGENTS.md
    │   ├── TOOLS.md
    │   ├── EMAIL.md
    │   ├── MEMORY.md
    │   ├── HEARTBEAT.md         # heartbeat checklist (email approval + TODO execution)
    │   ├── PATHS.md             # canonical path definitions (source of truth)
    │   ├── TODO.md              # scheduled task queue
    │   ├── CHANGELOG.md
    │   └── memory/              # daily memory files (auto-created by agent)
    ├── chattpc26/               # example second agent
    │   ├── IDENTITY.md
    │   ├── SOUL.md
    │   ├── USER.md
    │   ├── AGENTS.md
    │   ├── TOOLS.md
    │   ├── EMAIL.md
    │   ├── MEMORY.md
    │   ├── HEARTBEAT.md         # heartbeat checklist (TODO execution)
    │   ├── PATHS.md             # canonical path definitions (source of truth)
    │   ├── TODO.md              # scheduled task queue
    │   ├── URLS.md              # curated URLs for agent reference
    │   ├── CHANGELOG.md
    │   ├── memory/
    │   └── templates/           # email templates (JSON)
    ├── scripts/
    │   ├── send-approved-emails.sh  # cron: sends approved outbox emails via gog
    │   ├── check-todos.sh           # cron: marks due TODO items READY for heartbeat
    │   ├── monitor-sessions.sh      # cron: logs session file sizes every 5 min
    │   └── reset-sessions.sh        # cron: archives and clears large sessions at 4am
    └── shared/                  # cross-agent shared files
        ├── outbox/              # pending email JSON files
        ├── sent/                # sent email archive
        ├── rejected/            # rejected emails
        ├── todos/
        │   ├── todo.log         # append-only task execution log
        │   └── plans/           # complex task plan files (*.md)
        └── reports/
```

---

## First-time setup

### 1. Clone repos
```bash
cd ~/code
git clone https://github.com/eugr/spark-vllm-docker.git
git clone https://github.com/YOUR_USERNAME/spark-ai.git
git clone https://github.com/YOUR_USERNAME/spark-ai-agents.git
mkdir -p spark-ai-agents/main spark-ai-agents/shared/reports
```

### 2. Build the vLLM image
Source-built for GB10 SM121a kernel support — takes 20–40 min.
```bash
cd ~/code/spark-vllm-docker && ./build-and-copy.sh
docker images | grep vllm-node
```

### 3. Create .env files

These files are not committed (excluded by `.gitignore`). Create them manually.

`~/code/spark-ai/qwen3-coder-next/.env`:
```
HF_HUB_OFFLINE=0
```
Set to `0` for first run so vLLM can download the model. Flip to `1` after the model is fully cached — this prevents vLLM from making any outbound HuggingFace calls on subsequent starts, which is both faster and avoids accidental re-downloads or version drift.

`~/code/spark-ai/openclaw/.env`:
```
TAILSCALE_IP=<output of: tailscale ip -4>
OPENCLAW_WORKSPACE=/home/YOUR_USER/code/spark-ai-agents
```
`TAILSCALE_IP` binds the OpenClaw port to your Tailscale interface only — this is what prevents the gateway from being reachable on your LAN or the internet. `OPENCLAW_WORKSPACE` is the host path that gets mounted into the container as the agent workspace.

### 4. Download the model (~46GB, resumable)
```bash
pip install huggingface_hub --break-system-packages
read -s -p "HuggingFace token: " HF_TOKEN; echo
cat > /tmp/dl.py << 'PYEOF'
import os; from huggingface_hub import snapshot_download
snapshot_download(repo_id="Qwen/Qwen3-Coder-Next-FP8", token=os.environ["HF_TOKEN"])
PYEOF
HF_TOKEN="$HF_TOKEN" python3 /tmp/dl.py; unset HF_TOKEN; rm /tmp/dl.py
```

### 5. Fix OpenClaw volume permissions
Docker creates the volume as root; OpenClaw runs as uid 1000.
```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw_openclaw-config/_data
```

### 6. Run OpenClaw onboarding
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli onboard --no-install-daemon
```
Key answers: provider=vLLM, base URL=`http://nim:8000/v1`, key=`sk-dummy`, model=`Qwen/Qwen3-Coder-Next-FP8`, workspace=`/home/YOUR_USER/code/spark-ai-agents/main` (**use the host path — see Step 8**), bind=LAN, auth=Token. Save the dashboard token to a password manager.

### 7. Set up Tailscale Serve for HTTPS dashboard access
```bash
sudo tailscale set --operator=$USER
tailscale serve --bg http://$(tailscale ip -4):18789
tailscale serve status   # note your https://spark-ts.YOUR-TAILNET.ts.net URL
```

Then patch the gateway config to trust the Tailscale proxy:
```bash
cd ~/code/spark-ai/openclaw
docker compose exec openclaw-gateway sh -c "
cat /home/node/.openclaw/openclaw.json | \
node -e \"
const fs = require('fs');
let c = JSON.parse(fs.readFileSync('/dev/stdin','utf8'));
c.gateway.controlUi = {
  allowedOrigins: ['https://YOUR-HOSTNAME.YOUR-TAILNET.ts.net'],
  allowInsecureAuth: true,
  dangerouslyAllowHostHeaderOriginFallback: true
};
console.log(JSON.stringify(c, null, 2));
\" > /tmp/cfg.json && mv /tmp/cfg.json /home/node/.openclaw/openclaw.json
"
docker compose restart openclaw-gateway
```

Replace `YOUR-HOSTNAME.YOUR-TAILNET.ts.net` with the URL from `tailscale serve status`.

> **Note (v2026.2.26+):** The `allowedOrigins` field is now required — the gateway will
> crash on startup without it. If you see a crash loop with
> `non-loopback Control UI requires gateway.controlUi.allowedOrigins`, this is why.

### 8. Confirm agent workspace path — use host paths

In the dashboard go to **Settings → Config** and confirm the workspace uses **the host path**, not the gateway-internal path:
```json
"workspace": "/home/YOUR_USER/code/spark-ai-agents/main"
```

> **Why host paths?** The docker-compose mounts `OPENCLAW_WORKSPACE` at `/home/node/agents` inside the gateway container. But when OpenClaw spawns sandbox containers, it passes the workspace path directly to Docker as a bind-mount source. Docker resolves that path on the **host**, not inside the gateway. If you use `/home/node/agents/main`, Docker creates an empty, root-owned `/home/node/agents/main` directory on the host — completely separate from your real workspace. The sandbox ends up mounting an empty directory instead of your agent files.
>
> The fix has two parts:
> 1. Use host paths in openclaw.json (e.g., `/home/YOUR_USER/code/spark-ai-agents/main`)
> 2. Add a same-path mount in docker-compose.yml so the gateway can also read the workspace at the host path (already included in the docker-compose.yml in this repo — see the comment there)

### 9. Block container lateral movement
These rules prevent the OpenClaw container from reaching your LAN, other Tailscale nodes, or SSHing out to the internet. First confirm your Docker subnet:
```bash
docker network inspect qwen3-coder-next_nim_net | grep Subnet
```
Then apply the rules (adjust `DOCKER_SUBNET` if different from `172.18.0.0/16`):
```bash
DOCKER_SUBNET="172.18.0.0/16"
LAN_SUBNET="10.0.4.0/22"
TAILSCALE_CGNAT="100.64.0.0/10"
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $LAN_SUBNET -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $TAILSCALE_CGNAT -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -p tcp --dport 22 -j DROP
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```
> Note: `apt install iptables-persistent` triggers a full-screen purple ncurses dialog asking to save IPv4 and IPv6 rules. Answer **Yes** to both. This is normal.

Verify (must show 3 DROP rules — if no output, rules are not in place):
```bash
sudo iptables -L DOCKER-USER -n | grep DROP
```

### 10. Security hardening in openclaw.json
In the dashboard → **Settings → Config**, make these changes:

**Disable config writes** — prevents agents from modifying gateway config via chat:
```json
"commands": {
  "native": "auto",
  "nativeSkills": "auto",
  "config": false
},
```

**Disable per-channel config writes** — add inside `channels.slack`:
```json
"configWrites": false,
```

**Enable sandboxing globally:**
```json
"sandbox": { "mode": "all", "workspaceAccess": "rw" },
"agents": {
  "defaults": { ... },
  "list": [
    {
      "id": "main",
      "default": true,
      "workspace": "/home/YOUR_USER/code/spark-ai-agents/main",
      "tools": { "deny": [] },
      "sandbox": {
        "mode": "all",
        "workspaceAccess": "rw",
        "docker": {
          "network": "qwen3-coder-next_nim_net",
          "dangerouslyAllowExternalBindSources": true,
          "binds": [
            "/home/YOUR_USER/code/spark-ai-agents/shared:/shared:rw"
          ]
        }
      }
    },
    {
      "id": "chattpc26",
      "workspace": "/home/YOUR_USER/code/spark-ai-agents/chattpc26",
      "tools": { "deny": [] },
      "sandbox": {
        "mode": "all",
        "workspaceAccess": "rw",
        "docker": {
          "network": "qwen3-coder-next_nim_net",
          "dangerouslyAllowExternalBindSources": true,
          "binds": [
            "/home/YOUR_USER/code/spark-ai-agents/shared:/shared:rw"
          ]
        }
      }
    }
  ]
}
```

> **Important:** You must include `"workspaceAccess": "rw"` in **each agent's** `sandbox` block, not just in `agents.defaults`. Per-agent `sandbox` config completely overrides the defaults — if you omit `workspaceAccess`, the sandbox will be read-only even if the default says otherwise.

> **Important (v2026.2.26+):** Bind-mount targets under `/workspace` are now blocked.
> Use paths outside `/workspace` (e.g. `/shared`). Bind-mount sources outside the agent
> workspace root also require `dangerouslyAllowExternalBindSources: true`.

Both agents get sandbox exec — exec runs only inside ephemeral sandbox containers, not
on the host. See `GOG.md` for the full gog/Google credential configuration.

### 11. Connect Slack
See `openclaw/SLACK_README.md` for the complete walkthrough. Summary:
- Create a Slack app at api.slack.com/apps with Socket Mode enabled
- Add required bot scopes (see SLACK_README.md — do not add `assistant:write`)
- Add bot token and app token to openclaw.json under `channels.slack`
- For multiple agents, use `bindings` in openclaw.json to route specific channels to specific agents

> **Slack is a prerequisite for steps 12 and 13.** Steps 12 (Google/gog) and 13 (TODO scheduling) are independent of each other — you can do either, both, or neither.

### 12. Connect Google Workspace via gog (optional)
Required if agents need access to Gmail, Google Drive, Sheets, Docs, or Contacts.
See `openclaw/GOG.md` for the complete walkthrough. Summary:
- Create a Google Cloud project and enable the APIs you need (Drive, Sheets, Docs, Gmail, People)
- Configure OAuth consent screen and download credentials JSON
- Install `gog` on the Spark host and run `gog auth login` to authenticate
- Add the gog binary and credential bind mounts to the agent's sandbox config in openclaw.json
- See `openclaw/GMAIL.md` for the email outbox workflow (queuing, approval, cron sending)

### 13. Enable agent self-scheduling via TODO.md (optional)
Allows agents to schedule future tasks ("remind me at 5pm", "send emails on Monday") without sleeping or blocking. Requires a heartbeat to be configured on the agent.
See `openclaw/TODO-IMPLEMENTATION.md` for the complete walkthrough. Summary:
- Create `TODO.md` in each agent workspace
- Create `shared/todos/` directory structure
- Install `scripts/check-todos.sh` and add a crontab entry (`*/5 * * * *`)
- Set heartbeat interval to 15 min in openclaw.json for agents that use TODO
- Add the READY-item execution step to each agent's `HEARTBEAT.md`
- Add the deferred-task rule to each agent's `SOUL.md`

### 14. Set up session management (recommended for local models)

OpenClaw stores full conversation history in session files and sends it all to the model on every message. On a ~50 tps local model this causes multi-minute delays as history accumulates. A daily cron job clears sessions before they grow large enough to matter.

Two scripts in `spark-ai-agents/scripts/` handle this (already committed — just add the crontab entries):

```bash
# Add to crontab on Spark: crontab -e
*/5 * * * * /home/catlett/code/spark-ai-agents/scripts/monitor-sessions.sh >> /home/catlett/code/spark-ai-agents/shared/sessions/cron.log 2>&1
0 4 * * * /home/catlett/code/spark-ai-agents/scripts/reset-sessions.sh >> /home/catlett/code/spark-ai-agents/shared/sessions/cron.log 2>&1
```

Create the required directories on Spark:
```bash
mkdir -p ~/code/spark-ai-agents/shared/sessions ~/code/spark-ai-agents/shared/session-archives
```

The reset script archives any session `.jsonl` file above 512 KB to `shared/session-archives/YYYY-MM-DD/` and truncates it to zero. The agent starts fresh from its structured `.md` files on the next heartbeat or user message. Archives are kept on the host if you ever need to review past conversation history.

See `TROUBLESHOOT.md` → Slack latency and `spark-ai-agents/RUNBOOK.md` → Session Management for background and manual reset commands.

---

## Model configuration

By default all agents use the local vLLM model running on the Spark. `config.yaml`
controls which model each agent uses. You can switch any agent to a remote API
(e.g. Anthropic Claude) without touching `docker-compose.yml` or `openclaw.json`
by hand.

### Setup (first time)

```bash
cp secrets.yaml.example secrets.yaml
vim secrets.yaml        # paste your Anthropic API key if using a remote model
```

`secrets.yaml` is gitignored — it never leaves the Spark.

### config.yaml

The default config uses the local model for all agents:

```yaml
agents:
  main:
    model: vllm/Qwen/Qwen3-Coder-Next-FP8
  chattpc26:
    model: vllm/Qwen/Qwen3-Coder-Next-FP8
```

To switch an agent to Anthropic Claude, change its model:

```yaml
agents:
  main:
    model: anthropic/claude-sonnet-4-6
  chattpc26:
    model: vllm/Qwen/Qwen3-Coder-Next-FP8
```

**Supported providers:**

| Provider | Model format | Requires |
|---|---|---|
| Local vLLM | `vllm/Qwen/Qwen3-Coder-Next-FP8` | Nothing — always available |
| Anthropic | `anthropic/claude-haiku-4-5` | `anthropic_api_key` in `secrets.yaml` |
| Anthropic | `anthropic/claude-sonnet-4-6` | `anthropic_api_key` in `secrets.yaml` |
| Anthropic | `anthropic/claude-opus-4-6` | `anthropic_api_key` in `secrets.yaml` |

### Applying changes

After editing `config.yaml`:

```bash
./apply-config.sh --dry-run   # preview what will change
./apply-config.sh             # apply and restart gateway
```

The script patches `openclaw.json` in the Docker volume directly — no manual config
editing needed. The gateway restarts automatically.

### Emergency revert to local model

If anything goes wrong after switching to a remote model:

```bash
./revert-to-local.sh
```

This removes all remote-model config from `openclaw.json` and restarts the gateway.
No config files needed — safe to run any time.

### Note on vLLM and memory

The Spark's 128 GB is unified CPU+GPU memory. vLLM loads the model on startup and
holds ~107 GB regardless of whether agents are actively using it. If all agents are
switched to Anthropic, you can stop vLLM to reclaim that memory:

```bash
cd ~/code/spark-ai/qwen3-coder-next && docker compose down
```

Restart it again before switching any agent back to `vllm/...`.

---

## Adding a new agent

1. Create a subdirectory in `spark-ai-agents/`: `mkdir ~/code/spark-ai-agents/new-agent`
2. Populate it with the standard markdown files (copy from `main/` as a template). Create a `PATHS.md` defining all absolute container paths the agent uses (see `main/PATHS.md`). All other `.md` files should reference `PATHS.md` rather than hard-coding paths. Always use **absolute** paths (e.g. `/shared/`) — never relative paths like `../shared/`, which silently resolve to the wrong location inside the sandbox.
3. In the dashboard → **Settings → Config**, add the agent to `agents.list`:
```json
{
  "id": "new-agent",
  "workspace": "/home/YOUR_USER/code/spark-ai-agents/new-agent",
  "sandbox": { "mode": "all", "workspaceAccess": "rw" }
}
```
   Use the **host path** for workspace (see Step 8). Always include `workspaceAccess: "rw"` — per-agent sandbox config overrides defaults.
4. To route a specific Slack channel to this agent, add a binding and add the channel to the allowlist — see `openclaw/SLACK_README.md`
5. If the agent needs `exec` (e.g., for gog), add per-agent `sandbox.docker` config — do NOT disable sandbox. See `GOG.md`.
6. After adding the agent to config, **remove any stale sandbox containers** and restart the gateway (see `TROUBLESHOOT.md` → Sandbox gotchas → Sandbox container lifecycle).

---

## Multi-agent setup

OpenClaw supports multiple agents behind a single Slack app. In `openclaw.json`:

- `agents.list` — registers each agent with its workspace path
- One agent is marked `"default": true` — handles all unrouted messages including DMs
- `bindings` — routes specific Slack channels to specific agents
- `channels.slack.channels` — allowlist of channel IDs the bot will respond in (required when `groupPolicy: "allowlist"`)

See `openclaw/SLACK_README.md` for a worked example.

---

## Daily use

### Start
```bash
cd ~/code/spark-ai/qwen3-coder-next && docker compose up -d   # vLLM first
cd ~/code/spark-ai/openclaw && docker compose up -d            # then OpenClaw
```
vLLM takes ~2 min. Dashboard: `https://spark-ts.YOUR-TAILNET.ts.net/#token=YOUR_TOKEN`

### Stop
```bash
cd ~/code/spark-ai/openclaw && docker compose down
cd ~/code/spark-ai/qwen3-coder-next && docker compose down
```

### Retrieve dashboard token
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli dashboard --no-open
```

### Approve a Slack pairing request
```bash
docker exec openclaw-gateway node dist/index.js pairing approve slack <CODE>
```

> **Note:** Use `docker exec openclaw-gateway` rather than `docker compose run --rm openclaw-cli`. The standalone CLI container cannot reach the gateway over WebSocket when the gateway is bound to a Tailscale IP.

---

## Security checklist
```bash
ss -ltnp | grep :8000          # must show nothing (vLLM not exposed to host)
ss -tlnp | grep 18789          # must show TAILSCALE_IP:18789, not 0.0.0.0
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file
sudo iptables -L DOCKER-USER -n | grep DROP   # must show 3 DROP rules
```

---

## Checking for updates

Two separate scripts — neither downloads or pulls anything without `--update`:

```bash
~/code/spark-ai/check_openclaw.sh        # check OpenClaw image version
~/code/spark-ai/check_model.sh           # check Qwen model version
```

**`check_openclaw.sh`:** Fetches the GHCR manifest digest via a HEAD request (no pull).
Compares against your running container's digest. With `--update`: pulls the new image
and generates a ready-to-use prompt at `/tmp/openclaw-upgrade-prompt.md` with your
current `openclaw.json` embedded — paste in the release notes and take it to Claude
for impact analysis before restarting.

**`check_model.sh`:** Uses the HuggingFace hub API to compare local vs. remote commit hash.
No download occurs. With `--update`: prompts for your HF token and runs `snapshot_download`.

Your running gateway is **not affected** by either script — it only changes when you
explicitly restart it.

### Update vLLM image
```bash
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
cd ~/code/spark-ai/openclaw && docker compose down
cd ~/code/spark-ai/qwen3-coder-next && docker compose down && docker compose up -d
cd ~/code/spark-ai/openclaw && docker compose up -d
```

---

See `TROUBLESHOOT.md` for error fixes, config gotchas, and sandbox behavior. See `PLAN.md` for project status and roadmap.
