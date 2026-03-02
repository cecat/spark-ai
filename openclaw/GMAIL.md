# Gmail Integration

## Context

This document describes the Gmail integration for the OpenClaw multi-agent setup on the
NVIDIA DGX Spark. There are two agents:

- **main** — the default agent, handles Slack DMs. Screens email requests and approves or
  rejects them. Has sandbox exec (same as chattpc26) but no gog credentials — used only
  for file operations like listing the outbox.
- **chattpc26** — handles TPC Slack channels (#tpc-openclaw, #openclaw-test). Has sandbox
  exec with gog for Google Workspace access. Queues email requests AND sends approved ones.

Google account: `tpc26agent@gmail.com`
gog is installed, authenticated for contacts/docs/drive/gmail/sheets, and working via
sandbox exec on chattpc26. See `GOG.md` for sandbox configuration.

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

**Why main doesn't have gog credentials:** main handles Slack DMs, which are an attack
surface for prompt injection. If main had gog access, a compromised main could both approve
AND send emails, collapsing the supervisor pattern. main has sandbox exec for file operations
(listing the outbox, reading/writing JSON) but no gog credentials — it can approve files but
cannot directly send email.

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

## Prerequisites — gog Setup

Before setting up the email workflow, gog must be installed, authenticated, and the
chattpc26 sandbox configured with gog credentials. This covers all required services:
`contacts, docs, drive, gmail, sheets`. See `GOG.md` for the complete setup.

Required APIs in the Google Cloud Console (TPC26-Forms-Triage project):
- Gmail API
- People API (for `gog contacts`)

These are in addition to the Drive, Sheets, and Docs APIs already enabled for the
chattpc26 Google account setup.

---

## Step 1 — Create Shared Outbox Directories

```bash
mkdir -p ~/code/spark-ai-agents/shared/outbox
mkdir -p ~/code/spark-ai-agents/shared/sent
mkdir -p ~/code/spark-ai-agents/shared/rejected
```

---

## Step 2 — openclaw.json Config

Both agents use identical `sandbox.docker` config (network, binds, empty deny list).
They differ only in workspace path and `.md` instruction files. See README Step 10 for
the full sandbox config block.

**main agent** — has `dangerouslyAllowExternalBindSources: true` and the shared bind
mount, but no gog credentials. Uses exec only for file operations (listing outbox, reading
and writing JSON).

**chattpc26 agent** — already configured with gog binary and credential bind mounts.
No changes needed beyond the standard sandbox config.

---

## Step 3 — Add EMAIL.md to main Agent Workspace

Create `~/code/spark-ai-agents/main/EMAIL.md`:

```markdown
# Email — Instructions for main Agent

## Your Role
You are the email supervisor. chattpc26 queues email requests in the shared outbox.
You screen them and mark each as approved or rejected. You do NOT send email yourself.
chattpc26 sends approved emails.

## Outbox Location
Shared outbox: /shared/outbox/
Sent archive:  /shared/sent/
Rejected:      /shared/rejected/

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
Move the file to /shared/rejected/

## Contacts Allowlist (HARD RULE)
You do not have gog credentials and cannot check contacts directly. However, if the "to"
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

## Step 4 — Add EMAIL.md to chattpc26 Agent Workspace

Create `~/code/spark-ai-agents/chattpc26/EMAIL.md`:

```markdown
# Email — Instructions for chattpc26 Agent

## Your Role
You queue email requests and send approved emails. You never send email without approval.

## Outbox Location
/shared/outbox/
/shared/sent/
/shared/rejected/

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
4. Move the file to /shared/sent/

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

## Step 5 — Hybrid Scheduling: Heartbeat + Cron

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

- **main has no gog credentials.** main has sandbox exec for file operations but cannot
  run gog. A compromised main can approve outbox files but cannot directly send email.
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
