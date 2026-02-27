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

---

## Repository structure

Two repos:

**`spark-ai`** (this repo, public) — infrastructure: Docker compose files, `.env.example`, docs.

**`spark-ai-agents`** (separate private repo) — agent workspaces: markdown files defining each agent's identity, personality, memory, and tools. Clone to `~/code/spark-ai-agents/` alongside this repo.

The entire `spark-ai-agents/` directory is mounted into the OpenClaw container. Each agent gets its own subdirectory there. Adding a new agent means creating a new subdirectory and registering it in the dashboard — no changes to `docker-compose.yml` needed.

```
~/code/
├── spark-vllm-docker/       # eugr community vLLM build (cloned separately)
├── spark-ai/                # this repo
│   ├── qwen3-coder-next/
│   │   ├── docker-compose.yml
│   │   └── .env             # not committed — see Step 3
│   └── openclaw/
│       ├── docker-compose.yml
│       ├── SLACK_README.md
│       └── .env             # not committed — see Step 3
└── spark-ai-agents/         # private repo
    ├── main/                # default agent workspace
    │   ├── IDENTITY.md
    │   ├── SOUL.md
    │   ├── USER.md
    │   ├── AGENTS.md
    │   ├── TOOLS.md
    │   └── HEARTBEAT.md
    ├── chattpc26/           # example second agent
    └── shared/
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
Key answers: provider=vLLM, base URL=`http://nim:8000/v1`, key=`sk-dummy`, model=`Qwen/Qwen3-Coder-Next-FP8`, workspace=`/home/node/agents/main`, bind=LAN, auth=Token. Save the dashboard token to a password manager.

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
c.gateway.controlUi = { allowInsecureAuth: true };
c.gateway.auth.allowTailscale = true;
c.gateway.trustedProxies = ['$(tailscale ip -4)'];
console.log(JSON.stringify(c, null, 2));
\" > /tmp/cfg.json && mv /tmp/cfg.json /home/node/.openclaw/openclaw.json
"
docker compose restart openclaw-gateway
```

### 8. Confirm agent workspace path
In the dashboard go to **Settings → Config** and confirm:
```json
"workspace": "/home/node/agents/main"
```
The docker-compose.yml mounts `OPENCLAW_WORKSPACE` at `/home/node/agents`, so each agent subdirectory is accessible at `/home/node/agents/<agent-name>`.

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

**Disable exec/shell tools** — prevents agents from running commands even if prompted to:
```json
"tools": {
  "deny": ["exec", "process", "bash"]
},
```

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

**Enable sandboxing** — add inside `agents.defaults`:
```json
"sandbox": {
  "mode": "all",
  "workspaceAccess": "rw"
}
```

### 11. Connect Slack
See `openclaw/SLACK_README.md` for the complete walkthrough. Summary:
- Create a Slack app at api.slack.com/apps with Socket Mode enabled
- Add required bot scopes (see SLACK_README.md — do not add `assistant:write`)
- Add bot token and app token to openclaw.json under `channels.slack`
- For multiple agents, use `bindings` in openclaw.json to route specific channels to specific agents

---

## Adding a new agent

1. Create a subdirectory in `spark-ai-agents/`: `mkdir ~/code/spark-ai-agents/new-agent`
2. Populate it with the standard markdown files (copy from `main/` as a template)
3. In the dashboard → **Settings → Config**, add the agent to `agents.list`:
```json
{ "id": "new-agent", "workspace": "/home/node/agents/new-agent" }
```
4. To route a specific Slack channel to this agent, add a binding and add the channel to the allowlist — see `openclaw/SLACK_README.md`

---

## Multi-agent setup

OpenClaw supports multiple agents behind a single Slack app. In `openclaw.json`:

- `agents.list` — registers each agent with its workspace path
- One agent is marked `"default": true` — handles all unrouted messages including DMs
- `bindings` — routes specific Slack channels to specific agents
- `channels.slack.channels` — allowlist of channel IDs the bot will respond in (required when `groupPolicy: "allowlist"`)

See `openclaw/SLACK_README.md` for a worked example.

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
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli pairing approve slack <CODE>
```

---

## Security checklist
```bash
ss -ltnp | grep :8000          # must show nothing (vLLM not exposed to host)
ss -tlnp | grep 18789          # must show TAILSCALE_IP:18789, not 0.0.0.0
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file
sudo iptables -L DOCKER-USER -n | grep DROP   # must show 3 DROP rules
```

---

## Update vLLM image
```bash
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
cd ~/code/spark-ai/openclaw && docker compose down
cd ~/code/spark-ai/qwen3-coder-next && docker compose down && docker compose up -d
cd ~/code/spark-ai/openclaw && docker compose up -d
```

---

See `TROUBLESHOOT.md` for error fixes. See `PLAN.md` for project status and roadmap.
