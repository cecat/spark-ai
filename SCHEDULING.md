# SCHEDULING.md — Agent Scheduling Framework

## The Three Tiers

OpenClaw agents have a heartbeat — a recurring LLM session that fires every 15
minutes. Out of the box, that is the only scheduling primitive available. It works
fine for always-on routines, but it is a poor fit for one-time or infrequent tasks.
As with humans, agents benefit from having three distinct tools: a heartbeat for
reflexes, a calendar for recurring duties, and a to-do list for one-off reminders.
Understanding which to use — and why — is the key to keeping the system efficient,
reliable, and maintainable.

### The Human Analogy

| Mechanism | Human analog | Lifecycle | Owned by |
|-----------|-------------|-----------|----------|
| `HEARTBEAT.md` | Brushing teeth, checking email | Forever, while agent lives | Human (edit file) |
| `CALENDAR.md` | "Send Mon/Thu reports through June" | Finite season or recurring duty | Human or agent (edit file) |
| `TODO.md` | "Call the dentist", "pick up eggs" | One-shot, ad hoc | Agent (writes at runtime) |

---

## Design Principle: Shell for Scheduling, LLM for Reasoning

**LLM inference is expensive and non-deterministic. Bash is free and exact.**
The system is designed so that the *decision of when to act* is always made by
deterministic code (a cron-driven bash script), and the *act of doing the work*
is handled by the LLM. These two responsibilities must not be mixed.

### The Token-Waste Problem

A 15-minute heartbeat fires **672 times per week**
(4/hr × 24 hr × 7 days). If an agent uses HEARTBEAT.md to decide
whether it is time to run a recurring task, it must reason through the question
on every single heartbeat — including the 671 times the answer is "no":

| Task frequency | Heartbeats/week | Useful fires | Wasted reasoning calls | Waste rate |
|---------------|-----------------|--------------|------------------------|------------|
| Once a week | 672 | 1 | **671** | 99.9% |
| Twice a week (Mon+Thu) | 672 | 2 | **670** | 99.7% |
| Once a day (weekdays) | 672 | 5 | **667** | 99.3% |
| Once a day (every day) | 672 | 7 | **665** | 99.0% |

Beyond token cost, LLM-based scheduling is also fragile: the agent must
remember whether it already ran the task today — state that does not survive
a session reset. It will sometimes fire twice, sometimes not at all.

### The Solution: Push Scheduling Into Bash

`check-todos.sh` is a plain bash script that runs via cron every 5 minutes.
It computes — deterministically, with zero tokens — whether any scheduled task
is due. When one is, it writes a single `READY` flag into the agent's `TODO.md`.
The agent's next heartbeat then does exactly one thing: check if a flag was set.

```
cron (bash, every 5 min, zero tokens)
  └─ check-todos.sh
       ├─ reads CALENDAR.md → is a recurring entry due? → writes READY to TODO.md
       └─ reads TODO.md     → is a one-shot entry past-due? → marks READY in-place

OpenClaw heartbeat (LLM, every 15 min, tokens only when READY work exists)
  └─ agent greps TODO.md for ^READY
       ├─ nothing found → HEARTBEAT_OK  (cheap: no reasoning required)
       └─ READY found   → execute task  (this is where the LLM earns its keep)
```

The 671 wasted reasoning sessions collapse to 671 near-free grep operations.
The LLM only does cognitive work when there is actually something to do.

**General rule:** Anything that can be expressed as a condition on time, date, or
file state belongs in bash. Anything that requires judgment, synthesis, or
natural-language output belongs in the LLM. Keep these layers separate.

---

## HEARTBEAT.md — Always On

**What belongs here:** Tasks the agent should perform on *every* heartbeat, for the
lifetime of the agent. Infrastructure-level routines: check the TODO queue for READY
items, scan for rejected emails, watch for anomalies. Things that are genuinely
always relevant.

**What does NOT belong here:** Day-of-week logic, "only on Mondays," time-window
checks, or anything that requires the agent to remember whether it already ran today.
Putting calendar-style logic in HEARTBEAT.md creates a fragile implicit state machine
and wastes tokens on every heartbeat. Use CALENDAR.md instead.

**Location:** `/workspace/HEARTBEAT.md` (one per agent workspace)

---

## CALENDAR.md — Recurring Duties

**What belongs here:** Any task that repeats on a schedule but is not a permanent
forever-duty. Conference season reporting, weekly check-ins, quarterly reviews —
anything with a day-of-week or interval pattern.

**Format:**
```
# CALENDAR.md — <agent name> recurring duties
# Format: DAYS HH:MM UTC | task description
# DAYS: DAILY | WEEKDAYS | WEEKENDS | MON TUE WED THU FRI SAT SUN | MON,THU
#
# task description follows the same conventions as TODO.md:
#   plain text, SLACK_DM | <id> | <msg>, SLACK_POST | <id> | <msg>, PLAN: <path>

WEEKDAYS 14:00 | Read master sheet, sync track sheets, post Slack summary per RUNBOOK_LIGHTNING_TALKS.md
MON,THU  14:00 | Send track notification emails per IDENTITY.md
```

**How it works:** `check-todos.sh` reads CALENDAR.md every 5 minutes. When a
recurring entry is due (day matches, time has passed, not yet fired today), the
script writes a `READY` entry into the agent's `TODO.md`. The next heartbeat picks
it up and executes it exactly as it would any other READY item — no new agent-side
logic needed.

**State tracking:** `check-todos.sh` records last-fired timestamps in
`shared/todos/calendar-state.json` (keyed by agent + days + time + task text).
This is the ground truth for deduplication — not the agent's memory.

**Location:** `/workspace/CALENDAR.md` (one per agent workspace)

---

## TODO.md — Ad Hoc Tasks

**What belongs here:** One-shot tasks the agent defers to a future time. "DM Ian
at 3pm," "send the report after I approve it," "retry this in 20 minutes." The
agent writes these at runtime; `check-todos.sh` promotes them to READY when due;
the heartbeat executes and removes them.

**What does NOT belong here:** Recurring tasks. If a task needs to happen again
next week, it belongs in CALENDAR.md, not TODO.md. An agent that re-schedules
its own recurring tasks in TODO.md will eventually forget after a session reset.

**Location:** `/workspace/TODO.md` (one per agent workspace)

---

## Execution Flow (all three tiers)

```
cron (every 5 min)
  └─ check-todos.sh
       ├─ reads CALENDAR.md  → promotes due entries → writes READY to TODO.md
       └─ reads TODO.md      → promotes past-due entries → marks READY in-place

OpenClaw heartbeat (every 15 min)
  └─ agent reads HEARTBEAT.md
       └─ greps TODO.md for READY lines → executes → removes line → logs
```

---

## Files at a Glance

| File | Location | Edited by | Purpose |
|------|----------|-----------|---------|
| `HEARTBEAT.md` | `/workspace/` | Human | Forever routines (runs every heartbeat) |
| `CALENDAR.md` | `/workspace/` | Human or agent | Recurring scheduled duties |
| `TODO.md` | `/workspace/` | Agent (runtime) | One-shot deferred tasks |
| `check-todos.sh` | `scripts/` | Human | Bash scheduler — promotes due items to READY |
| `calendar-state.json` | `shared/todos/` | `check-todos.sh` | Last-fired timestamps (dedup) |
