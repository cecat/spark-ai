# Agent Self-Scheduling via TODO.md

This document describes how OpenClaw agents can schedule future tasks without sleeping,
blocking, or requiring human intervention at execution time. The design rationale is in
`../TODO-PLAN.md`.

---

## Context

By default, agents only act in response to an inbound message (Slack DM, channel post)
or a heartbeat firing. There is no native mechanism for an agent to say "do X in 15
minutes" without either sleeping (blocking) or firing heartbeats continuously.

This integration adds a lightweight self-scheduling layer:

- Agents write timestamped TODO entries to a file in their workspace
- A host cron script marks entries `READY` when their timestamp arrives
- The agent's heartbeat detects `READY` items and executes them using its existing tools

No new credentials are required. No agent sandbox changes are needed. The cron script
is ~40 lines of pure bash.

---

## Architecture

```
Agent writes to TODO.md:
  2026-03-04T23:00:00Z | DM catlett@anl.gov: reminder to go home

check-todos.sh runs every 5 min (bash, no LLM, no credentials)
  → detects timestamp ≤ now
  → rewrites line:  READY | 2026-03-04T23:00:00Z | DM catlett@anl.gov: reminder to go home
  → logs to shared/todos/todo.log: <ts> | TRIGGERED | <task>

Agent heartbeat fires (every 15 min)
  → greps TODO.md for "^READY" lines
  → executes each task using existing tools (Slack, email outbox, gog, exec, etc.)
  → on success: removes line from TODO.md, appends OK to todo.log
  → on failure: prefixes line with FAILED in TODO.md, appends FAIL to todo.log, DMs Charlie
```

**Why cron marks READY instead of triggering the agent directly:**
Triggering the agent would require posting a Slack message (needs bot token on host) or
a gateway API call (unverified feature). Writing a flag to a file requires nothing — the
agent reads it on its next heartbeat. This keeps all new credentials off the host.

**Why heartbeat instead of a more frequent LLM wakeup:**
Running a local model (no token cost) makes 15-minute heartbeats practical. Worst-case
latency for a scheduled task is ~14 minutes. The cron script itself runs every 5 minutes
and is essentially free (a few file reads and timestamp comparisons).

---

## TODO.md Format

One task per line. Timestamps are always UTC ISO-8601 with `Z` suffix.

```
2026-03-04T23:00:00Z | DM catlett@anl.gov: reminder to go home
2026-03-09T14:00:00Z | Send Monday track notification emails per IDENTITY.md
2026-03-10T13:00:00Z | PLAN: /workspace/todos/plans/weekly-report-2026-03-10.md
```

**States (managed by cron and agent, not written by hand):**
```
READY  | 2026-03-04T23:00:00Z | <task>   ← cron marks when timestamp ≤ now
FAILED | 2026-03-04T23:00:00Z | <task>   ← agent marks on execution failure (no retry)
```

**Rules:**
- Agent always converts relative/local times to UTC when writing entries
  - "in 15 minutes" → current UTC + 15 min
  - "5pm Central" → 5pm America/Chicago in UTC
- Task descriptions ≤ 100 characters
- Complex tasks use `PLAN: /workspace/todos/plans/<filename>.md` — agent creates the
  plan file before writing the TODO entry

---

## File Structure

```
spark-ai-agents/
├── main/
│   └── TODO.md                      # main agent's scheduled tasks
├── chattpc26/
│   └── TODO.md                      # chattpc26's scheduled tasks
├── shared/
│   └── todos/
│       ├── todo.log                 # append-only audit log
│       └── plans/                   # complex task plan files (*.md)
└── scripts/
    └── check-todos.sh               # host cron script
```

`todo.log` format: `<UTC ISO timestamp> | TRIGGERED|OK|FAIL | <task> [| <reason>]`

---

## Step 1 — Create Directory Structure

```bash
mkdir -p ~/code/spark-ai-agents/shared/todos/plans
touch ~/code/spark-ai-agents/shared/todos/todo.log
```

Create `~/code/spark-ai-agents/main/TODO.md`:

```
# TODO.md — main agent scheduled tasks
#
# Format:
#   2026-03-04T23:00:00Z | <task description>
#
# Timestamps are always UTC (Z suffix). Agent converts local/relative times to UTC.
# READY and FAILED prefixes are managed by cron and heartbeat — do not write them manually.
```

Create `~/code/spark-ai-agents/chattpc26/TODO.md` with the same header, adjusted for chattpc26.

---

## Step 2 — Install check-todos.sh

Create `~/code/spark-ai-agents/scripts/check-todos.sh`:

```bash
#!/bin/bash
# check-todos.sh — Mark due TODO items as READY for agent heartbeat to execute.
# Runs every 5 minutes via cron. No credentials required.
#
# Crontab:
#   */5 * * * * /home/catlett/code/spark-ai-agents/scripts/check-todos.sh >> \
#               /home/catlett/code/spark-ai-agents/shared/todos/cron.log 2>&1

set -euo pipefail

BASE_DIR="$HOME/code/spark-ai-agents"
TODO_FILES=(
    "$BASE_DIR/main/TODO.md"
    "$BASE_DIR/chattpc26/TODO.md"
)
LOG_FILE="$BASE_DIR/shared/todos/todo.log"
NOW=$(date -u +%s)

log() {
    echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | $*" >> "$LOG_FILE"
}

mark_ready() {
    local file="$1"
    local tmp="${file}.tmp"
    local changed=0

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments, blanks, and already-processed lines
        if [[ "$line" =~ ^# ]] || [[ -z "$line" ]] || \
           [[ "$line" =~ ^READY[[:space:]]*\| ]] || \
           [[ "$line" =~ ^FAILED[[:space:]]*\| ]]; then
            echo "$line"
            continue
        fi

        # Match: YYYY-MM-DDTHH:MM:SSZ | task
        if [[ "$line" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z)[[:space:]]*\|[[:space:]]*(.+)$ ]]; then
            ts="${BASH_REMATCH[1]}"
            task="${BASH_REMATCH[2]}"
            ts_epoch=$(date -u -d "$ts" +%s 2>/dev/null || \
                       date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$ts" +%s 2>/dev/null || echo 0)

            if [[ "$ts_epoch" -le "$NOW" && "$ts_epoch" -gt 0 ]]; then
                echo "READY | $ts | $task"
                log "TRIGGERED | $task"
                changed=1
            else
                echo "$line"
            fi
        else
            echo "$line"
        fi
    done < "$file" > "$tmp"

    if [[ "$changed" -eq 1 ]]; then
        mv "$tmp" "$file"
    else
        rm -f "$tmp"
    fi
}

for todo_file in "${TODO_FILES[@]}"; do
    [[ -f "$todo_file" ]] && mark_ready "$todo_file"
done
```

```bash
chmod +x ~/code/spark-ai-agents/scripts/check-todos.sh
```

---

## Step 3 — Add Crontab Entry

```bash
(crontab -l; echo '*/5 * * * * /home/catlett/code/spark-ai-agents/scripts/check-todos.sh >> /home/catlett/code/spark-ai-agents/shared/todos/cron.log 2>&1') | crontab -
```

---

## Step 4 — Set Heartbeat to 15 Minutes

Edit `openclaw.json` in the Docker config volume. The agents key is `config["agents"]["list"]`.
For each agent with `"heartbeat": {"every": "1h"}`, change to `"every": "15m"`.

Convenience script (runs inside the volume, no host python permissions issue):

```bash
docker run --rm -v openclaw_openclaw-config:/data alpine sh -c "
apk add --quiet --no-cache python3 2>/dev/null
python3 -c '
import json
path = \"/data/openclaw.json\"
with open(path) as f:
    config = json.load(f)
changed = []
for agent_config in config.get(\"agents\", {}).get(\"list\", []):
    if \"heartbeat\" in agent_config and agent_config[\"heartbeat\"].get(\"every\") == \"1h\":
        agent_config[\"heartbeat\"][\"every\"] = \"15m\"
        changed.append(agent_config.get(\"id\", \"?\"))
with open(path, \"w\") as f:
    json.dump(config, f, indent=2)
print(\"Updated:\", changed)
'"
```

Then restart the gateway:

```bash
cd ~/code/spark-ai/openclaw && docker compose restart
```

---

## Step 5 — Update Agent Instructions

### HEARTBEAT.md (both agents)

Add as the first section, before email outbox review:

```markdown
## TODO.md — Scheduled Task Execution

Check `/workspace/TODO.md` for any lines prefixed `READY`:

    exec: grep "^READY" /workspace/TODO.md

If there are none, proceed to the next checklist item.

For each `READY` line:
1. Parse the task: `READY | <timestamp> | <task description>`
2. Execute the task using available tools (Slack DM, email outbox, exec, etc.)
   - For `PLAN:` tasks: read the referenced `.md` file for detailed steps
3. On success:
   - exec: echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | OK | <task>" >> /shared/todos/todo.log
   - Remove the READY line from TODO.md
4. On failure:
   - exec: echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) | FAIL | <task> | <reason>" >> /shared/todos/todo.log
   - Prefix the line with FAILED in TODO.md (prevents re-execution)
   - DM Charlie to report what failed and why
```

### SOUL.md (both agents) — add to Core Truths

```markdown
**Use TODO.md for deferred tasks.** When asked to do something at a future time or after
an interval, write a timestamped entry to `/workspace/TODO.md` (UTC ISO-8601) — never
sleep or block waiting for the time to arrive. Convert relative or local times to UTC when
writing the entry. For complex tasks, create a plan file at
`/shared/todos/plans/<filename>.md` and reference it as `PLAN: /shared/todos/plans/<filename>.md`.
The heartbeat will execute READY items automatically.
```

---

## Verification

```bash
# 1. Confirm crontab is installed
crontab -l | grep check-todos

# 2. Confirm heartbeat interval
docker run --rm -v openclaw_openclaw-config:/data alpine \
  cat /data/openclaw.json | python3 -m json.tool | grep -A3 '"heartbeat"'

# 3. End-to-end test — DM main agent in Slack:
#    "remind me in 6 minutes that the TODO system works"
#
#    Expected sequence:
#    a. main writes a UTC+6min entry to /workspace/TODO.md
#    b. Within 5 min, check-todos.sh marks it READY
#    c. Within 15 min, heartbeat fires, agent sees READY, sends you a Slack DM
#    d. Line removed from TODO.md; OK entry in shared/todos/todo.log

# 4. Monitor during test
watch -n 10 'cat ~/code/spark-ai-agents/main/TODO.md; echo "---"; tail -5 ~/code/spark-ai-agents/shared/todos/todo.log'
```

---

## Design Decisions

**Why not trigger the agent via Slack API?**
Posting a Slack message from the cron script requires the bot token on the host (another
secret to manage). Writing a `READY` flag to a file requires nothing — the agent reads it
on its next heartbeat.

**Why not a more frequent heartbeat (e.g., every 5 min)?**
Each heartbeat is an LLM inference call. At 5-minute intervals, that's 288 calls/day just
to check "is it time yet?" — mostly finding nothing. The 5-min cron + 15-min heartbeat
split means cron does the cheap check, LLM only runs when there is actual work to do.

**Why not OpenClaw's native cron?**
OpenClaw's native scheduling features (if any) are not reliably documented in the
ONBOARDING or UPGRADE guides. This approach uses only documented, stable primitives:
heartbeat, shared file mounts, and host cron.

**Why does the FAILED prefix prevent retry?**
A task that fails likely requires human diagnosis (wrong tool, missing credential, etc.).
Automatically retrying would loop forever. Charlie sees the FAILED line in TODO.md and
the FAIL entry in todo.log, investigates, and either fixes the issue or removes the line.

**Extending to chattpc26:**
chattpc26 does not currently have a heartbeat configured. To enable TODO scheduling for
chattpc26, add a heartbeat block to its entry in `openclaw.json` (same format as main).
