# ARCHITECTURE.md — Agent Scheduling & Execution Architecture

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
file state belongs in bash or Python. Anything that requires judgment, synthesis,
or natural-language output belongs in the LLM. Keep these layers separate.

This principle extends beyond scheduling — it applies to *all* deterministic operations
the agent needs to perform. See the next section.

---

## Task Execution Architecture: RUNBOOKs + Scripts

When a CALENDAR or TODO entry fires, the agent needs to know *how* to do the work.
Two complementary patterns handle this:

### RUNBOOKs — Step-by-Step Procedures

A `RUNBOOK_<topic>.md` file lives in the agent's `runbooks/` directory and gives
the agent step-by-step instructions for a specific recurring task. The CALENDAR
entry names the runbook; the agent follows it when the task fires.

```
CALENDAR.md entry:
  DAILY 14:00 | Run data-sync script, then post summary per runbooks/RUNBOOK_DAILY_SYNC.md

runbooks/RUNBOOK_DAILY_SYNC.md:
  Step 1: exec python3 scripts/sync-data.py
  Step 2: check errors, DM admin if any
  Step 3: post summary using counts from script output
```

RUNBOOKs are written by humans and never modified by agents during autonomous
execution. The authoring flow for any new recurring duty is three files:
1. One line in the agent's identity file — *what* the duty is
2. One file `runbooks/RUNBOOK_X.md` — *how* to execute it
3. One line added to `CALENDAR.md` — *when* to execute it

### Scripts — Deterministic Tools

For operations that are purely mechanical — read data, transform it, write it
somewhere — the LLM should **not** reason about the implementation at execution
time. Instead, a Python or bash script in `scripts/` handles the operation
deterministically and returns structured output (typically JSON) that the LLM
reads and acts on.

```
LLM's role:    exec: python3 scripts/sync-data.py
               read JSON output → compose message → post

Script's role: read source → route rows → dedup → append → return counts
```

This mirrors the scheduling principle: the LLM does cognitive work (composition,
judgment, communication); scripts do mechanical work (data movement, counting,
file operations). The boundary is clean:

| Operation type | Owner | Why |
|---------------|-------|-----|
| *When* to act | `check-todos.sh` (bash) | Deterministic; zero tokens |
| *How* to move/transform data | `scripts/*.py` (Python) | Deterministic; no LLM drift |
| *What* to say / *whether* to act | LLM | Requires judgment |

Scripts are essentially **registered tools** for the agent — the equivalent of
function-calling in an API context, but running deterministically in the sandbox.
The RUNBOOK tells the agent which tool to call and what to do with the output.

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

**Location:** Agent workspace (one per agent)

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

DAILY    14:00 | Run daily sync script per runbooks/RUNBOOK_DAILY_SYNC.md
MON,THU  14:00 | Send notification emails per runbooks/RUNBOOK_NOTIFICATIONS.md
```

**How it works:** `check-todos.sh` reads CALENDAR.md every 5 minutes. When a
recurring entry is due (day matches, time has passed, not yet fired today), the
script writes a `READY` entry into the agent's `TODO.md`. The next heartbeat picks
it up and executes it exactly as it would any other READY item — no new agent-side
logic needed.

**State tracking:** `check-todos.sh` records last-fired timestamps in a JSON state
file (keyed by agent + days + time + task text). This is the ground truth for
deduplication — not the agent's memory.

**Location:** Agent workspace (one per agent)

---

## TODO.md — Ad Hoc Tasks

**What belongs here:** One-shot tasks the agent defers to a future time. "DM Ian
at 3pm," "send the report after I approve it," "retry this in 20 minutes." The
agent writes these at runtime; `check-todos.sh` promotes them to READY when due;
the heartbeat executes and removes them.

**What does NOT belong here:** Recurring tasks. If a task needs to happen again
next week, it belongs in CALENDAR.md, not TODO.md. An agent that re-schedules
its own recurring tasks in TODO.md will eventually forget after a session reset.

**Location:** Agent workspace (one per agent)

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
| `HEARTBEAT.md` | Agent workspace | Human | Forever routines (runs every heartbeat) |
| `CALENDAR.md` | Agent workspace | Human | Recurring scheduled duties |
| `TODO.md` | Agent workspace | Agent (runtime) | One-shot deferred tasks |
| `RUNBOOK_<topic>.md` | `runbooks/` in agent workspace | Human | Step-by-step instructions for a specific task |
| `check-todos.sh` | `scripts/` (shared) | Human | Bash scheduler — promotes due items to READY |
| `<tool>.py` / `<tool>.sh` | `scripts/` (shared) | Human | Deterministic tools called by agent via exec |
| `calendar-state.json` | Runtime state (shared) | `check-todos.sh` | Last-fired timestamps (dedup) |

---

## LLM Inference: Prefill vs. Generation (Why TTFT Is Interactive)

The DGX Spark GB10 runs Qwen3-Coder-Next-FP8 at approximately 50 tokens/second.
A common and reasonable concern: if each agent interaction sends 40,000+ characters
of system prompt plus conversation history (~10,000+ tokens), does that mean
10,000 ÷ 50 = 200 seconds before any output appears? No — because the 50 tps figure
applies only to **output generation**, not to **input processing**. These are
physically different operations.

### Phase 1 — Prefill (processing the input)

All input tokens are processed **in parallel** as a single large matrix multiplication
across the GPU. Because every input token is known before generation begins, the GPU
computes attention for all positions simultaneously, saturating its parallel compute
capacity. For 10,000 input tokens, prefill takes roughly **1–3 seconds** on the GB10.
Time To First Token (TTFT) equals the prefill time — the user sees output as soon as
prefill completes.

### Phase 2 — Generation (producing the output)

Each output token depends on the previous one, so generation is **sequential**.
Every step requires loading the full model weight matrix from memory — a
memory-bandwidth-bound operation that runs at ~50 tokens/second. A 200-token
response takes about 4 seconds to generate.

### The Math

| Phase | Tokens | Mechanism | Approximate time |
|-------|--------|-----------|-----------------|
| Prefill (input) | ~10,000 | Parallel GPU matrix ops | 1–3 seconds |
| Generation (output) | ~200 | Sequential, memory-bandwidth-bound | ~4 seconds |
| **Total to complete response** | | | **~5–7 seconds** |

Doubling the input context from 10K to 20K tokens adds ~1–2 seconds to prefill,
not minutes. The 150K-token system prompt budget OpenClaw supports would take
roughly 15–30 seconds to prefill — fast, not the hours the naive calculation implies.

### Why Session History Eventually Causes Latency

Session history is where context size genuinely hurts. A Slack channel with months
of conversation history can accumulate tens of thousands of turns. Unlike the
system prompt (which is bounded by the 150K budget), session history grows without
a hard cap until the session is reset. A session of several hundred thousand tokens
will produce multi-minute prefill times regardless of GPU speed.

This is why `reset-sessions.sh` runs nightly: not to reduce system prompt size
(which is already bounded), but to prevent unbounded session history growth.
See `spark-ai-agents/ARCHITECTURE.md` → OpenClaw Context Architecture for the
full details on what gets loaded, caps, and behavioral implications for agents.
