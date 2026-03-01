# Gmail Integration Plan

## Context

This document describes the Gmail integration for the OpenClaw multi-agent setup on the
NVIDIA DGX Spark. There are two agents:

- **main** — the default agent, handles Slack DMs. Screens email requests, approves or
  rejects them. Does NOT have exec access — stays locked down.
- **chattpc26** — handles TPC Slack channels (#tpc-openclaw, #openclaw-test). Has sandbox
  exec with gog for Google Workspace access. Queues email requests AND sends approved ones.

Google account: `tpc26agent@gmail.com`
gog is installed, authenticated for contacts/docs/drive/gmail/sheets, and working via
sandbox exec on chattpc26. See `GOG-SANDBOX-PLAN.md` for sandbox configuration.

---

## Architecture: Supervised Email with Contacts Allowlist

chattpc26 **never sends email without approval**. It writes JSON files to a shared outbox.
main reads the outbox (triggered by cron → Slack DM), screens each message, and writes an
approval or rejection. chattpc26 then sends approved emails via `gog gmail send`.

Recipients are restricted to the tpc26agent@gmail.com Google Contacts list. This is managed
by the human operator (Charlie), not by the agents. Both agents check contacts before
queuing or sending — if the recipient isn't in contacts, the email is rejected.

```
chattpc26 → shared/outbox/*.json → main (screens, writes approved/rejected)
                                 → chattpc26 picks up approved → gog gmail send → recipient
                                 → moves to shared/sent/ or shared/rejected/
```

**Why main stays exec-free:** main handles Slack DMs, which are an attack surface for
prompt injection. If main had exec, a compromised main could both approve AND send emails,
collapsing the supervisor pattern. By keeping main exec-free, a compromised main can only
approve files — it cannot directly send email or run arbitrary commands.

---

## Contacts Allowlist

The tpc26agent@gmail.com Google Contacts list serves as a hard recipient allowlist.

**Management:** Charlie manages contacts by hand via the Google Contacts web UI
(contacts.google.com signed in as tpc26agent@gmail.com) or via `gog contacts create`
on the Spark host. Agents do NOT add, modify, or delete contacts.

**Enforcement:** Before queuing (chattpc26) or approving (main), check that the recipient
exists in contacts:
```bash
gog contacts search "recipient@example.com" --account tpc26agent@gmail.com --plain
```
If no result is returned, reject the email. This is a hard rule — never override.

**Scope:** The `contacts` scope is included in the OAuth token. The agent has read-write
access to contacts (Google doesn't offer read-only scopes for contacts), but agent
instructions prohibit modification. The contacts API also needs to be enabled in the
Google Cloud Console (TPC26-Forms-Triage project).

---

## Outbox JSON Schema

File naming: `YYYYMMDD-HHMMSS-<slug>.json` (timestamp prefix ensures ordering)

**Atomic writes:** Always write to a `.tmp` file first, then rename to `.json`.
Both agents must ignore `.tmp` files. This prevents reading half-written JSON.

```json
{
  "to": "recipient@example.com",
  "subject": "Subject line",
  "body": "Full email body text. Plain text only, no HTML.",
  "requested_by": "chattpc26",
  "requested_at": "2026-02-28T14:30:00Z",
  "context": "One sentence explaining why this email is being sent — for main's screening use only, not included in the email.",
  "status": "pending"
}
```

When main screens the file, it updates the JSON in place:
- Approved: sets `"status": "approved"`, adds `"approved_at": "<timestamp>"`
- Rejected: sets `"status": "rejected"`, adds `"rejected_at"` and `"rejected_reason"`
  then moves the file to `shared/rejected/`

chattpc26 watches the outbox for files with `"status": "approved"`, sends them, then
moves to `shared/sent/` with `"sent_at"` added.

---

## Step 1 — Add Gmail + Contacts Scopes to gog Auth (DONE)

The token has been re-authorized with all needed scopes:
```
tpc26agent@gmail.com  default  contacts,docs,drive,gmail,sheets  oauth
```

The Gmail API is enabled in the TPC26-Forms-Triage Google Cloud project.
The People (Contacts) API must also be enabled — same one-click toggle in the Console.

Verified working:
```bash
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog gmail search "newer_than:1d" --account tpc26agent@gmail.com --plain
```
> Note: Inside sandbox containers, use the `gog` wrapper (which reads the password
> from file automatically). The above syntax is for host-side testing only.

---

## Step 2 — Enable People API in Google Cloud Console

Go to APIs & Services → Enabled APIs in the TPC26-Forms-Triage project.
Enable "People API" (used by `gog contacts`). This is a one-click toggle.

Verify:
```bash
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog contacts list --account tpc26agent@gmail.com --plain
```

---

## Step 3 — Create Shared Outbox Directories

```bash
mkdir -p ~/code/spark-ai-agents/shared/outbox
mkdir -p ~/code/spark-ai-agents/shared/sent
mkdir -p ~/code/spark-ai-agents/shared/rejected
```

---

## Step 4 — openclaw.json Config

**main agent — NO changes to exec.** Keep `tools.deny: ["exec", "process", "bash"]`.
main only reads/writes JSON files in the shared directory. It does not need exec.

**chattpc26 agent — already configured.** Has sandbox exec with gog binds.
No config changes needed.

---

## Step 5 — Add EMAIL.md to main Agent Workspace

Create `~/code/spark-ai-agents/main/EMAIL.md`:

```markdown
# Email — Instructions for main Agent

## Your Role
You are the email supervisor. chattpc26 queues email requests in the shared outbox.
You screen them and mark each as approved or rejected. You do NOT send email yourself.
chattpc26 sends approved emails.

## Outbox Location
Shared outbox: /home/node/agents/shared/outbox/
Sent archive:  /home/node/agents/shared/sent/
Rejected:      /home/node/agents/shared/rejected/

## When to Check
You will receive a Slack DM reminder to check the outbox. When you receive it, process
all pending .json files (status: "pending"). Ignore .tmp files.

## How to Approve
Read the JSON file. If it passes all screening rules, update the file:
- Set "status" to "approved"
- Add "approved_at" with the current ISO 8601 timestamp
Write the updated JSON back to the same file.

## How to Reject
Update the JSON file:
- Set "status" to "rejected"
- Add "rejected_at" with the current ISO 8601 timestamp
- Add "rejected_reason" with a clear explanation
Move the file to /home/node/agents/shared/rejected/

## Contacts Allowlist (HARD RULE)
You do not have exec access and cannot check contacts directly. However, if the "to"
address is not someone you recognize as a known TPC contact, reject the email.
chattpc26 is also required to verify contacts before queuing — this is a backup check.

## Screening Rules — Apply All of These

**Rate limits (hard rules — never override):**
- No more than 2 emails to any single recipient in a 24-hour period. Check shared/sent/
  for recent messages to that address before approving.
- No more than 10 emails total from the system in any 24-hour period.

**Content standards:**
- Professional, respectful tone at all times.
- No NSFW content of any kind.
- Emails must be clearly from an automated TPC system — do not impersonate Charlie or
  other individuals by name as the sender.
- Body must be substantive. Reject empty, placeholder, or test emails.
- Subject must accurately describe the content. Reject misleading subject lines.

**Consent and relevance:**
- Only approve emails to recipients with a clear, established TPC relationship.
  Do not approve cold outreach to unknown addresses.
- Content must be relevant to TPC activities. Reject anything off-topic.
- If the same substantive content was already sent to the same recipient recently,
  reject as duplicate.

**When in doubt, reject.** It is always better to skip an email than to send something
inappropriate.

## Rejection Examples
- Duplicate content sent in last 7 days → reject
- Recipient already received 2 emails today → reject
- Tone is overly casual or could be read as spam → reject
- No clear TPC relevance → reject
- Body is empty or a test string → reject
- Recipient not recognized as TPC contact → reject
```

---

## Step 6 — Add EMAIL.md to chattpc26 Agent Workspace

Create `~/code/spark-ai-agents/chattpc26/EMAIL.md`:

```markdown
# Email — Instructions for chattpc26 Agent

## Your Role
You queue email requests and send approved emails. You never send email without approval.

## Outbox Location
/home/node/agents/shared/outbox/
/home/node/agents/shared/sent/
/home/node/agents/shared/rejected/

## Contacts Allowlist (HARD RULE — CHECK BEFORE QUEUING)
Before writing any email to the outbox, verify the recipient is in Google Contacts:
```
gog contacts search "recipient@example.com" --account tpc26agent@gmail.com --plain
```
If no result is returned, do NOT queue the email. Inform the user that the recipient
is not in the approved contacts list and ask them to add the contact first.

## How to Queue an Email
1. Verify recipient is in contacts (see above).
2. Write JSON to a temp file: YYYYMMDD-HHMMSS-slug.json.tmp
3. Rename .tmp to .json (atomic write — prevents main from reading partial files).

Required fields:
- to: recipient email address
- subject: clear, accurate subject line
- body: full email text, plain text only
- requested_by: "chattpc26"
- requested_at: ISO 8601 timestamp
- context: one sentence explaining why (for main's review only, not in the email)
- status: "pending"

## How to Send Approved Emails
Periodically check the outbox for files with "status": "approved".
For each approved file:
1. Verify recipient is still in contacts (re-check).
2. Send:
```
gog gmail send --account tpc26agent@gmail.com --to <to> --subject "<subject>" --body "<body>" --force --no-input
```
3. Update the JSON: add "sent_at" with current timestamp, set "status" to "sent".
4. Move the file to /home/node/agents/shared/sent/

## Standards — Follow These When Composing
- Professional and respectful tone. You represent TPC.
- Relevant to TPC activities only.
- Do not queue the same content twice to the same person.
- No more than one email per task to any given recipient.
- Check shared/rejected/ if an expected email wasn't sent — main may have rejected it.

## Do NOT
- Send email without an approved outbox file.
- Modify or delete contacts.
- Send to addresses not in the contacts list.
- Override a rejection by main — if rejected, revise and re-queue.
```

---

## Step 7 — Hybrid Scheduling: Heartbeat + Cron

The email flow uses two scheduling mechanisms, each chosen for what it does best:

### Approval: OpenClaw Heartbeat (main agent)

The main agent's heartbeat wakes it every hour to review the outbox. This requires
LLM judgment (screening content, checking rate limits, recognizing contacts), so it
uses OpenClaw's native heartbeat mechanism.

**openclaw.json** — added to main agent config:
```json
"heartbeat": {
  "every": "1h",
  "activeHours": {
    "start": "08:00",
    "end": "22:00",
    "timezone": "America/Chicago"
  }
}
```

**HEARTBEAT.md** — created in main's workspace (`~/code/spark-ai-agents/main/HEARTBEAT.md`):
- Check `shared/outbox/` for pending .json files
- Apply screening rules from EMAIL.md
- Approve or reject each file
- Reply HEARTBEAT_OK if nothing pending

Heartbeats are skipped outside active hours (before 8am / after 10pm Central).
Since vLLM runs locally, there is no token cost — only GPU compute time.

### Sending: Host Cron Script

Sending approved emails is purely mechanical: check status, verify contacts, run
`gog gmail send`. No LLM judgment needed. A bash script does this more reliably
and cheaply than an agent.

**Script:** `~/code/spark-ai-agents/scripts/send-approved-emails.sh`
- Scans `shared/outbox/` for files with `"status": "approved"`
- Verifies recipient is in Google Contacts (hard check)
- Runs `gog gmail send` for each
- Updates JSON with `"sent_at"` and moves to `shared/sent/`
- Rejects to `shared/rejected/` if contact check fails at send time
- Logs all actions to `shared/send-email.log`

**Crontab:** `*/30 * * * *` (every 30 minutes)

### Why hybrid?
- **Heartbeat for approval** — needs LLM judgment (content screening, context)
- **Cron for sending** — deterministic, no LLM needed, more reliable
- **Decoupled** — approval and sending happen independently; cron works even if
  the gateway is temporarily down

---

## Step 8 — Add Contacts Scope to Auth Token

Re-auth with contacts scope added:
```bash
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog auth add tpc26agent@gmail.com --services drive,sheets,docs,gmail,contacts \
  --manual --force-consent
```

Enable the People API in Google Cloud Console (TPC26-Forms-Triage project).

Verify:
```bash
GOG_KEYRING_BACKEND=file GOG_KEYRING_PASSWORD=$(cat ~/.config/gogcli/.gog_pw) \
  gog contacts list --account tpc26agent@gmail.com --plain
```

Restart gateway after re-auth:
```bash
cd ~/code/spark-ai/openclaw && docker compose restart openclaw-gateway
```

---

## Verification

```bash
# 1. Verify gmail works from sandbox (ask chattpc26 in Slack):
#    "run: gog gmail search newer_than:1d --account tpc26agent@gmail.com --plain"

# 2. Verify contacts works from sandbox:
#    "run: gog contacts list --account tpc26agent@gmail.com --plain"

# 3. End-to-end test:
#    a. Add a test contact (yourself) to tpc26agent@gmail.com contacts
#    b. Manually write a test JSON to shared/outbox/ with status: "pending"
#    c. Wait for main's heartbeat (or DM main: "check the email outbox")
#    d. Verify main approves (check file status changed to "approved")
#    e. Wait for cron (or run: ~/code/spark-ai-agents/scripts/send-approved-emails.sh)
#    f. Verify email arrives and file moves to shared/sent/
#    g. Check shared/send-email.log for the send record
```

---

## Security Notes

- **main stays exec-free.** `tools.deny: ["exec", "process", "bash"]` is preserved.
  main can only read/write files in the workspace. A compromised main cannot send
  email directly or run arbitrary commands.
- **Contacts as allowlist.** Recipients must be in Google Contacts, managed by the
  human operator. Even if both agents are compromised, they can only email addresses
  that Charlie has explicitly approved.
- **Two-layer sending.** main approves via heartbeat (LLM judgment), cron script sends
  (mechanical). The cron script also re-checks the contacts allowlist at send time.
- **Atomic file writes.** Temp-file-then-rename prevents race conditions.
- **Honest limitation:** The agent separation is instruction-based, not system-enforced.
  chattpc26 has sandbox exec and could in theory bypass the outbox and send directly.
  The contacts allowlist is the hard backstop — even a rogue chattpc26 can only reach
  addresses in the contacts list.
- **Cron is independent.** The send script runs on the host, not inside OpenClaw.
  It works even if the gateway is restarting, and its log (`shared/send-email.log`)
  provides an auditable record of all sent and rejected emails.
