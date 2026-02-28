# GOG / Google Access via Sandbox Exec

## Status: Working (2026-02-28)

`gog auth list` succeeds from the chattpc26 agent in Slack. Google Docs, Drive, and
Sheets access is fully authenticated.

## Architecture

OpenClaw's sandbox spawns ephemeral Docker containers for tool execution. The `gog`
binary and credentials are bind-mounted into these containers. No host exec, no
exec-approvals system involved.

**Why not host exec (`tools.exec.host: "gateway"`):** OpenClaw wraps shell strings in
`/bin/sh -c "..."`, so the exec-approvals allowlist sees `/bin/sh` (not `/usr/local/bin/gog`)
and blocks it. The exec-approvals CLI is also broken in self-hosted installs ("pairing required").
Sandbox exec bypasses this entire layer.

## Google Cloud / OAuth Setup

- Google Cloud project: **TPC26-Forms-Triage**
  (The original tpc26-488714 was disabled by Google for ToS violation — a new project
  was required before re-auth could proceed.)
- OAuth account: `chattpc26@gmail.com`
- Services authorized: drive, sheets, docs
- Keyring: **file-based** (not GNOME keyring — use `GOG_KEYRING_BACKEND=file`)
- Keyring password: stored in openclaw.json sandbox env (see below)

### Install gog and authenticate on host

```bash
# Install gog (if not already present)
# Download from https://github.com/openclaw/gog/releases and place at /usr/local/bin/gog

# Authenticate using file-based keyring
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=sparkagent2026
gog auth login --account chattpc26@gmail.com

# Verify
gog auth list
# Should show: chattpc26@gmail.com  default  docs,drive,sheets
```

Token files live at `~/.config/gogcli/keyring/token:default:chattpc26@gmail.com`
and `~/.local/share/keyrings/` on the host.

### Install gog skill

```bash
npx playbooks add skill openclaw/skills --skill gog
# Installs to ~/.agents/skills/gog
```

## openclaw.json — chattpc26 Agent Config

Key facts about the sandbox container:
- Rootfs is **read-only** → `HOME` must be `/tmp`; bind targets must use `/tmp` prefix
- `GOG_KEYRING_BACKEND=file` (not `GOG_KEYRING=file` — that env var does not work)
- `GOG_KEYRING_PASSWORD` is required for file-based keyring decryption
- Credentials mounted read-write (needed for OAuth token refresh)

```json
{
  "id": "chattpc26",
  "workspace": "/home/node/agents/chattpc26",
  "tools": { "deny": [] },
  "sandbox": {
    "mode": "all",
    "docker": {
      "binds": [
        "/home/catlett/.config/gogcli:/tmp/.config/gogcli:rw",
        "/home/catlett/.local/share/keyrings:/tmp/.local/share/keyrings:rw",
        "/usr/local/bin/gog:/usr/local/bin/gog:ro"
      ],
      "env": {
        "GOG_KEYRING_BACKEND": "file",
        "GOG_KEYRING_PASSWORD": "sparkagent2026",
        "GOG_ACCOUNT": "chattpc26@gmail.com",
        "HOME": "/tmp"
      },
      "network": "qwen3-coder-next_nim_net"
    }
  }
}
```

## docker-compose.yml additions (openclaw-gateway service)

The gog skill must be visible inside the gateway container for OpenClaw to load it.
Add to volumes:

```yaml
- /home/catlett/.agents:/home/node/.agents:ro
```

The gogcli credentials do NOT need to be mounted into the gateway container — only into
the sandbox containers (handled by `sandbox.docker.binds` above).

## Deploy config changes

```bash
cat /tmp/openclaw-new.json | docker exec -i openclaw-gateway sh -c 'cat > /home/node/.openclaw/openclaw.json'
cd ~/code/spark-ai/openclaw && docker compose restart openclaw-gateway
```

## Verify

```bash
# In Slack, message chattpc26:
# "run gog auth list"
# Expected: chattpc26@gmail.com  default  docs,drive,sheets

# Watch sandbox containers spawn:
watch docker ps

# Gateway logs:
docker logs openclaw-gateway --tail 30
```

## Security

**Sandbox containers get:**
- gog binary (read-only)
- gogcli credentials (read-write for token refresh)
- Network via nim_net (required for Google APIs)
- Workspace read-write

**Sandbox containers do NOT get:**
- docker.sock (no container escape)
- Host filesystem beyond workspace + explicit binds
- SSH keys or host credentials
- LAN or Tailscale access (iptables blocks 10.0.4.0/22 and 100.64.0.0/10)

**Residual risk:** Sandbox has outbound internet for Google APIs. A sophisticated prompt
injection could exfiltrate data via HTTP. Mitigated by dedicated minimal-scope Google
account and periodic log review.

## Config snapshot

Pre-sandbox config: `~/code/spark-ai-agents/_snapshots/openclaw-pre-sandbox-20260227-162821.json`
