# OpenClaw on NVIDIA DGX Spark

vLLM serving Qwen3-Coder-Next-FP8 + OpenClaw agent. Model API is Docker-internal only. OpenClaw is Tailscale-only. See `TROUBLESHOOT.md` for fixes, `ONBOARDING.md` for the OpenClaw wizard walkthrough, `PLAN.md` for project status.

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

This setup uses two repos:

**`spark-ai`** (this repo, public) — infrastructure only: Docker compose files, `.env.example`, documentation. Safe to share.

**`spark-ai-agents`** (separate private repo) — agent workspaces: the markdown files that define each agent's identity, personality, memory, and tools. Private because it contains personal context and evolves independently of infrastructure. Clone it to `~/code/spark-ai-agents/` alongside this repo.

The OpenClaw container mounts the entire `spark-ai-agents/` directory at once, so adding a new agent never requires changing `docker-compose.yml` — just add a new subfolder to `spark-ai-agents/` and register it in the OpenClaw dashboard.

```
~/code/
├── spark-vllm-docker/       # eugr community vLLM build (cloned separately)
├── spark-ai/                # this repo
└── spark-ai-agents/         # your private agent configs repo
    ├── main/                # default personal assistant agent
    │   ├── IDENTITY.md      # name, emoji, vibe
    │   ├── SOUL.md          # personality and behavior
    │   ├── USER.md          # about you
    │   ├── AGENTS.md        # operating instructions
    │   ├── TOOLS.md         # tool notes
    │   └── HEARTBEAT.md     # periodic task checklist
    ├── tpc-reporter/        # example second agent
    └── shared/              # files shared across agents
        └── reports/
```

---

## First-time setup (do once)

### 1. Clone all three repos
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
```bash
cp ~/code/spark-ai/qwen3-coder-next/.env.example ~/code/spark-ai/qwen3-coder-next/.env
# Set HF_HUB_OFFLINE=0 (flip to 1 after model download)

cp ~/code/spark-ai/openclaw/.env.example ~/code/spark-ai/openclaw/.env
# Set TAILSCALE_IP=$(tailscale ip -4)
# Set OPENCLAW_WORKSPACE=/home/YOUR_USER/code/spark-ai-agents
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
See `ONBOARDING.md` for every question and answer. Short version:
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli onboard --no-install-daemon
```
Key answers: provider=vLLM, base URL=`http://nim:8000/v1`, key=`sk-dummy`,
model=`Qwen/Qwen3-Coder-Next-FP8`, workspace=`/home/node/workspace/main`, bind=LAN, auth=Token.
Save the dashboard token to 1Password as "OpenClaw Gateway Token".

### 7. Set up Tailscale Serve for HTTPS dashboard access
The Control UI requires HTTPS. Do this once:
```bash
sudo tailscale set --operator=$USER
tailscale serve --bg http://$(tailscale ip -4):18789
tailscale serve status   # note your https://spark-ts.YOUR-TAILNET.ts.net URL
```

Then patch the gateway config to trust the proxy:
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

### 8. Set agent workspace path in dashboard
In the OpenClaw dashboard go to **Settings → Config** and confirm:
```json
"workspace": "/home/node/workspace/main"
```
Save. The gateway will restart automatically.

### 9. Block container lateral movement (iptables)
```bash
DOCKER_SUBNET="172.18.0.0/16"   # confirm: docker network inspect qwen3-coder-next_nim_net | grep Subnet
LAN_SUBNET="10.0.4.0/22"        # your LAN subnet
TAILSCALE_CGNAT="100.64.0.0/10"
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $LAN_SUBNET -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $TAILSCALE_CGNAT -j DROP
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -p tcp --dport 22 -j DROP
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```

### 10. MacBook SSH hardening
Reverse SSH (Spark → Mac) is not needed. On your Mac, remove the Spark's key from `~/.ssh/authorized_keys`.

---

## Daily use

### Start
```bash
cd ~/code/spark-ai/qwen3-coder-next && docker compose up -d   # vLLM first
cd ~/code/spark-ai/openclaw && docker compose up -d            # then OpenClaw
```
vLLM takes ~2 min to be ready. Dashboard: `https://spark-ts.YOUR-TAILNET.ts.net/#token=YOUR_TOKEN`

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

### Connect Slack
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli channels add --channel slack --token YOUR_SLACK_BOT_TOKEN
```

### Add a new agent
1. `mkdir ~/code/spark-ai-agents/new-agent` and populate its markdown files
2. In the dashboard **Settings → Config** add the agent to `agents.list`:
```json
{ "id": "new-agent", "workspace": "/home/node/workspace/new-agent" }
```
3. Save. No docker-compose changes needed.

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

See `TROUBLESHOOT.md` for error fixes.
