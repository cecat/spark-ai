# OpenClaw Onboarding Log

**Date:** 2026-02-24  
**Version:** OpenClaw 2026.2.17  
**Platform:** DGX Spark (spark-960b), Ubuntu  
**Goal:** Minimal, security-first configuration for TPC survey reporting use case

This file records every onboarding decision and the rationale behind it.
Update as you progress through each step.

---

## Step 1 — Security Warning

**Prompt:** "I understand this is powerful and inherently risky. Continue?"

**Decision:** ✅ Yes

**Notes:** We have read and understood the warning. Our security model (iptables,
scoped workspace, shell disabled, dedicated Google/Slack accounts) directly addresses
the risks listed. Shell tool will remain disabled throughout.

---

## Step 2 — Gateway Bind Address

**What OpenClaw will ask:** Where should the gateway listen?
Options are typically `localhost`, `lan` (all LAN interfaces), or a specific IP.

**Decision:** Choose `lan` or the specific Tailscale IP (`100.120.99.52`).

**Rationale:** Our Docker port binding in `docker-compose.yml` already restricts
port 18789 to the Tailscale IP — that is the real enforcement boundary. The gateway
bind address inside the container should be permissive enough for Docker to route to
it, so `lan` or `0.0.0.0` inside the container is fine. The security comes from the
`ports:` line in compose, not from the gateway bind setting itself.

---

## Step 3 — AI Provider / Model

**What OpenClaw will ask:** Which AI provider?

**Decision:** Select "OpenAI-compatible" (custom/local).

**Settings:**
- Base URL: `http://nim:8000/v1`
- API key: `dummy` (vLLM doesn't require a real key)
- Model: `Qwen/Qwen3-Coder-Next-FP8`

**Rationale:** `nim` is the Docker container hostname for vLLM on the shared
`qwen3-coder-next_nim_net` network. Using a local model means TPC survey data
never leaves the Spark during inference.

---

## Step 4 — Workspace

**What OpenClaw will ask:** Where is your workspace?

**Decision:** `/home/node/workspace`

**Rationale:** This is the container-side path where `~/openclaw-workspace` on the
Spark host is mounted. Do NOT enter a host path here — enter the container path.

---

## Step 5 — Sandboxing

**What OpenClaw will ask:** Enable agent sandboxing?

**Decision:** ✅ Yes — enable sandboxing.

**Rationale:** Sandboxing runs agent tool execution in a nested container, isolating
it from the gateway process itself. This is the single most important security setting
after disabling the shell tool.

---

## Step 6 — Shell Tool

**What OpenClaw will ask:** Enable shell/exec tool?

**Decision:** ❌ No — leave shell DISABLED.

**Rationale:** This is the highest-risk tool. A compromised agent with shell access
could attempt to SSH out, exfiltrate files, or install software. Our iptables rules
block outbound SSH as a backstop, but the primary control is keeping shell disabled.
Do not enable unless you have a specific, understood need.

---

## Step 7 — Messaging Channel

**What OpenClaw will ask:** Which channel(s) to connect?

**Decision:** Telegram (for initial setup and testing).
Slack will be added later as the production channel for TPC reporting.

**Steps:**
1. Get a bot token from @BotFather on Telegram (`/newbot`)
2. Enter the token when prompted
3. After onboarding, approve the pairing code OpenClaw sends to your Telegram

**DM Policy:** Set to `pairing` (not `open`) — only your paired account can
command the agent.

---

## Step 8 — Skills

**What OpenClaw will ask:** Install any skills?

**Decision:** ❌ Skip all skills for now.

**Rationale:** Skills are plugins that run with agent permissions. Only install
skills whose source you have reviewed. Start with zero and add only what is
needed for the TPC reporting use case (Google Sheets, Slack) once the base
config is verified stable.

---

## Post-Onboarding Checklist

Run these after onboarding completes:

```bash
# Confirm gateway is running
docker compose ps

# Confirm port binding is Tailscale IP only
ss -tlnp | grep 18789
# Must show 100.120.99.52:18789 — NOT 0.0.0.0:18789

# Check gateway logs look clean
docker compose logs --tail=50 openclaw-gateway

# Run security audit
docker compose exec openclaw-gateway node dist/index.js security audit --deep
```

---

## Decisions Log

| Step | Decision | Rationale |
|---|---|---|
| Security warning | Accepted | Understood; mitigations in place |
| Gateway bind | `lan` or Tailscale IP | Docker ports: line is the real enforcement |
| AI provider | OpenAI-compatible, local | `http://nim:8000/v1`, model stays on Spark |
| Workspace | `/home/node/workspace` | Container path, not host path |
| Sandboxing | Enabled | Isolates tool execution from gateway |
| Shell tool | Disabled | Highest-risk tool; iptables as backstop |
| Channel | Telegram (initial) | Fast to set up; Slack added later |
| DM policy | `pairing` | Only paired account can command agent |
| Skills | None for now | Review source before installing any |

---

## Outstanding Items After Onboarding

- [ ] Approve Telegram pairing code
- [ ] Verify port binding with `ss -tlnp | grep 18789`
- [ ] Apply iptables rules (see README.md)
- [ ] Run `openclaw security audit --deep`
- [ ] Add Slack channel (production use)
- [ ] Connect Google account for Sheets/Docs access
- [ ] Test: ask agent to summarize content via Telegram
- [ ] Update PLAN.md Phase 3 checklist items
