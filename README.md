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

The OpenClaw container mounts the entire `spark-ai-agents/` directory, so adding an agent never requires changing `docker-compose.yml` — add a subfolder and register it in the dashboard.

```
~/code/
├── spark-vllm-docker/       # eugr community vLLM build (cloned separately)
├── spark-ai/                # this repo
│   ├── qwen3-coder-next/
│   │   ├── docker-compose.yml
│   │   ├── .env.example
│   │   └── .env             # not committed
│   └── openclaw/
│       ├── docker-compose.yml
│       ├── SLACK_README.md
│       ├── .env.example
│       └── .env             # not committed
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

`~/code/spark-ai/qwen3-coder-next/.env`:
```
HF_HUB_OFFLINE=0
```
Flip to `1` after confirming model is cached.

`~/code/spark-ai/openclaw/.env`:
```
TAILSCALE_IP=<output of: tailscale ip -4>
OPENCLAW_WORKSPACE=/home/YOUR_USER/code/spark-ai-agents
```

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
Note: the docker-compose.yml mounts `OPENCLAW_WORKSPACE` at `/home/node/agents`, so each agent subfolder is at `/home/node/agents/<agent-name>`.

### 9. Block container lateral movement
```bash
DOCKER_SUBNET="172.18.0.0/16"   # confirm: docker network inspect qwen3-coder-next_nim_net | grep Subnet
LAN_SUBNET="10.0.4.0/22"
TAILSCALE_CGNAT="100.64.0.0/10"
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $LAN_SUBNET -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $TAILSCALE_CGNAT -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -p tcp --dport 22 -j DROP
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```

### 10. Connect Slack
See `openclaw/SLACK_README.md` for the complete walkthrough. Summary:
- Create a Slack app at api.slack.com/apps with Socket Mode enabled
- Add required bot scopes (see SLACK_README.md for exact list — do not add `assistant:write`)
- Add bot token and app token to openclaw.json under `channels.slack`
- For multiple agents, use `bindings` in openclaw.json to route specific channels to specific agents

---

## Multi-agent setup

OpenClaw supports multiple agents behind a single Slack app. Each agent has its own workspace directory under `spark-ai-agents/`. In `openclaw.json`:

- `agents.list` — registers each agent with its workspace path
- One agent is marked `"default": true` — handles all unrouted messages including DMs
- `bindings` — routes specific Slack channels to specific agents
- `channels.slack.channels` — allowlist of channel IDs the bot will respond in (required when `groupPolicy: "allowlist"`)

See `openclaw/SLACK_README.md` for a worked example with `main` (default) and `chattpc26` agents.

---

## openclaw.json — key config notes

A few things learned the hard way:

- `gateway.auth.mode` must be `"token"` with a `"token"` field — `"password"` mode requires a separate `"password"` field and will crash-loop the gateway if misconfigured
- `channels.slack.channels` is an **object** keyed by channel ID, not an array: `{ "C123": { "allow": true } }`
- `channels.slack.groupPolicy: "allowlist"` requires every channel to be explicitly listed — an empty allowlist means the bot responds nowhere
- `streaming: false` is required to prevent use of Slack's native streaming API, which fails with `missing_recipient_team_id` without the `assistant:write` scope
- Do not add `assistant:write` scope to the Slack app — it enables Slack's AI agent streaming API which silently drops messages in this setup
- `webhookPath` should be kept as `/slack/events` even in Socket Mode — the config validator requires it
- When editing openclaw.json directly (e.g. to fix a crash loop), use: `docker run --rm -v openclaw_openclaw-config:/data alpine sh -c 'cat > /data/openclaw.json << EOF ... EOF'`

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
