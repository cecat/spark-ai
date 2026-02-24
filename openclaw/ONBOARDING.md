# OpenClaw Onboarding Log

**Date:** 2026-02-24  
**Version:** OpenClaw 2026.2.17  
**Platform:** DGX Spark (spark-960b), Ubuntu  
**Goal:** Minimal, security-first configuration for TPC survey reporting use case

This file records every onboarding question, the answer chosen, and the rationale.
It reflects the actual onboarding wizard as experienced — questions are in the order
they appear.

---

## Pre-onboarding: fix volume permissions

Before running the wizard, fix permissions on the `openclaw-config` Docker volume.
Docker creates it as root; OpenClaw runs as `node` (uid 1000) and will crash
mid-wizard with `EACCES: permission denied` without this step:

```bash
sudo chown -R 1000:1000 /var/lib/docker/volumes/openclaw_openclaw-config/_data
```

Run this once. It persists as long as the volume exists.

---

## Run onboarding

```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli onboard --no-install-daemon
```

---

## Onboarding Questions

### Q1 — Security warning
**Prompt:** I understand this is powerful and inherently risky. Continue?  
**Answer:** Yes  
**Notes:** Read and understood. Our security model (iptables, scoped workspace,
shell disabled, dedicated Google/Slack accounts) directly addresses the risks listed.

---

### Q2 — Onboarding mode
**Prompt:** Onboarding mode  
**Options:** Quickstart / Manual  
**Answer:** Manual  
**Rationale:** Quickstart makes assumptions we want to control explicitly — particularly
the AI provider (local vLLM, not a cloud API), workspace path, and shell tool setting.

---

### Q3 — What to set up
**Prompt:** What do you want to set up?  
**Options:** Local gateway (this machine) / Remote GW (info only)  
**Answer:** Local gateway (this machine)  
**Rationale:** The gateway runs on the Spark itself, accessible only via Tailscale.

---

### Q4 — Workspace directory
**Prompt:** Workspace directory  
**Pre-filled default:** `/home/node/.openclaw/workspace`  
**Answer:** `/home/node/workspace`  
**⚠️ Important:** Clear the pre-filled value and enter `/home/node/workspace`.
The default puts the workspace inside the config volume, which is wrong for our setup.
`/home/node/workspace` is where Docker mounts `~/openclaw-workspace` from the Spark
host (as defined in `openclaw/docker-compose.yml`). The wizard does not read the
compose file — you must enter this manually.

---

### Q5 — Model/auth provider
**Prompt:** Model/auth provider  
**Options:** Long list including OpenAI, Anthropic, vLLM, Qwen, Custom Provider, etc.  
**Answer:** vLLM  
**Rationale:** vLLM is a first-class option that knows the right settings for a local
vLLM endpoint. Do not select "Qwen" — that points to Qwen's cloud API, not our local
instance. Do not select "Custom Provider" — vLLM is cleaner.

---

### Q6 — vLLM base URL
**Prompt:** vLLM base URL  
**Pre-filled default:** `http://127.0.0.1:8000/v1`  
**Answer:** `http://nim:8000/v1`  
**⚠️ Important:** Clear the pre-filled value. `127.0.0.1` refers to localhost inside
the OpenClaw container, which cannot reach vLLM. `nim` is the vLLM service name on
the shared Docker network `qwen3-coder-next_nim_net` — that is how the two containers
communicate. (`nim` is a legacy name from early planning; the service works correctly
despite the name.)

---

### Q7 — vLLM API key
**Prompt:** vLLM API key  
**Pre-filled default:** `sk-...`  
**Answer:** `sk-dummy` (or any non-empty string)  
**Rationale:** vLLM does not validate API keys. The field must be non-empty to satisfy
the OpenAI-compatible API format. The value does not matter.

---

### Q8 — vLLM model
**Prompt:** vLLM model  
**Pre-filled default:** `meta-llama/Meta-Llama-3-8B-Instruct`  
**Answer:** `Qwen/Qwen3-Coder-Next-FP8`  
**⚠️ Important:** Replace the pre-filled value. This must exactly match the model
string vLLM is serving.

---

### Q9 — Default model
**Prompt:** Default model  
**Options:** Keep current (vllm/Qwen/Qwen3-Coder-Next-FP8) / Enter model manually  
**Answer:** Keep current  
**Notes:** Confirms the model from Q8 was accepted correctly.

---

### Q10 — Gateway port
**Prompt:** Gateway port  
**Pre-filled default:** `18789`  
**Answer:** Keep `18789`  
**Rationale:** Matches the port in `openclaw/docker-compose.yml` and all security tests.

---

### Q11 — Gateway bind
**Prompt:** Gateway bind  
**Options:** Loopback (127.0.0.1) / LAN (0.0.0.0) / Tailnet (Tailscale IP) / Auto / Custom IP  
**Answer:** LAN (0.0.0.0)  
**Rationale:** The gateway must listen on `0.0.0.0` inside the container so Docker
can route traffic to it. The real security boundary is the `ports:` line in
`docker-compose.yml`, which binds port 18789 to the Spark's Tailscale IP on the host
side — that prevents LAN/internet exposure. Do not select Loopback; Docker cannot
route to it.

---

### Q12 — Gateway auth
**Prompt:** Gateway auth  
**Options:** Token / Password  
**Answer:** Token  
**Rationale:** Token is a long random string, harder to guess than a password. Used
as a URL parameter (`#token=...`) to access the dashboard.

---

### Q13 — Tailscale exposure
**Prompt:** Tailscale exposure  
**Options:** Off / Serve / Funnel  
**Answer:** Off  
**Rationale:** We handle Tailscale exposure via `docker-compose.yml` port binding.
OpenClaw does not need to manage Tailscale separately.

---

### Q14 — Gateway token
**Prompt:** Gateway token (blank to generate)  
**Answer:** Leave blank  
**Rationale:** Let OpenClaw generate a strong random token. The token is displayed
near the end of onboarding in the dashboard URL:
```
http://172.18.0.3:18789/#token=<YOUR_TOKEN>
```
**Save this token to 1Password immediately** as "OpenClaw Gateway Token".
If you miss it, retrieve it later:
```bash
cd ~/code/spark-ai/openclaw
docker compose run --rm openclaw-cli dashboard --no-open
```

---

### Q15 — Configure chat channels
**Prompt:** Configure chat channels now?  
**Answer:** No (select Finished if you accidentally enter the channel list)  
**Rationale:** Slack is the production channel for TPC reporting. Connect it after
onboarding via:
```bash
docker compose run --rm openclaw-cli channels add --channel slack --token YOUR_SLACK_BOT_TOKEN
```

---

### Q16 — Configure skills
**Prompt:** Configure skills now? (recommended)  
**Answer:** No  
**Rationale:** Skills are plugins that run with agent permissions. Only install skills
whose source you have reviewed. Start with zero; add only what is needed for TPC
reporting (Google Sheets, Slack) once the base config is stable.

---

### Q17 — Enable hooks
**Prompt:** Enable hooks?  
**Answer:** Skip for now  
**Rationale:** Hooks automate actions on agent commands. Not needed for our use case
and add attack surface. Add later only if a specific need arises.

---

### Q18 — Shell completion
**Prompt:** Enable zsh shell completion for openclaw?  
**Answer:** No  
**Rationale:** Not needed; we run OpenClaw via Docker, not a local CLI install.

---

## Expected output at end of onboarding

The wizard will display a health check failure — **this is normal and expected:**
```
Health check failed: gateway closed (1006 abnormal closure): no close reason
Gateway target: ws://172.18.0.3:18789
```
The health check fails because the gateway container is not running yet. Onboarding
only writes config. Start the gateway after onboarding completes.

The wizard will also display the dashboard URL with your token:
```
http://172.18.0.3:18789/#token=YOUR_TOKEN
```
Note: `172.18.0.3` is the container's internal IP — this URL only works from inside
the Docker network. From your Mac, use the Spark's Tailscale IP instead:
```
http://100.120.99.52:18789/#token=YOUR_TOKEN
```

---

## After onboarding: start the gateway

```bash
cd ~/code/spark-ai/openclaw
docker compose up -d openclaw-gateway
docker compose logs -f openclaw-gateway
```

Then verify from your Mac browser:
```
http://100.120.99.52:18789/#token=YOUR_TOKEN
```

---

## Post-onboarding checklist

- [ ] Token saved to 1Password as "OpenClaw Gateway Token"
- [ ] Gateway started (`docker compose up -d openclaw-gateway`)
- [ ] Dashboard accessible from Mac at Tailscale IP
- [ ] Port binding verified: `ss -tlnp | grep 18789` shows Tailscale IP, not `0.0.0.0`
- [ ] Apply iptables rules (see README.md)
- [ ] Run security audit: `docker compose exec openclaw-gateway node dist/index.js security audit --deep`
- [ ] Connect Slack channel
- [ ] Connect Google account for Sheets/Docs access
- [ ] Test: send a message to the agent via Slack
- [ ] Update PLAN.md Phase 3 checklist

---

## Decisions summary

| Question | Answer | Key reason |
|---|---|---|
| Security warning | Yes | Mitigations in place |
| Mode | Manual | Control all settings explicitly |
| Gateway type | Local | Runs on Spark |
| Workspace | `/home/node/workspace` | Must match Docker volume mount path |
| Provider | vLLM | First-class option for local vLLM |
| Base URL | `http://nim:8000/v1` | Docker service name, not localhost |
| API key | `sk-dummy` | vLLM doesn't validate; field must be non-empty |
| Model | `Qwen/Qwen3-Coder-Next-FP8` | Must match what vLLM is serving |
| Port | `18789` | Matches compose file |
| Bind | LAN (0.0.0.0) | Docker needs 0.0.0.0; host ports: line enforces Tailscale-only |
| Auth | Token | Stronger than password |
| Tailscale | Off | Handled by compose file already |
| Token | Auto-generated | Strong random; save to 1Password |
| Channels | Skip | Connect Slack separately after |
| Skills | No | Review source before installing any |
| Hooks | Skip | Not needed; adds attack surface |
| Shell completion | No | Using Docker, not local CLI |
