# Google Integration via gog

## Overview

`gog` is the CLI tool OpenClaw uses to access Google Workspace APIs (Drive, Sheets, Docs,
Gmail, Contacts) from inside sandbox containers. It authenticates via OAuth and stores
tokens in a file-based keyring on the host, which is bind-mounted read-write into the
chattpc26 sandbox so tokens can auto-refresh.

**Google account:** `tpc26agent@gmail.com` (dedicated, minimal-scope)
**Google Cloud project:** TPC26-Forms-Triage
**Services authorized:** `contacts, docs, drive, gmail, sheets`
**Agent with gog access:** `chattpc26` only — main has no gog credentials by design

See `GMAIL.md` for the email workflow (outbox pattern, approval, cron sending). This
document covers only the gog/Google setup.

---

## Google Cloud Project Setup

### Create the project and enable APIs

1. Go to [console.cloud.google.com](https://console.cloud.google.com) and create a new project.
   Name it something descriptive (e.g. `TPC26-Forms-Triage`).

   > **Note:** The original project `tpc26-488714` was disabled by Google for a ToS
   > violation (likely OAuth consent screen configuration). If your project gets disabled,
   > create a new one, re-configure OAuth, and re-run `gog auth login`.

2. Go to **APIs & Services → Enabled APIs** and enable each service you need:
   - Google Drive API
   - Google Sheets API
   - Google Docs API
   - Gmail API
   - People API (required for `gog contacts`)

3. Go to **APIs & Services → OAuth consent screen**:
   - User type: External
   - Add the scopes for each enabled API
   - Add your agent Google account as a test user

4. Go to **APIs & Services → Credentials → Create Credentials → OAuth 2.0 Client ID**:
   - Application type: Desktop app
   - Download the credentials JSON — gog will need this during auth

---

## Install gog

Download the `gog` binary from the releases page and place it on the host:

```bash
# Download and install (replace VERSION with the current release)
curl -Lo /usr/local/bin/gog https://github.com/openclaw/gog/releases/download/VERSION/gog-linux-arm64
chmod +x /usr/local/bin/gog
gog --version
```

Install the gog skill so OpenClaw can load it inside the gateway container:

```bash
npx playbooks add skill openclaw/skills --skill gog
# Installs to ~/.agents/skills/gog
```

Then add to `openclaw/docker-compose.yml` under the gateway service volumes so the skill
is visible inside the container:

```yaml
- /home/YOUR_USER/.agents:/home/node/.agents:ro
```

The gog credentials do **not** need to be mounted into the gateway container — only into
the sandbox containers (handled by `sandbox.docker.binds`).

---

## Authenticate

Run the initial OAuth flow on the host. Use the file-based keyring — GNOME keyring is not
available in headless/Docker environments.

```bash
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw)   # see next section
gog auth login --account tpc26agent@gmail.com \
  --services drive,sheets,docs,gmail,contacts \
  --force-consent
```

Verify all services are authorized:

```bash
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth list
# Expected: tpc26agent@gmail.com  default  contacts,docs,drive,gmail,sheets  oauth
```

Token files are stored at:
- `~/.config/gogcli/keyring/token:default:tpc26agent@gmail.com`
- `~/.local/share/keyrings/` (keyring metadata)

---

## Keyring Password — Wrapper Script Approach

**The problem:** OpenClaw strips environment variables whose names contain security-sensitive
keywords (`PASSWORD`, `SECRET`, `TOKEN`). Setting `GOG_KEYRING_PASSWORD` directly in
`sandbox.docker.env` means the sandbox container never sees it — gog fails silently.

**The solution:** A wrapper script reads the password from a file at runtime and exports it
before calling the real `gog` binary.

### Step 1 — Write the password to a file

```bash
echo -n 'your-keyring-password' > ~/.config/gogcli/.gog_pw
chmod 600 ~/.config/gogcli/.gog_pw
```

### Step 2 — Create the wrapper script

Create `~/.config/gogcli/gog-wrapper` (this is what the sandbox calls as `gog`):

```bash
#!/bin/sh
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD="$(cat /tmp/.config/gogcli/.gog_pw)"
export GOG_ACCOUNT="tpc26agent@gmail.com"
exec /usr/local/bin/gog-real "$@"
```

```bash
chmod +x ~/.config/gogcli/gog-wrapper
```

### Step 3 — Bind-mount the wrapper and real binary

In `sandbox.docker.binds`, mount the wrapper as `gog` and the real binary under a
different name:

```json
"/home/YOUR_USER/.config/gogcli/gog-wrapper:/usr/local/bin/gog:ro",
"/usr/local/bin/gog:/usr/local/bin/gog-real:ro"
```

The sandbox calls `gog` (the wrapper), which reads the password from the bind-mounted
credential file, then delegates to `gog-real` (the actual binary).

---

## openclaw.json — chattpc26 Sandbox Config

Key constraints for the sandbox container:
- Rootfs is **read-only** — all writable paths must use `/tmp` as a prefix
- `HOME` must be `/tmp` (not `/home/node` — that path doesn't exist with write access)
- Use `GOG_KEYRING_BACKEND=file` (not `GOG_KEYRING=file` — that env var does nothing)
- Credentials mounted read-write so OAuth tokens can auto-refresh

```json
{
  "id": "chattpc26",
  "workspace": "/home/YOUR_USER/code/spark-ai-agents/chattpc26",
  "tools": { "deny": [] },
  "sandbox": {
    "mode": "all",
    "workspaceAccess": "rw",
    "docker": {
      "network": "qwen3-coder-next_nim_net",
      "dangerouslyAllowExternalBindSources": true,
      "env": {
        "GOG_KEYRING_BACKEND": "file",
        "GOG_ACCOUNT": "tpc26agent@gmail.com",
        "HOME": "/tmp"
      },
      "binds": [
        "/home/YOUR_USER/.config/gogcli/gog-wrapper:/usr/local/bin/gog:ro",
        "/usr/local/bin/gog:/usr/local/bin/gog-real:ro",
        "/home/YOUR_USER/.config/gogcli:/tmp/.config/gogcli:rw",
        "/home/YOUR_USER/.local/share/keyrings:/tmp/.local/share/keyrings:rw",
        "/home/YOUR_USER/code/spark-ai-agents/shared:/shared:rw"
      ]
    }
  }
}
```

> **Important:** Use **host paths** for workspace and all bind-mount sources.
> See README Step 8 for why gateway-internal paths silently break sandboxes.

> **Important (v2026.2.26+):** Bind targets under `/workspace` are blocked — use paths
> outside `/workspace` (e.g. `/shared`, `/tmp`). `dangerouslyAllowExternalBindSources`
> is required when any source path is outside the agent workspace root.

---

## Verification

Test from the host first (bypassing sandbox):

```bash
# Gmail
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog gmail search "newer_than:1d" --account tpc26agent@gmail.com --plain

# Contacts
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog contacts list --account tpc26agent@gmail.com --plain

# Drive / Sheets
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog drive list --account tpc26agent@gmail.com --plain
```

Then test from the sandbox — message chattpc26 in Slack:

```
run: gog auth list
```

Expected response:
```
tpc26agent@gmail.com  default  contacts,docs,drive,gmail,sheets  oauth
```

Watch sandbox containers spawn during the test:
```bash
watch docker ps   # look for openclaw-sbx-agent-chattpc26
```

---

## Re-authentication

OAuth tokens auto-refresh when the sandbox has network access and credentials are
mounted read-write. If a token refresh fails (e.g. after a long downtime or revocation),
re-authenticate on the host:

```bash
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw)
gog auth login --account tpc26agent@gmail.com \
  --services drive,sheets,docs,gmail,contacts \
  --force-consent
```

Then restart the gateway so the sandbox picks up fresh credentials:

```bash
cd ~/code/spark-ai/openclaw && docker compose restart openclaw-gateway
```

---

## Security

**Sandbox containers get:**
- gog wrapper + real binary (both read-only)
- gogcli credentials and keyring (read-write, for token refresh)
- Shared outbox directory (read-write)
- Network access via nim_net (required for Google APIs)
- Workspace read-write

**Sandbox containers do NOT get:**
- docker.sock (no container escape)
- Host filesystem beyond workspace + explicit binds
- SSH keys or host credentials
- LAN or Tailscale access (iptables blocks 10.0.4.0/22 and 100.64.0.0/10)

**Residual risk:** Sandbox has outbound internet for Google APIs. A sophisticated prompt
injection could exfiltrate data via HTTP to an external server. Mitigated by a dedicated
minimal-scope Google account and periodic log review.

**Why main has no gog access:** main handles Slack DMs — an attack surface for prompt
injection. Giving main gog credentials would allow a compromised main to both approve
and send emails, collapsing the outbox supervision pattern. See `GMAIL.md`.
