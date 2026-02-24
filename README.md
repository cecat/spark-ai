# OpenClaw on a NVIDIA DGX Spark

This config runs **Qwen3-Coder-Next-FP8** via community vLLM on a DGX Spark, secured so
the model API is reachable only from other containers on the same Docker network. OpenClaw
is reachable only from hosts on the same Tailscale network as the Spark.

Use any of this at your own risk.

---

## Directory layout

```
~/code/
├── spark-vllm-docker/     # eugr community vLLM build repo
├── qwen3-coder-next/      # vLLM docker-compose.yml lives here
└── openclaw/              # OpenClaw docker-compose.yml lives here

~/.cache/huggingface/      # model weights (~46GB) — not in ~/code
```

`spark-vllm-docker`, `qwen3-coder-next`, and `openclaw` are independent directories
connected only at runtime through a shared Docker network. The model cache lives in
`~/.cache/huggingface` by convention — it is large binary data, not code, and should
not be inside `~/code`.

---

## Architecture

```
[Tailscale]
    |
    v  (port 18789, Tailscale IP only)
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
- The HuggingFace token is a pass-through only. It must never be hardcoded into
  `docker-compose.yml` or committed to version control.
- The `~/.cache/huggingface` volume mount persists model weights. Do not replace it with
  a broader mount such as `~/` or `/home`.
- Do not mount `~/.ssh`, `/etc`, or any path containing credentials into any container.
- Your home directory and `~/.docker` should not be world-readable. Tighten permissions
  if unsure:
  ```bash
  chmod 700 ~ ~/.docker
  ```
- After the model is downloaded, set `HF_HUB_OFFLINE=1` in `docker-compose.yml` to
  block unnecessary outbound connections from the model container.

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
- Generate a read-only access token at https://huggingface.co/settings/tokens
- The token is passed at runtime only, never stored in this repo

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

## docker-compose.yml

```yaml
services:
  nim:
    image: vllm-node
    container_name: vllm-qwen3-coder-next
    restart: unless-stopped
    runtime: nvidia
    deploy:
      resources:
        reservations:
          devices:
            - capabilities: [gpu]
    shm_size: "32g"
    ipc: host
    environment:
      - HF_TOKEN           # pass-through only; set in shell before compose up
      - HF_HUB_OFFLINE=0   # change to 1 after first successful model download
    volumes:
      - ~/.cache/huggingface:/root/.cache/huggingface
    # NO ports: section — model API must not be published to the host
    networks:
      - nim_net
    command: >
      bash -c "vllm serve Qwen/Qwen3-Coder-Next-FP8
        --host 0.0.0.0
        --port 8000
        --gpu-memory-utilization 0.8
        --max-model-len 131072
        --load-format fastsafetensors
        --attention-backend flashinfer
        --enable-prefix-caching
        --enable-auto-tool-choice
        --tool-call-parser qwen3_coder
        --kv-cache-dtype fp8"

  # OpenClaw — add later; placeholder shown
  # openclaw:
  #   ...
  #   environment:
  #     - OPENAI_API_BASE=http://nim:8000/v1
  #     - OPENAI_API_KEY=dummy
  #   networks:
  #     - nim_net

networks:
  nim_net:
    driver: bridge
```

> **Context length note:** `--max-model-len 131072` (128K) is the proven-stable value for
> a single Spark. The model supports 256K but the larger KV cache may cause OOM. Increase
> to 262144 only after confirming stability at 131072.

---

## First run: download the model

The model is ~46GB. Pre-download before starting the stack so you can monitor progress:

```bash
# Install huggingface_hub if needed
pip install huggingface_hub --break-system-packages

read -s -p "HuggingFace token: " HF_TOKEN; echo
python3 -c "
from huggingface_hub import snapshot_download
snapshot_download(
    repo_id='Qwen/Qwen3-Coder-Next-FP8',
    token='$HF_TOKEN'
)
"
unset HF_TOKEN
```

The download goes to `~/.cache/huggingface/\` automatically. Progress is shown per file.
Expect 20-60 minutes depending on your connection speed.

---

## Start the stack

```bash
cd ~/code/qwen3-coder-next

# Model is cached — no token needed at runtime
# WARNING: Never pass HF_TOKEN on the command line or hardcode it anywhere.
# It will appear in `ps aux` output and shell history. If you accidentally
# exposed your token, rotate it immediately:
# https://huggingface.co/settings/tokens
docker compose up -d

docker compose ps
```

### Watch logs until ready
```bash
docker logs -f vllm-qwen3-coder-next
```

Wait for:
```
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8000
```

First start takes 3-5 minutes while vLLM compiles Triton kernels. Subsequent starts
are fast once kernels are cached.

---

## Security verification

Run these checks after every fresh deployment.

### A) Host must NOT be listening on port 8000
```bash
ss -ltnp | grep :8000 || echo "No host listener on 8000 (expected)"
```

Direct access from the host must fail:
```bash
curl -s http://localhost:8000/v1/models || echo "Host cannot reach vLLM (expected)"
```

### B) Model API reachable only from inside the Docker network
```bash
docker network ls | grep nim_net
# Note the full network name, e.g. qwen3-coder-next_nim_net

NET="<PASTE_NETWORK_NAME_HERE>"
docker run --rm --network "$NET" curlimages/curl:latest \
  -s http://nim:8000/v1/models | python3 -m json.tool
```

Expected: JSON response listing `Qwen/Qwen3-Coder-Next-FP8`.

### C) Quick generation test
```bash
NET="<PASTE_NETWORK_NAME_HERE>"
docker run --rm --network "$NET" curlimages/curl:latest \
  -s -X POST http://nim:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "Qwen/Qwen3-Coder-Next-FP8",
    "messages": [{"role": "user", "content": "Say hello in one sentence."}],
    "max_tokens": 32
  }' | python3 -m json.tool
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
cd ~/code/qwen3-coder-next
docker compose down
docker compose up -d   # no token needed once model is cached
```

---

## Updating

```bash
cd ~/code/spark-vllm-docker
git pull
./build-and-copy.sh

cd ~/code/qwen3-coder-next
docker compose down
docker compose up -d
```

Model weights in `~/.cache/huggingface/` are unaffected by image updates.

---

## Troubleshooting

```bash
# Compose config check
docker compose config

# Container status
docker compose ps && docker ps -a

# Recent logs
docker logs vllm-qwen3-coder-next --tail 200

# GPU access check
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi

# Auth/download errors
docker logs vllm-qwen3-coder-next 2>&1 | grep -i "error\|auth\|token"

# Confirm model is fully downloaded (~46GB)
du -sh ~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/
```

**`CUDA error` or `SM version not supported`:**
The `vllm-node` image must be built from `eugr/spark-vllm-docker`, not pulled from
NVIDIA NGC. Rebuild:
```bash
cd ~/code/spark-vllm-docker && git pull && ./build-and-copy.sh
```

**OOM during model load:**
Reduce `--gpu-memory-utilization` to `0.7` and restart.

**Slow first start:**
Normal — vLLM compiles Triton kernels on first run. Subsequent starts are fast.

**Model redownloads on every start:**
Check that `~/.cache/huggingface` is correctly mounted as a volume in `docker-compose.yml`.

---

## Adding OpenClaw

When adding OpenClaw as a second service, point it at the model server via the
Docker-internal hostname:

```yaml
environment:
  - OPENAI_API_BASE=http://nim:8000/v1
  - OPENAI_API_KEY=dummy
```

Keep `HF_TOKEN` out of the OpenClaw container entirely.
