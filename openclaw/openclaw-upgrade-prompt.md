# OpenClaw Upgrade Impact Analysis

## Instructions for the AI assistant

I'm considering upgrading OpenClaw (a self-hosted AI agent gateway) and need to know
what will break or require changes before I restart. My current config is below, followed
by the release notes I've pasted in. Please give me a concrete, config-specific analysis
— not a general summary of what's new.

---

## My Current openclaw.json

```json
{{OPENCLAW_JSON}}
```

---

## My Setup (key details beyond the config)

- **Hardware**: NVIDIA DGX Spark (ARM64, Ubuntu), running 24/7
- **Model**: Qwen3-Coder-Next-FP8 via vLLM, Docker-internal only (port 8000 not exposed)
- **Gateway exposure**: Tailscale Serve — HTTPS reverse proxy to port 18789 on Tailscale IP
- **Two agents**:
  - `main` — default agent, handles Slack DMs, email outbox approval via heartbeat
  - `chattpc26` — handles specific Slack channels, runs Google Workspace tools via `gog`
    CLI in sandbox containers
- **Sandbox**: both agents use `mode: all`, `dangerouslyAllowExternalBindSources: true`,
  with external bind mounts for a shared outbox directory and gog credentials
- **Slack**: Socket Mode, `streaming: false`, `groupPolicy: allowlist`, `dmPolicy: pairing`
- **Heartbeat**: main agent runs hourly (08:00–22:00 America/Chicago) to check email outbox
- **Volume**: config stored in Docker volume `openclaw_openclaw-config`

---

## Release Notes

[PASTE RELEASE NOTES HERE — copy from https://github.com/openclaw/openclaw/releases]

---

## What I Need

Work through the release notes against my config above and tell me:

**1. Must fix before restarting** (gateway will crash or misbehave without these)
List each change as: *what's breaking* → *exact edit needed in my config*

**2. Must fix after restarting** (post-upgrade steps, migrations, re-pairing, etc.)

**3. Watch out for** (non-breaking but relevant to my setup — sandbox behavior, bind mount
handling, Tailscale proxy, multi-agent routing, heartbeat, Slack Socket Mode)

**4. Verdict**: upgrade now, wait, or prerequisites needed first?

Skip anything that clearly doesn't apply to my setup. Be specific about which config keys
or sections are affected — quote from my config where relevant.
