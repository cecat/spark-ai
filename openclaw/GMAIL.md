# Gmail Integration Plan

## Context for Warp

This document describes the Gmail integration for the OpenClaw multi-agent setup on the
NVIDIA DGX Spark. There are two agents:

- **main** — the default agent, handles Slack DMs. Will send Gmail on behalf of the system.
- **chattpc26** — handles TPC Slack channels (#tpc-openclaw, #openclaw-test). Reads Google
  Sheets/Docs/Drive via the `gog` skill with sandbox exec. Will queue emails for main to review.

Google account for all email: `chattpc26@gmail.com`
gog is already installed, authenticated for drive/sheets/docs, and working via sandbox exec
on the chattpc26 agent. The gog skill is at `~/.agents/skills/gog`. See `GOG-SANDBOX-PLAN.md`
for the full sandbox configuration that chattpc26 already uses.

---

## Architecture: Supervised Email

chattpc26 **never sends email directly**. It writes JSON files to a shared outbox.
main reads the outbox on a schedule, screens each message, and sends or rejects it.
This gives main supervisory control over all outbound email.

```
chattpc26 → shared/outbox/*.json → main (screens) → gog gmail send → recipient
                                                   → shared/sent/ or shared/rejected/
```

---

## Outbox JSON Schema

File naming: `YYYYMMDD-HHMMSS-<slug>.json` (timestamp prefix ensures ordering)

```json
{
  "to": "recipient@example.com",
  "subject": "Subject line",
  "body": "Full email body text. Plain text only, no HTML.",
  "requested_by": "chattpc26",
  "requested_at": "2026-02-28T14:30:00Z",
  "context": "One sentence explaining why this email is being sent — for main's screening use only, not included in the email."
}
```

JSON is used (not plaintext) because main needs to reliably parse fields, enforce
per-recipient rate limits by inspecting the `to` field, and log structured records.

---

## Step 1 — Add Gmail Scope to gog Auth

The existing chattpc26@gmail.com token was authorized for drive/sheets/docs only.
Add gmail scope:

```bash
export GOG_KEYRING_BACKEND=file
export GOG_KEYRING_PASSWORD=sparkagent2026
gog auth login chattpc26@gmail.com --scopes gmail
# Or if gog requires re-auth of all scopes together:
gog auth login chattpc26@gmail.com --scopes drive,sheets,docs,gmail
```

Verify:
```bash
gog auth list
# Should show gmail in the scope list for chattpc26@gmail.com
gog gmail ls --account chattpc26@gmail.com
# Should list inbox without error
```

---

## Step 2 — Create Shared Outbox Directories

```bash
mkdir -p ~/code/spark-ai-agents/shared/outbox
mkdir -p ~/code/spark-ai-agents/shared/sent
mkdir -p ~/code/spark-ai-agents/shared/rejected
```

---

## Step 3 — Update main Agent openclaw.json Config

Main currently has `tools.deny: ["exec","process","bash"]`. This must change to allow
sandbox exec, same pattern as chattpc26. Add a `sandbox.docker` block to the main agent.

```json
{
  "id": "main",
  "default": true,
  "workspace": "/home/node/agents/main",
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

Deploy:
```bash
cat /tmp/openclaw-new.json | docker exec -i openclaw-gateway sh -c \
  'cat > /home/node/.openclaw/openclaw.json'
cd ~/code/spark-ai/openclaw && docker compose restart openclaw-gateway
```

---

## Step 4 — Add EMAIL.md to main Agent Workspace

Create `~/code/spark-ai-agents/main/EMAIL.md`:

```markdown
# Email — Instructions for main Agent

## Your Role
You are the email supervisor. chattpc26 queues emails in the shared outbox. You screen
and send them, or reject them. You are the only agent that sends email.

## Outbox Location
Shared outbox: /home/node/agents/shared/outbox/
Sent archive:  /home/node/agents/shared/sent/
Rejected:      /home/node/agents/shared/rejected/

Check the outbox every hour (see HEARTBEAT.md for schedule). Process all pending .json files.

## How to Send
```
gog gmail send --account chattpc26@gmail.com --to <to> --subject <subject> --body <body>
```
After sending, move the file to shared/sent/. After rejection, move to shared/rejected/
and append a `rejected_reason` field to the JSON before moving.

## Screening Rules — Apply All of These

**Rate limits (hard rules — never override):**
- No more than 2 emails to any single recipient in a 24-hour period. Check shared/sent/
  for recent messages to that address before sending.
- No more than 10 emails total from the system in any 24-hour period.

**Content standards:**
- Professional, respectful tone at all times. No casual insults, sarcasm directed at
  recipients, or language that could be read as condescending.
- No NSFW content of any kind.
- Emails must be clearly from an automated TPC system — do not impersonate Charlie or
  other individuals by name as the sender.
- Body must be substantive. Reject empty, placeholder, or test emails.
- Subject must accurately describe the content. Reject misleading subject lines.

**Consent and relevance:**
- Only send to recipients who have a clear, established relationship with TPC (e.g.,
  survey respondents, registered members, known collaborators). Do not send cold outreach
  to unknown addresses.
- Content must be relevant to TPC activities. Reject anything off-topic.
- If the same substantive content was already sent to the same recipient recently,
  reject as duplicate.

**When in doubt, reject.** It is always better to skip an email than to send something
inappropriate. Log your reason in the rejected file.

## Rejection Examples
- Duplicate content sent in last 7 days → reject
- Recipient already received 2 emails today → reject, retry tomorrow
- Tone is overly casual or could be read as spam → reject, ask chattpc26 to revise
- No clear TPC relevance → reject
- Body is empty or a test string → reject
```

---

## Step 5 — Add EMAIL.md to chattpc26 Agent Workspace

Create `~/code/spark-ai-agents/chattpc26/EMAIL.md`:

```markdown
# Email — Instructions for chattpc26 Agent

## Your Role
You do not send email. You request email by writing JSON files to the shared outbox.
main reviews and sends them. This is intentional — main is the email supervisor.

## Outbox Location
/home/node/agents/shared/outbox/

## How to Queue an Email
Write a JSON file named: YYYYMMDD-HHMMSS-<short-slug>.json

Required fields:
- to: recipient email address
- subject: clear, accurate subject line
- body: full email text, plain text only
- requested_by: "chattpc26"
- requested_at: ISO 8601 timestamp
- context: one sentence explaining why this is being sent (for main's review only)

Example:
```json
{
  "to": "researcher@example.org",
  "subject": "TPC Survey Summary — February 2026",
  "body": "Dear colleague,\n\nHere is a summary of...",
  "requested_by": "chattpc26",
  "requested_at": "2026-02-28T14:30:00Z",
  "context": "Monthly survey summary for active TPC member who opted in to updates."
}
```

## Standards — Follow These When Composing

- Professional and respectful tone. You represent TPC.
- Relevant to TPC activities only.
- Only queue email to people with an established TPC relationship.
- Do not queue the same content twice to the same person.
- No more than one email per task to any given recipient — if you need to contact
  multiple people, queue separate files.
- main may reject your request. Check shared/rejected/ if you expect a confirmation
  and do not see the email in shared/sent/.
```

---

## Step 6 — Update HEARTBEAT.md

Add to `~/code/spark-ai-agents/main/HEARTBEAT.md` (or create it):

```markdown
## Scheduled Tasks

### Hourly — Email Outbox Check
Every hour: check /home/node/agents/shared/outbox/ for pending .json files.
For each file, apply the screening rules in EMAIL.md and either send or reject.
This runs even if there is no other activity.
```

---

## Verification

```bash
# Test gog gmail on host:
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=sparkagent2026 \
  gog gmail ls --account chattpc26@gmail.com

# In Slack, DM main:
# "check the email outbox"
# Expected: "Outbox is empty" or it processes any pending files

# End-to-end test: manually write a test JSON to the outbox, then ask main to
# check the outbox and confirm it screens and sends (or rejects) correctly.
```

---

## Security Notes

- Enabling sandbox exec on main is a deliberate tradeoff. The main agent gains exec
  capability, but it runs in ephemeral containers with no host access — same model as
  chattpc26. See PLAN.md security section.
- chattpc26 cannot send email directly. The outbox pattern means all email passes
  through a supervisory screening step.
- The blast radius of a compromised chattpc26 is limited: it can queue emails, but
  main's screening rules provide a second layer of defense.
- Review shared/sent/ and shared/rejected/ logs periodically for unexpected patterns.
