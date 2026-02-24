# OpenClaw on a NVIDIA DGX Spark

This repo runs **Qwen3-Coder-Next-FP8** via community vLLM and **OpenClaw** on a DGX
Spark. The model API is reachable only from other containers on the same Docker network.
OpenClaw is reachable only from hosts on the same Tailscale network as the Spark.

Use any of this at your own risk.

---

## Repository layout

```
~/code/
├── spark-vllm-docker/           # eugr community vLLM build repo (cloned separately)
└── spark-ai/                    # this repo
    ├── README.md
    ├── PLAN.md
    ├── .gitignore
    ├── qwen3-coder-next/
    │   ├── docker-compose.yml   # vLLM inference service
    │   ├── .env.example         # committed — shows required variables
    │   └── .env                 # NOT committed — your actual values
    └── openclaw/
        ├── docker-compose.yml   # OpenClaw gateway service
        ├── .env.example         # committed — shows required variables
        └── .env                 # NOT committed — your actual values

~/.cache/huggingface/            # model weights (~46GB) — not in this repo
~/openclaw-workspace/            # folder OpenClaw is allowed to read/write
```

Model weights are large binary data and must not be committed to this repo.

---

## Architecture

```
[Tailscale]
    |
    v  (port 18789, Tailscale IP only — not 0.0.0.0)
[OpenClaw container]
    |
    | http://nim:8000/v1   (Docker-internal only, no host port exposed)
    v
[vLLM container: Qwen3-Coder-Next-FP8]
    |
    v
[GB10 GPU + 128GB unified memory]
```

> Goal: no secrets committed; no accidental LAN/Tailscale exposure

---

## Security warnings

**Read before proceeding.**

- Do not add a `ports:` section to the vLLM service. Publishing port 8000 will expose
  the model API to the host, LAN, and Tailscale network.
- The HuggingFace token must never be passed as a command-line argument, hardcoded into
  any file, or committed to version control. It will appear in `ps aux`. Always use
  `read -s` to set it in your shell environment only.
- The `~/.cache/huggingface` volume mount persists model weights. Do not replace it with
  a broader mount such as `~/` or `/home`.
- Do not mount `~/.ssh`, `/etc`, or any path containing credentials into any container.
- OpenClaw runs as non-root (`node` user, uid 1000). Do not override this.
- Your home directory and `~/.docker` should not be world-readable:
  ```bash
  chmod 700 ~ ~/.docker
  ```
- After the model is downloaded, set `HF_HUB_OFFLINE=1` in
  `qwen3-coder-next/.env` to block unnecessary outbound connections from the vLLM container.
- Rotate your HuggingFace token immediately if it ever appears in `ps aux` or shell
  history. Rotate at: https://huggingface.co/settings/tokens

---

## Prerequisites

### 1) Docker Engine + Docker Compose v2
```bash
docker version        # must show both Client and Server sections
docker compose version
```

### 2) NVIDIA Container Toolkit
```bash
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
# Expected: output showing GB10 GPU name and driver version
```

### 3) HuggingFace account + token
- Create a free account at https://huggingface.co
- Generate a **read-only** access token at https://huggingface.co/settings/tokens
- The token is passed at runtime only, never stored in this repo

### 4) Tailscale installed and active
```bash
tailscale ip -4
# Note this IP — you must set it in openclaw/docker-compose.yml before first use
```

---

## One-time setup: build the community vLLM image

The inference engine is **eugr's community vLLM build** (`github.com/eugr/spark-vllm-docker`),
a source-built vLLM with GB10 SM121a kernel support not present in NVIDIA's pre-built
images. It must be built locally once. This takes 20-40 minutes on the Spark.

```bash
cd ~/code
git clone https://github.com/eugr/spark-vllm-docker.git
cd spark-vllm-docker
./build-and-copy.sh

# Confirm the image exists
docker images | grep vllm-node
```

> Rebuild monthly to pick up vLLM and kernel patches:
> ```bash
> cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
> ```

---

## One-time setup: create the OpenClaw workspace folder

The volume mount in `openclaw/docker-compose.yml` gives the container access to exactly
one folder on the Spark host — nothing else. Do not point this at your home directory
or any path containing credentials.

```bash
mkdir -p ~/openclaw-workspace
```

---

## One-time setup: create your .env files

Each compose directory has a `.env.example` showing the required variables. Copy and
fill them in — these files are never committed to git.

**`qwen3-coder-next/.env`:**
```bash
cp ~/code/spark-ai/qwen3-coder-next/.env.example ~/code/spark-ai/qwen3-coder-next/.env
# Edit and set:
#   HF_HUB_OFFLINE=0   (flip to 1 after model is downloaded)
```

**`openclaw/.env`:**
```bash
cp ~/code/spark-ai/openclaw/.env.example ~/code/spark-ai/openclaw/.env
# Edit and set:
#   TAILSCALE_IP=       output of: tailscale ip -4
#   OPENCLAW_WORKSPACE= full path, e.g. /home/catlett/openclaw-workspace
```

Verify your Tailscale IP with:
```bash
tailscale ip -4
```

---

## qwen3-coder-next/docker-compose.yml

See the file at `qwen3-coder-next/docker-compose.yml`. Machine-specific values are in
`qwen3-coder-next/.env` (not committed).

**Do not edit the compose file** except to tune vLLM parameters. The one value you will
need to change over time is `HF_HUB_OFFLINE` — edit it in `.env`, not in the compose file:

```bash
# After model download is confirmed complete:
# Edit qwen3-coder-next/.env and change HF_HUB_OFFLINE=0 to HF_HUB_OFFLINE=1
# Then restart vLLM:
cd ~/code/spark-ai/qwen3-coder-next && docker compose up -d
```

Key parameters in the compose file:
- `--max-model-len 131072` — 128K context, proven-stable on a single Spark. The model
  supports 256K but the larger KV cache may cause OOM. Increase to 262144 only after
  confirming stability at 128K.
- `--gpu-memory-utilization 0.8` — reduce to `0.7` if you see OOM errors on startup.

---

## openclaw/docker-compose.yml

See the file at `openclaw/docker-compose.yml`. Machine-specific values are in
`openclaw/.env` (not committed):

```bash
TAILSCALE_IP=           # your Spark's Tailscale IP (tailscale ip -4)
OPENCLAW_WORKSPACE=     # full path e.g. /home/catlett/openclaw-workspace
```

Key points:
- Gateway port 18789 is bound to `${TAILSCALE_IP}` only — never `0.0.0.0`.
- `${OPENCLAW_WORKSPACE}` is the only host path mounted into the container, at
  `/home/node/workspace` inside the container.
- OpenClaw connects to vLLM via `http://nim:8000/v1` on the shared Docker network.
- vLLM must be started before OpenClaw so the shared network exists.

---

## First run: download the model

The model is ~46GB. Pre-download before starting the stack so you can monitor progress.

**WARNING:** Do not pass the token as a Python `-c` argument — it will appear in `ps aux`.
Use the script approach below.

```bash
# Install huggingface_hub if needed
pip install huggingface_hub --break-system-packages

# Set token securely — read -s does not echo and does not save to shell history
read -s -p "HuggingFace token: " HF_TOKEN; echo

# Write a temp script so the token stays in the environment, not in ps aux
cat > /tmp/hf_download.py << 'EOF'
import os, sys
from huggingface_hub import snapshot_download
token = os.environ.get("HF_TOKEN")
if not token:
    print("ERROR: HF_TOKEN not set"); sys.exit(1)
snapshot_download(repo_id="Qwen/Qwen3-Coder-Next-FP8", token=token)
print("Download complete.")
EOF

HF_TOKEN="$HF_TOKEN" python3 /tmp/hf_download.py
unset HF_TOKEN
rm /tmp/hf_download.py
```

The download is **resumable** — if interrupted, re-run and it continues from where it
left off. To run in the background and survive SSH disconnections:

```bash
read -s -p "HuggingFace token: " HF_TOKEN; echo
cat > /tmp/hf_download.py << 'EOF'
import os, sys
from huggingface_hub import snapshot_download
token = os.environ.get("HF_TOKEN")
if not token:
    print("ERROR: HF_TOKEN not set"); sys.exit(1)
snapshot_download(repo_id="Qwen/Qwen3-Coder-Next-FP8", token=token)
print("Download complete.")
EOF

nohup bash -c "HF_TOKEN='$HF_TOKEN' python3 /tmp/hf_download.py" \
  > ~/download.log 2>&1 &
echo "PID: $!"
unset HF_TOKEN

tail -f ~/download.log
```

---

## Start the stack

### Step 1: Start vLLM

```bash
cd ~/code/spark-ai/qwen3-coder-next
docker compose up -d
docker logs -f vllm-qwen3-coder-next
```

Wait for:
```
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

First start takes 3-5 minutes while vLLM compiles Triton kernels. Subsequent starts
are fast once kernels are cached.

### Step 2: Start OpenClaw

```bash
cd ~/code/spark-ai/openclaw
docker compose up -d openclaw-gateway
docker compose logs -f openclaw-gateway
```

### Step 3: Complete OpenClaw onboarding

```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli onboard --no-install-daemon
```

During onboarding:
1. **AI Provider** — select "OpenAI-compatible", base URL `http://nim:8000/v1`, API key `dummy`
2. **Gateway mode** — choose `local`
3. **Messaging channel** — Telegram recommended (see Step 4)
4. **Agent sandboxing** — enable when prompted
5. **Shell tool** — **leave disabled**. This is the most important security setting.
   A compromised agent with shell access could attempt to SSH out of the container.
   Enable only if you have a specific understood need for it.

### Step 4: Connect Telegram

```bash
# Get a bot token from @BotFather on Telegram, then:
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli channels add \
  --channel telegram \
  --token YOUR_TELEGRAM_BOT_TOKEN

docker compose up -d openclaw-gateway

# Approve the pairing code OpenClaw sends to your Telegram
docker compose run --rm openclaw-cli pairing approve telegram YOUR_PAIRING_CODE
```

Verify `gateway.mode` is `local` and the channel is locked to your account only.

---

## Google and Slack credentials

**Google account:**
- Create a dedicated Google account solely for the OpenClaw agent — do not use your
  personal account.
- Grant this account view-only access to the three Google Sheets.
- The account will need Drive write scope to create Google Docs. Ensure it has no access
  to your personal Google Drive.
- OAuth tokens are stored in the `openclaw-config` Docker volume, not on the host
  filesystem.

**Slack:**
- Create a dedicated Slack bot with minimum scopes: `chat:write`, `files:write`, and
  `channels:read` for your target channel only. Do not use a broad user OAuth token.
- Restrict the bot to a single channel.

---

## Block container lateral movement (iptables)

Run on the **Spark host** after both containers are running. Prevents a compromised agent
from reaching other hosts on your LAN, Tailscale network, or SSHing out to any host.

```bash
# Get the Docker network subnet
docker network inspect qwen3-coder-next_nim_net | grep Subnet

DOCKER_SUBNET="172.18.0.0/16"   # adjust to match output above
LAN_SUBNET="YOUR_LAN_SUBNET"    # e.g. 10.0.4.0/22
TAILSCALE_CGNAT="100.64.0.0/10"

# Block container → LAN
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $LAN_SUBNET -j DROP

# Block container → Tailscale peers
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -d $TAILSCALE_CGNAT -j DROP

# Block container outbound SSH to any host
sudo iptables -I DOCKER-USER -s $DOCKER_SUBNET -p tcp --dport 22 -j DROP

# Verify all three rules are present
sudo iptables -L DOCKER-USER -n -v
```

Make persistent across reboots:

```bash
sudo apt install iptables-persistent -y
sudo netfilter-persistent save
```

---

## Harden SSH on your MacBook

Even with iptables blocking the containers, the Spark host itself has a passwordless SSH
key to your MacBook. Add a `from=` restriction on the MacBook side as a backstop.

On your **MacBook**, edit `~/.ssh/authorized_keys` and prefix the Spark's key entry:

```
from="YOUR_TAILSCALE_IP",no-agent-forwarding,no-X11-forwarding,no-port-forwarding ssh-ed25519 AAAA... spark-key
```

---

## Security verification

Run after every fresh deployment.

### A) Host must NOT be listening on port 8000
```bash
ss -ltnp | grep :8000 || echo "No host listener on 8000 (expected)"
curl -s http://localhost:8000/v1/models || echo "Host cannot reach vLLM (expected)"
```

### B) OpenClaw bound to Tailscale IP only
```bash
ss -tlnp | grep 18789
# Must show YOUR_TAILSCALE_IP:18789 — NOT 0.0.0.0:18789
```

### C) Model API reachable only from inside Docker network
```bash
NET="qwen3-coder-next_nim_net"
docker run --rm --network "$NET" curlimages/curl:latest \
  -s http://nim:8000/v1/models | python3 -m json.tool
# Expected: JSON listing Qwen/Qwen3-Coder-Next-FP8
```

### D) Container cannot reach LAN, Tailscale peers, or SSH out
```bash
docker compose exec openclaw-gateway ping -c 2 YOUR_MAC_TAILSCALE_IP
# Expected: 100% packet loss

docker compose exec openclaw-gateway ping -c 2 10.0.4.1
# Expected: 100% packet loss

docker compose exec openclaw-gateway timeout 5 bash -c \
  "echo > /dev/tcp/github.com/22" 2>&1 || echo "Port 22 outbound blocked (expected)"
```

### E) Container CAN reach the internet
```bash
docker compose exec openclaw-gateway curl -s https://api.anthropic.com --max-time 5
# Expected: any response (even 401 — network works)
```

### F) No ~/.ssh mount in container
```bash
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1
# Expected: No such file or directory
```

---

## Performance expectations

| Scenario | Approx tok/s |
|---|---|
| Single request | ~43 |
| OpenClaw parallel tool calls (batch 4–8) | ~120–200 |
| Heavy concurrent agentic load | ~300–400 aggregate |

---

## Stop / restart

```bash
# Stop OpenClaw first, then vLLM
cd ~/code/spark-ai/openclaw && docker compose down
cd ~/code/spark-ai/qwen3-coder-next && docker compose down

# Start vLLM first, then OpenClaw
cd ~/code/spark-ai/qwen3-coder-next && docker compose up -d
cd ~/code/spark-ai/openclaw && docker compose up -d
```

---

## Updating

```bash
# Update vLLM image
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh

# Restart stack (vLLM first, then OpenClaw)
cd ~/code/spark-ai/openclaw && docker compose down
cd ~/code/spark-ai/qwen3-coder-next && docker compose down && docker compose up -d
cd ~/code/spark-ai/openclaw && docker compose up -d
```

Model weights in `~/.cache/huggingface/` are unaffected by image updates.

---

## Troubleshooting

```bash
# Container status
docker compose ps && docker ps -a

# vLLM logs
docker logs vllm-qwen3-coder-next --tail 200

# OpenClaw logs
docker logs openclaw-gateway --tail 200

# GPU access check
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi

# Confirm model fully downloaded (~46GB)
du -sh ~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/
```

**`CUDA error` or `SM version not supported`:**
```bash
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
```

**OOM during model load:**
Reduce `--gpu-memory-utilization` to `0.7` in `qwen3-coder-next/docker-compose.yml`.

**Slow first start:**
Normal — vLLM compiles Triton kernels on first run. Subsequent starts are fast.

**OpenClaw cannot reach vLLM:**
vLLM must be started first. Check the network exists:
```bash
docker network ls | grep nim_net
```

**Model redownloads on every start:**
Check `~/.cache/huggingface` is correctly mounted in `qwen3-coder-next/docker-compose.yml`.
