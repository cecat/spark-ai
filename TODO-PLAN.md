# TODO-PLAN.md — Agent Self-Scheduling via TODO.md

**Status:** IMPLEMENTED
**Goal:** Allow agents to schedule future tasks from a DM prompt without sleeping
or editing HEARTBEAT.md.

See [`openclaw/TODO-IMPLEMENTATION.md`](openclaw/TODO-IMPLEMENTATION.md) for the full configuration reference.

---

## What OpenClaw Already Has (Verified)

| Mechanism | What it does | Frequency |
|---|---|---|
| Heartbeat | Sends HEARTBEAT.md prompt to agent | Configured per-agent in openclaw.json |
| Slack DM / channel | External trigger when message arrives | Real-time |

**What OpenClaw does NOT appear to have (despite web search claims):**
Native one-shot scheduled jobs (cron-style) and a `/hooks/agent` webhook endpoint are
not documented in the actual ONBOARDING.md or UPGRADE guides — treat those claims as
unreliable until verified against the gateway source.

---

## Core Architecture Decision

**Two-layer design: bash cron does the timing, heartbeat does the executing.**

```
Agent writes TODO.md entry (e.g., "5:00pm: DM Charlie to go home")
        ↓
check-todos.sh runs every 5 min (bash only, no LLM, no credentials)
        ↓ (when item is due)
Marks line READY in TODO.md
        ↓
Agent heartbeat fires (every 15 min), sees READY item, executes it
        ↓
Agent appends to todo.log, removes line from TODO.md
```

**Why this is better than cron-triggers-Slack:**
- No Slack bot token needed on the host — no new credentials anywhere
- The agent already has all the tools it needs (Slack, email, gog, etc.)
- Cron script is ~20 lines of bash, never needs updating regardless of task type
- All execution logic stays in the agent, not split across cron and agent

**Why a 15-minute heartbeat is fine:**
- Running a local model (Qwen3-Coder-Next-FP8) — no token cost
- Worst-case task latency: 14 minutes (acceptable for "remind me at 5pm")
- Heartbeat interval is per-agent in `openclaw.json` — can tune independently
  (e.g., a future expensive-model agent could stay at 1h or 2h)

---

## TODO.md Format

One line per task. Absolute UTC timestamp for reliable cross-timezone comparison.

```
2026-03-04T23:00:00Z | DM catlett@anl.gov: reminder to go home
2026-03-06T14:00:00Z | Send Monday track notification emails per IDENTITY.md item 5
2026-03-10T13:00:00Z | PLAN: /workspace/todos/plans/tpc26-report-2026-03-10.md
```

**Rules:**
- Timestamp is always UTC ISO-8601 (`Z` suffix)
- Agent converts user's relative or local time to UTC when writing the entry
  - "5pm today" → 5pm Central → UTC equivalent
  - "in 15 minutes" → current UTC + 15 min
  - "5pm CET" → 5pm Central Europe Time → UTC equivalent
- Task text is a one-line prompt (≤100 chars)
- For complex tasks: `PLAN: /workspace/todos/plans/<filename>.md` — agent creates
  the plan file and references it from the TODO entry

---

## File Structure

```
spark-ai-agents/
├── main/
│   └── TODO.md                    # main agent's scheduled tasks
├── chattpc26/
│   └── TODO.md                    # chattpc26's scheduled tasks
├── shared/
│   └── todos/
│       ├── todo.log               # append-only log: one line per completed task
│       └── plans/                 # detailed multi-step task plans
│           └── *.md
└── scripts/
    └── check-todos.sh             # NEW: bash cron, checks both TODO.md files
```

**Why `shared/todos/` (not per-agent)?**
- `todo.log` is one unified audit trail
- Plans in `plans/` can be handed between agents or reference work from both
- Cross-agent task coordination: main can create a plan file; chattpc26 picks it up

---

## TODO.md Entry Lifecycle

```
Agent writes entry → TODO.md (status: pending, implied by presence)
        ↓
check-todos.sh fires (every 5 min via cron; when timestamp ≤ now)
  → Rewrites line:  READY | <timestamp> | <task>
  → Logs to todo.log:  <ts> | TRIGGERED | <task>
        ↓
OpenClaw heartbeat fires (every 15 min)
Agent greps TODO.md for "^READY" lines, executes each task
        ↓  (on success)
Agent appends to todo.log:  2026-03-04T23:01:42Z | OK | DM catlett@anl.gov: reminder to go home
Agent removes READY line from TODO.md
        ↓  (on failure)
Simple task:  append to todo.log:  2026-03-04T23:01:42Z | FAIL | <task> | <reason ≤80 chars>
Plan task:    append to todo.log:  2026-03-04T23:01:42Z | FAIL | PLAN: /shared/todos/plans/foo.md
              agent updates foo.md with failure details
Agent prefixes line with FAILED | in TODO.md (prevents re-execution; no auto-retry)
Agent DMs Charlie to report what failed and why
```

**Log format:** `<UTC ISO timestamp> | OK|FAIL | <task or PLAN: path> [| <fail reason>]`

---

## check-todos.sh Design

```
Inputs:  main/TODO.md, chattpc26/TODO.md
Actions: for each line where timestamp ≤ now UTC and not already READY or DONE:
           - rewrite line with READY prefix:
             READY | 2026-03-04T23:00:00Z | DM catlett@anl.gov: reminder to go home
           - log to shared/todos/todo.log: <ts> | TRIGGERED | <task>
Requires: nothing — pure bash, no credentials, no API calls
Crontab:  */5 * * * * /home/catlett/code/spark-ai-agents/scripts/check-todos.sh
```

---

## HEARTBEAT.md Changes

Add one step to the existing checklist:

> Check `/workspace/TODO.md` for any lines prefixed `READY`.
> Execute each one using available tools (Slack, email, gog, etc.).
> On success: append `OK` line to `shared/todos/todo.log`, remove line from `TODO.md`.
> On failure: append `FAIL` line to `shared/todos/todo.log`, leave line in `TODO.md`
> with a `FAILED` prefix so it is not re-executed automatically.

The heartbeat is the **primary execution mechanism** (not a fallback).
Heartbeat frequency: **15 minutes** (set in `openclaw.json` per-agent).

---

## Agent Instructions Changes

Typed actions are a **finite, explicitly enumerated set**. Each typed action requires
instructions in two agent files — one governing write time, one governing execution time:

| File | When | Purpose |
|---|---|---|
| `SOUL.md` | Write time | How to form the entry; what data must be resolved interactively before writing |
| `HEARTBEAT.md` | Execution time | Dispatch table: prefix to match and exactly what to do when READY |

Adding a new typed action means updating both files for both agents, plus the supported
actions table in `openclaw/TODO-IMPLEMENTATION.md`.

### SOUL.md (both agents) — add to Core Truths:
> **Use TODO.md for deferred tasks.** When asked to do something at a future time
> or after an interval, write a timestamped entry to `/workspace/TODO.md` (UTC ISO-8601).
> Never sleep or block. Convert relative times ("in 15 min") and local times ("5pm Central")
> to UTC when writing the entry. Complex tasks get a plan file in
> `/shared/todos/plans/` — reference it from the TODO entry.

### Both TODO.md files — create with header comment explaining format

---

## Implementation Checklist

- [x] Create `main/TODO.md` (empty, with format comment)
- [x] Create `chattpc26/TODO.md` (empty, with format comment)
- [x] Create `shared/todos/` directory structure + empty `todo.log`
- [x] Write `scripts/check-todos.sh`
- [x] Update `main/HEARTBEAT.md` — add READY-item execution step
- [x] Update `chattpc26/HEARTBEAT.md` — same
- [x] Update `main/SOUL.md` and `chattpc26/SOUL.md` — add deferred-task rule
- [ ] Update `openclaw.json` — verify heartbeat is set to 15 min for main and chattpc26 *(verify on Spark)*
- [ ] Add crontab entry on Spark: `*/5 * * * * .../check-todos.sh` *(verify on Spark)*
- [ ] Update both `CHANGELOG.md` files *(in spark-ai-agents repo)*
- [ ] Test: ask main "remind me in 6 minutes that this works"

---

## Deferred / Out of Scope

- **Cross-agent task hand-off**: agent A writes a plan to `shared/todos/plans/` and
  messages agent B to pick it up — possible with current architecture, implement later
- **Recurring TODO items**: the format could support `REPEAT: 1w` suffixes, but start
  simple with one-shot tasks only
- **OpenClaw native webhooks**: if a future OpenClaw release confirms a stable
  `/hooks/agent` endpoint, `check-todos.sh` could call it directly as a lower-latency
  alternative to waiting for the next heartbeat
- **Google Calendar triggers**: watching for calendar events as an alternative TODO
  source — same architecture applies, different input to check-todos.sh
