# spark-ai Project Plan

**Owner:** Charlie Catlett  
**Platform:** NVIDIA DGX Spark (GB10, 128GB unified memory, Ubuntu)  
**Repo:** `~/code/spark-ai` → `github.com/cecat/spark-ai`  
**Status:** vLLM running and verified; tests and CI in place; OpenClaw not yet started

---

## Overview

This project runs a self-hosted AI agent (OpenClaw) on a DGX Spark, backed by a local
large language model (Qwen3-Coder-Next-FP8, 80B MoE) served via community vLLM. The
agent is accessible only from devices on the same Tailscale network as the Spark.

The initial use case is automating periodic monitoring and reporting from Google Forms /
Sheets data, with output delivered via Slack and optionally Google Docs.

---

## Repository Structure

```
spark-ai/
├── README.md                        # Deployment and operations guide
├── PLAN.md                          # This file — project context and roadmap
├── .gitignore
├── tests/
│   ├── test_vllm.py                 # Smoke test: vLLM endpoint reachable from Docker network
│   ├── test_openclaw.py             # Smoke test: OpenClaw gateway responding on Tailscale IP
│   └── test_security.py            # Security checks: port bindings, iptables, container isolation
├── .github/
│   └── workflows/
│       └── ci.yml                   # Structural checks + live tests on self-hosted runner
├── qwen3-coder-next/
│   ├── docker-compose.yml           # vLLM inference service
│   ├── .env.example                 # committed — shows required variables
│   └── .env                         # NOT committed — your actual values
└── openclaw/
    ├── docker-compose.yml           # OpenClaw gateway service
    ├── .env.example                 # committed — shows required variables
    └── .env                         # NOT committed — your actual values
```

**External repos on the Spark (not in this repo):**
- `~/code/spark-vllm-docker/` — eugr community vLLM build for GB10 (cloned from
  `github.com/eugr/spark-vllm-docker`); build once with `./build-and-copy.sh`
- `~/.cache/huggingface/` — model weights (~46GB), downloaded separately

---

## Infrastructure Status

| Component | Status | Notes |
|---|---|---|
| vLLM community image | ✅ Built | `vllm-node` image via `eugr/spark-vllm-docker` |
| Qwen3-Coder-Next-FP8 | ✅ Downloaded | ~46GB in `~/.cache/huggingface/` |
| NVIDIA Container Runtime | ✅ Configured | `nvidia-ctk runtime configure --runtime=docker` done |
| qwen3-coder-next compose | ✅ Running | Verified startup; API serving on Docker-internal port 8000 |
| qwen3-coder-next .env | ✅ Created | `HF_HUB_OFFLINE=0` — flip to `1` after confirming model is cached |
| vLLM smoke test | ✅ Verified | Prompt/response confirmed via Docker network test container |
| openclaw compose | ✅ Running | Gateway up; Tailscale-only; connected to vLLM |
| openclaw-workspace | ✅ Created | `~/code/spark-ai-agents/` — multi-agent private repo |
| Tests directory | ✅ Created | `tests/` with vLLM, OpenClaw, and security tests; CI workflow in `.github/` |
| OpenClaw onboarding | ✅ Done | main + chattpc26 agents configured |
| Slack bot | ✅ Done | ChatCeC app; main agent handles DMs; chattpc26 handles TPC channels |
| iptables rules | ✅ Done | 3 DROP rules in place; saved via iptables-persistent |
| Security hardening | ✅ Done | tools.deny, sandbox, configWrites all configured |
| Google/gog integration | ✅ Done | chattpc26@gmail.com; sandbox exec; gog auth list verified |
| Telegram channel | ⬜ Not started | Need @BotFather token |
| MacBook SSH hardening | ✅ Done | Removed authorized_keys (no passwordless SSH into Mac needed) |

**Next action:** Phase 5 — share Google Sheets with chattpc26@gmail.com and test report generation.

---

## Use Case: TPC Survey Monitoring and Reporting

### Background

Charlie runs the Trillion Parameter Consortium (TPC), a virtual organization of 1,500+
scientists across 100+ organizations. TPC uses Google Forms to collect data from members
— currently three active forms. The responses accumulate in corresponding Google Sheets.
Manually monitoring these sheets and producing summary reports is time-consuming.

### What the Agent Will Do

The agent runs on a schedule (or on demand via Slack) and performs the following:

1. **Read the three Google Sheets** — access is via a dedicated Google account granted
   view-only permission on each sheet. The agent does not need write access to any sheet.

2. **Analyze the responses** — for each sheet, produce a summary report covering:
   - Response counts and trends over time
   - Key categorical breakdowns (organization type, country, topic area — exact fields
     TBD based on actual form structure)
   - Notable new entries since the last report
   - Any anomalies or data quality issues worth flagging

3. **Produce a report as a Markdown file** — written to `~/openclaw-workspace/reports/`
   on the Spark host. Report filenames should be datestamped, e.g.
   `tpc-survey-report-2026-02-24.md`.

4. **Deliver the report via Slack** — post a summary message plus attach or link the
   full report to a designated TPC Slack channel (e.g. `#agent-reports`).

5. **Optionally create a Google Doc** — if a shareable formatted version is needed,
   the agent can create a Google Doc in a shared TPC Drive folder using the dedicated
   agent Google account. This requires Drive write scope on that account.

### Trigger Mechanism

Initially: on-demand via a Slack message to the agent (e.g. "run the survey report").
Later: scheduled via OpenClaw's scheduling capability (e.g. weekly on Monday morning).

### Agent Identity and Persona

The agent should be configured with a clear persona and scope description so it stays
on task. Suggested `agent.json` settings:

```json
{
  "name": "tpc-reports",
  "description": "TPC survey monitoring agent. Reads three Google Sheets (TPC member surveys), produces summary reports, and posts them to Slack. Does not send email, modify any sheets, or access any files outside its workspace.",
  "sandbox": {
    "enabled": true,
    "network": "none"
  },
  "tools": {
    "filesystem": {
      "enabled": true,
      "allowedPaths": ["/home/node/workspace"]
    },
    "shell": {
      "enabled": false
    },
    "browser": {
      "enabled": true
    }
  }
}
```

### Google Sheets — Setup Steps

1. Create a dedicated Google account (e.g. `tpc-agent@gmail.com` or a Google Workspace
   account under a TPC domain).
2. Share each of the three Google Sheets with this account as **Viewer** (view-only).
3. Note the Sheet IDs from each URL:
   `https://docs.google.com/spreadsheets/d/SHEET_ID/edit`
4. During OpenClaw onboarding, connect the Google integration using this dedicated
   account. OAuth tokens will be stored in the `openclaw-config` Docker volume.
5. If Google Docs output is desired, also grant the dedicated account **Editor** access
   to a specific TPC shared Drive folder — not the entire Drive.

### Slack — Setup Steps

1. Go to https://api.slack.com/apps → **Create New App** → **From scratch**
2. Name: `tpc-reports-bot`; select the TPC Slack workspace
3. Under **OAuth & Permissions**, add these minimum required scopes:
   `chat:write`, `im:history`, `im:read`, `im:write`, `app_mentions:read`

   Optional scopes (add if you want the agent to read channel history, react to messages, or handle files):
   `channels:history`, `channels:read`, `files:read`, `files:write`,
   `groups:history`, `mpim:history`, `reactions:read`, `reactions:write`, `users:read`

   **Do NOT add `assistant:write`** — it enables Slack's native AI streaming API which causes silent message delivery failures in this setup.
4. Install the app to the workspace; copy the **Bot User OAuth Token** (`xoxb-...`)
5. Invite the bot to the target channel: `/invite @tpc-reports-bot`
6. During OpenClaw Slack channel setup, provide this token

---

## Security Model

### Threat Model Summary

OpenClaw is a capable agent with real access to files, APIs, and (optionally) a browser
and shell. The primary risks are:

| Threat | Likelihood | Impact | Mitigation |
|---|---|---|---|
| Prompt injection via sheet data | Medium | Agent executes unintended actions | Exec runs in ephemeral sandbox containers for both agents; workspace scoped; no host access |
| Agent credential exfiltration | Low | Google/Slack tokens stolen | Dedicated accounts; tokens in Docker volume only |
| Lateral movement to LAN hosts | Low | Access to MacBook or other devices | iptables DOCKER-USER rules |
| Lateral movement via Tailscale | Low | Access to other Tailscale nodes | iptables blocks 100.64.0.0/10 |
| Agent SSHing out to internet | Low | Exfiltration or C2 | iptables blocks outbound TCP/22 |
| Unauthorized agent access | Low | Agent commanded by third party | Tailscale-only port binding; DM-only pairing |
| Token/credential in repo | Medium | Credential exposure | `.gitignore`; `read -s` pattern; no `-c` args |

### Security Layers in Place

| Layer | Implementation | Status | File |
|---|---|---|---|
| Network ingress | Port 18789 bound to Tailscale IP only | ✅ Done | `openclaw/docker-compose.yml` |
| Model API isolation | Port 8000 not published to host | ✅ Done | `qwen3-coder-next/docker-compose.yml` |
| Filesystem isolation | Only `~/code/spark-ai-agents` mounted at `/home/node/agents` | ✅ Done | `openclaw/docker-compose.yml` |
| Container user | Runs as `node` uid 1000, non-root | ✅ Done | OpenClaw default; do not override |
| LAN lateral movement | iptables DOCKER-USER drop rule | ✅ Done | Manual step; see README |
| Tailscale lateral movement | iptables DOCKER-USER drop rule | ✅ Done | Manual step; see README |
| Outbound SSH | iptables TCP/22 drop rule | ✅ Done | Manual step; see README |
| Shell/exec tool (all agents) | Exec runs in ephemeral sandbox containers only; host untouched | ✅ Done | openclaw.json / `GOG.md` |
| Agent sandboxing | `sandbox.mode: "all"` globally in openclaw.json | ✅ Done | openclaw.json |
| Config writes | `configWrites: false` per channel; `commands.config: false` | ✅ Done | openclaw.json |
| Slack access | DM-only pairing; Tailscale-only port | ✅ Done | openclaw.json |
| SSH backstop | Removed MacBook authorized_keys | ✅ Done | — |
| Credential hygiene | `read -s` for tokens; temp script for HF download | ✅ Done | README pattern |

### Dedicated Account Strategy

Two dedicated accounts are used to contain the blast radius of any credential compromise:

**Google (`chattpc26@gmail.com`):**
- View-only on three specific Sheets
- Editor on one specific Drive folder (for Doc output only)
- No access to personal Google accounts or Drive
- OAuth tokens stored in `~/.config/gogcli/keyring/` on host; bind-mounted read-write
  into sandbox containers only (not the gateway container)
- Google Cloud project: TPC26-Forms-Triage
- Keyring backend: file-based encryption (`GOG_KEYRING_BACKEND=file`)

**Slack (`tpc-reports-bot` / ChatCeC app):**
- Scopes: `chat:write`, `files:write`, `channels:read`, `channels:join`
- Restricted to specified channels
- Bot token stored only in `openclaw-config` Docker volume

### What the Agent Cannot Do

By design and enforcement:
- Cannot read or write any file outside `~/code/spark-ai-agents` (main agent) or its
  workspace + explicit sandbox binds (chattpc26)
- Cannot SSH to the MacBook or any other host (iptables + no SSH keys in container)
- Cannot reach other LAN hosts (iptables)
- Cannot reach other Tailscale nodes (iptables)
- Cannot run shell commands on the host (exec runs only inside ephemeral sandbox containers for both agents)
- Cannot be commanded by anyone other than Charlie's Slack account
- Cannot access Charlie's personal Google account or Drive

### Residual Risks

- **Prompt injection via sheet content** remains the most realistic attack vector. If a
  survey respondent puts instructions in a free-text field, the agent could act on them.
  For both agents, injected commands would run inside an ephemeral sandbox container with
  no host access, no docker.sock, and no lateral movement — but the container does have
  outbound network, so data exfiltration via HTTP to an external server is theoretically
  possible. Monitor agent logs periodically.
- **OpenClaw is young software** (formerly Moltbot/Clawdbot). Security architecture
  may change with updates. Review release notes before updating.
- **Google OAuth tokens** in `~/.config/gogcli/keyring/` are as secure as host filesystem
  permissions — not encrypted at rest beyond the file-based keyring password. Acceptable
  for a dedicated minimal-scope account; do not use personal account tokens.

---

## Development Roadmap

### Phase 1 — Infrastructure ✅ Complete
- [x] Build vLLM community image (`eugr/spark-vllm-docker`)
- [x] Download Qwen3-Coder-Next-FP8 model weights (~46GB)
- [x] Configure NVIDIA Container Runtime for Docker
- [x] Create and validate `qwen3-coder-next/docker-compose.yml`
- [x] Create and validate `openclaw/docker-compose.yml`
- [x] Set up `.env` files for both services
- [x] Create `~/openclaw-workspace/` on host
- [x] Start vLLM and verify prompt/response via Docker network test
- [x] Create GitHub repo (`cecat/spark-ai`) and push all committed files

### Phase 2 — Tests and CI ✅ Complete
- [x] Create `tests/test_vllm.py` — smoke test vLLM endpoint from inside Docker network
- [x] Create `tests/test_openclaw.py` — smoke test OpenClaw gateway on Tailscale IP
- [x] Create `tests/test_security.py` — port bindings, container isolation, iptables rules,
  agent config, HF_HUB_OFFLINE, MacBook SSH backstop (`--macbook` flag)
- [x] Create `.github/workflows/ci.yml` — structural checks + live tests on self-hosted runner
- [x] MacBook SSH hardening — removed authorized_keys (no passwordless SSH into Mac)

### Phase 3 — OpenClaw Onboarding ✅ Complete
- [x] Start OpenClaw container (`docker compose up -d` in `openclaw/`)
- [x] Run onboarding wizard (local LLM)
- [x] Connect Slack — main agent (DMs) and chattpc26 agent (channels C09KGGMS116, C0AJ1EL2KJ5)
- [x] Apply iptables rules; verify in place
- [x] Enable agent sandboxing globally in openclaw.json (`sandbox.mode: "all"`) for all agents
- [x] Set `configWrites: false` and `commands.config: false` to prevent agents editing gateway config
- [x] Verify all security checks pass

### Phase 4 — Connect Data Sources ✅ Complete
- [x] Create dedicated Google account (`chattpc26@gmail.com`)
- [x] Create Google Cloud project (TPC26-Forms-Triage, replacing disabled tpc26-488714)
- [x] Authorize drive, sheets, docs via gog CLI; file-based keyring
- [x] Install gog skill at `~/.agents/skills/gog`; mount into gateway container
- [x] Configure sandbox exec for chattpc26 with gog binary + credentials bind-mounts
- [x] Verified: `gog auth list` succeeds from agent in Slack
- [ ] Share three Google Sheets with chattpc26@gmail.com (view-only)
- [ ] Test: ask agent to summarize one sheet via Slack

### Phase 5 — Report Generation
- [ ] Identify exact field names and structure of each Google Form / Sheet
- [ ] Develop and test prompt/skill for per-sheet summary report
- [ ] Test Markdown report output to `~/openclaw-workspace/reports/`
- [ ] Test Slack delivery of report file
- [ ] Optionally: test Google Doc creation and sharing

### Phase 6 — Scheduling and Hardening
- [ ] Configure scheduled runs (weekly or as appropriate for TPC cadence)
- [ ] Add report archiving / deduplication in workspace
- [ ] Review OpenClaw logs for any unexpected behavior
- [ ] Assess whether additional Google Forms should be added

---

## Testing Strategy

Tests live in `tests/` and are designed to run both locally on the Spark and in GitHub
Actions CI. Because vLLM and OpenClaw run in Docker and the model API is intentionally
not exposed to the host, tests that exercise the actual inference endpoint must run
inside the Docker network.

### Test categories

**`tests/test_vllm.py` — vLLM smoke test**
Runs inside the `qwen3-coder-next_nim_net` Docker network via a temporary container.
Sends a minimal prompt to `http://nim:8000/v1/chat/completions` and asserts:
- HTTP 200 response
- Response contains `choices[0].message.content` (non-empty string)
- Model name in response matches `Qwen/Qwen3-Coder-Next-FP8`
- Response time under a reasonable threshold

**`tests/test_openclaw.py` — OpenClaw gateway smoke test**
Connects to `http://${TAILSCALE_IP}:18789` and asserts:
- Gateway is reachable (HTTP response, not connection refused)
- Health endpoint returns expected status
Requires OpenClaw to be running and `TAILSCALE_IP` set in environment.

**`tests/test_security.py` — Security verification**
Runs on the Spark host (not inside a container) with additional `--macbook` mode. Asserts:
- Port 8000 is NOT bound on the host (`ss -ltnp`)
- Port 18789 is bound to Tailscale IP only
- Only `~/openclaw-workspace` bind-mounted; no sensitive paths (`/etc`, `~/.ssh`, `/root`)
- OpenClaw not running as root
- Container cannot reach LAN gateway, Tailscale CGNAT range, or outbound SSH (TCP/22)
- `iptables -L DOCKER-USER -n` contains DROP rules for LAN, CGNAT, and dpt:22
- `openclaw-config` volume exists and is not world-readable
- `HF_HUB_OFFLINE=1` in `qwen3-coder-next/.env`
- Agent shell tool disabled and sandbox enabled in `agent.json` (after onboarding)
- (`--macbook`) Every key in `~/.ssh/authorized_keys` has `from=` restriction

### Running tests locally

```bash
# From the Spark, with both containers running:
cd ~/code/spark-ai

# vLLM test (spins up a temp container on nim_net)
python3 tests/test_vllm.py

# Security test (runs on host)
python3 tests/test_security.py

# OpenClaw test (requires OpenClaw running)
TAILSCALE_IP=100.120.99.52 python3 tests/test_openclaw.py
```

### GitHub Actions CI

CI runs on push/PR to `main`. Because the Spark is not a GitHub-hosted runner, the
workflow uses a **self-hosted runner** registered on the Spark, or alternatively runs
only the host-side and structural tests (port binding checks, compose file validation,
`.env.example` completeness) without requiring the containers to be live.

The `.github/workflows/ci.yml` workflow:
1. Validate compose file syntax (`docker compose config` with dummy env vars)
2. Check that no `.env` files are committed
3. On self-hosted runner: run `test_security.py` and `test_vllm.py`

---

## Key Decisions and Rationale

**Why local LLM instead of cloud API for OpenClaw?**
The agent reads potentially sensitive organizational data from TPC survey responses.
Running the LLM locally on the Spark means that data never leaves the Spark during
inference. Cloud API calls would send sheet content to Anthropic/OpenAI servers.

**Why Qwen3-Coder-Next-FP8 and not a smaller model?**
The 80B MoE model activates only 3B parameters per forward pass, giving ~43 tok/s on
the Spark — fast enough for agentic workflows. It has strong tool-calling and instruction
following, which matters for reliable report generation. Smaller models tested (Qwen3-32B
dense) ran at 9 tok/s due to memory bandwidth limits at batch=1.

**Why two compose files instead of one?**
vLLM owns the Docker network and must start first. Keeping them separate allows
independent restarts, clearer security boundaries, and the ability to swap the inference
backend (e.g., to a future NVFP4 image) without touching the OpenClaw config.

**Why Telegram for initial testing and Slack for production?**
Telegram is faster to set up for initial validation. Slack is the production channel
because that's where TPC team communication happens.

**Why not use OpenClaw's built-in cloud deployment options?**
DigitalOcean/Hostinger deployments put the agent on shared infrastructure and require
routing sensitive data through cloud servers. The Spark is purpose-built for always-on
local AI and gives full control over the security boundary.

---

## Environment Reference

| Item | Value |
|---|---|
| Spark hostname | `spark-960b` |
| Spark user | `catlett` |
| Spark Tailscale IP | `100.120.99.52` |
| Spark LAN IP (Ethernet) | `10.0.5.124` |
| Spark LAN IP (WiFi) | `10.0.5.123` |
| LAN subnet | `10.0.4.0/22` (confirmed via `ip route show`) |
| Model | `Qwen/Qwen3-Coder-Next-FP8` |
| Model cache | `~/.cache/huggingface/hub/models--Qwen--Qwen3-Coder-Next-FP8/` |
| Workspace | `~/openclaw-workspace/` |
| vLLM image | `vllm-node` (local build) |
| vLLM build repo | `~/code/spark-vllm-docker/` |
| OpenClaw port | `18789` |
| vLLM port | `8000` (Docker-internal only) |
| Docker network | `qwen3-coder-next_nim_net` |
| vLLM startup time | ~2 min (model load 52s + torch.compile 28s + CUDA graphs 12s + warmup) |
| vLLM notable warnings | GDS not supported (no impact); missing MoE GB10 config (uses defaults); KV scale 1.0 (minor accuracy tradeoff) — all expected, none actionable |

---

## References

- OpenClaw docs: https://docs.openclaw.ai
- eugr vLLM community build: https://github.com/eugr/spark-vllm-docker
- Qwen3-Coder-Next-FP8: https://huggingface.co/Qwen/Qwen3-Coder-Next-FP8
- Tailscale: https://tailscale.com/kb
- HF token management: https://huggingface.co/settings/tokens
