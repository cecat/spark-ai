# Troubleshooting

## Quick log commands
```bash
docker compose ps
docker logs vllm-qwen3-coder-next --tail 50
docker logs openclaw-gateway --tail 50
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

**Model redownloads on every start**
Confirm `~/.cache/huggingface` is mounted correctly in `qwen3-coder-next/docker-compose.yml`.

**Confirm model fully downloaded**
```bash
du -sh ~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/
# Expected: ~46GB
```

---

## OpenClaw onboarding

**`EACCES: permission denied, mkdir '/home/node/.openclaw/agents'`**
Docker created the volume as root. Fix before re-running onboarding:
```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw_openclaw-config/_data
```

**Onboarding pre-fills wrong workspace path**
Clear `/home/node/.openclaw/workspace` and enter `/home/node/workspace` — that is where Docker mounts `~/openclaw-workspace`.

**Onboarding pre-fills wrong vLLM base URL**
Clear `http://127.0.0.1:8000/v1` and enter `http://nim:8000/v1` — `nim` is the vLLM service name on the shared Docker network.

**Health check failure at end of onboarding**
Expected — the gateway isn't running yet. Start it after onboarding completes.

---

## OpenClaw dashboard

**"control ui requires HTTPS or localhost"**
Plain HTTP over Tailscale IP is rejected. Set up Tailscale Serve (README Step 6).

**"pairing required" after Tailscale Serve is set up**
The gateway doesn't trust the proxy yet. Run the config patch in README Step 6 and restart.

**Token lost**
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli dashboard --no-open
```

**Dashboard URL**
Use `https://spark-ts.YOUR-TAILNET.ts.net/#token=YOUR_TOKEN`, not the `172.18.x.x` URL shown during onboarding (that is a Docker-internal IP).

---

## Networking

**OpenClaw cannot reach vLLM**
vLLM must start before OpenClaw so the shared network exists. Check:
```bash
docker network ls | grep nim_net
```

**Verify vLLM reachable from inside Docker network**
```bash
docker run --rm --network qwen3-coder-next_nim_net curlimages/curl:latest \
  http://nim:8000/v1/models
```

**Verify OpenClaw port binding**
```bash
ss -tlnp | grep 18789
# Must show 100.120.99.52:18789 — NOT 0.0.0.0:18789
```

**Verify iptables DROP rules are in place**
```bash
sudo iptables -L DOCKER-USER -n -v | grep DROP
# Must show 3 rules: LAN, Tailscale CGNAT, port 22
```

**iptables rules lost after reboot**
```bash
sudo apt install iptables-persistent -y && sudo netfilter-persistent save
```

---

## Security verification (run after fresh deployment)

```bash
# vLLM not exposed to host
ss -ltnp | grep :8000 || echo "OK"

# OpenClaw Tailscale-only
ss -tlnp | grep 18789   # must show 100.120.99.52, not 0.0.0.0

# No SSH keys in container
docker compose exec openclaw-gateway ls /home/node/.ssh 2>&1   # must say no such file

# Container cannot reach LAN
docker compose exec openclaw-gateway ping -c 2 10.0.4.1   # must show 100% loss

# Container cannot SSH out
docker compose exec openclaw-gateway timeout 5 bash -c \
  "echo > /dev/tcp/github.com/22" 2>&1 || echo "Port 22 blocked OK"
```
