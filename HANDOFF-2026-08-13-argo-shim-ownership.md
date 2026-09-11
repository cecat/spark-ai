# HANDOFF 2026-08-13 — argo-shim single-ownership refactor

> ## PROMPT FOR THE NEW SESSION — paste or say "read this file"
>
> You are picking up work on the Spark's three `start-all.sh` scripts. Read this
> whole file first; it is the complete context. Do not re-derive it.
>
> **The situation:** a refactor is code-complete and committed locally in four
> repos, but **nothing is pushed**. It is gated on one manual test: Charlie
> reboots the machine and runs `~/start-all.sh` (see §5). That is the only code
> path that could not be verified safely while the stack was live.
>
> **Start by asking Charlie how the reboot went.** Then:
>
> - **If it went clean** → confirm the four repos are still ahead of origin
>   (§4), then push. Also handle the open items in §7 — especially that
>   `run-stack-health.sh` is untracked and needs `git add -f`.
> - **If it failed** → diagnose from the exit code, the failing layer, and
>   `tail -30 ~/code/spark-ai/argo-shim.log`. Fix, commit **on top** (never
>   amend), re-test, then push.
>
> **Before you act, know these three things:**
>
> 1. §2 lists two confident claims from the prior session that turned out to be
>    **false**. Read it before reasoning about argo-shim, or you will repeat
>    them.
> 2. Do not add any start/restart/kill of argo-shim to a child script. The
>    master is the sole owner — that is the entire point of this work (§3).
> 3. `~/start-all.sh` is now a **symlink**. Edit through it, never `cp` over it.
>
> Verify claims in this file against the current code before acting on them —
> it is a point-in-time snapshot.


**Status:** code complete, committed locally in 4 repos, **nothing pushed**.
Waiting on one thing: Charlie reboots the machine the morning of 2026-08-14 and
runs `~/start-all.sh`. If clean → push. If not → diagnose, fix, commit, push.

---

## 1. What was wrong

All three `start-all.sh` scripts had their own
`pkill -f "argo-shim --port 44497"`, firing on a **single** failed health probe.
That probe is a live LLM round-trip over an SSH tunnel to Argonne, so ordinary
latency read as "dead" and killed a healthy shim.

Evidence (from `spark-ai-agents/shared/logs/stack-health.log` + `slack/sent/`):

- 34 failed cron runs in the 7 days to 2026-08-13; 200 runs logged since 05-27.
- **Every** one of the 34 was this bug (`argo-shim did not become healthy` ×34).
- 20 cascaded into recreating a **healthy** gateway, because `gateway_health_ok`
  probes Argo *through* socat — kill the shim and the gateway looks dead too.
- First occurrence 2026-07-14. A month of self-inflicted 3:30am Slack pages.

Why it mattered: `spark-ai/start-all.sh` is run **unattended by cron every 6h**
(`run-stack-health.sh`, 03:30/09:30/15:30/21:30 CT).

## 2. Two corrections to earlier claims (don't re-introduce these)

Both were asserted by me earlier in the session and are **wrong**:

1. **"socat blocks argo-shim's port check."** False. Binding `172.19.0.1:44497`
   does not block `127.0.0.1:44497` — verified by direct socket test. The
   `Address already in use` error was a *consequence* of the script's own pkill,
   not a cause.
2. **"Restarting argo-shim needs an interactive Duo prompt."** False.
   `argo_shim/_shim.py:581` sets `BatchMode=yes` — its ssh *cannot* prompt; it
   fails with exit 255. Duo is answered by a separate, longer-lived outer
   ControlMaster (`~/.ssh/sockets/catlett@logins.cels.anl.gov-22`).

   The real hazard is `MAX_SSH_FAILURES = 3` (`_shim.py:31`), which exists
   because **CSPO blocks the source IP** after repeated failed SSH auth against
   ALCF hosts. That is why an unattended killer was dangerous.

## 3. The design now

| Script | Role re: argo-shim |
|---|---|
| `~/start-all.sh` → symlink to `code/DGX-Spark/ops/start-all.sh` | **Sole owner.** Layer 1 starts/restarts it. |
| `code/spark-ai/start-all.sh` | **Verify-only.** Re-probe 20s → `exit 3`. |
| `code/Spark-Hermes/ops/start-all.sh` | **Verify-only.** Re-probe 20s → `exit 3`. |

Three scripts were kept deliberately (not merged): the layering is sound and
each child must stay independently runnable. Only *ownership* changed.

Other changes:
- **Re-confirm before destroy** (reuses the existing `wait_for` helper) on every
  remaining destructive site: vLLM restart, socat pkill, gateway recreate
  (health path only — the vLLM-cascade recreate is intentional and unguarded),
  LiteLLM restart, and the master's own argo pkill.
- **Probes harmonized**: `claudehaiku45` / `--max-time 10` everywhere. spark-ai
  had paired the slowest model (sonnet, 1.56s measured) with the tightest
  timeout (8s) — the most false-positive-prone probe in the stack.
- **`ARGO_PORT` env-overridable** in all three, so the argo-down path can be
  tested against a dead port without touching the real shim.
- **Cron** (`run-stack-health.sh`): `rc=3` → "needs a human" header, posted once
  then suppressed 24h via `$LOGS_DIR/.argo-down-notified`, cleared on next clean
  run. Genuine faults (rc=1) unaffected.
- Deleted: both children's blind `sleep 20`, Hermes's write-only
  `ARGO_RESTARTED`.

## 4. Commits (all local, all on `main`, none pushed)

```
spark-ai        79bada5  Stop killing argo-shim; re-confirm health before any restart
                5704e3d  Recreate gateway instead of restarting it when health fails
Spark-Hermes    3ea7e93  Stop killing argo-shim; re-confirm LiteLLM health before restarting
DGX-Spark       babdbe5  Re-confirm argo-shim health before restarting it
                31f3a66  Port live master start-all.sh into the repo
spark-ai-agents 44fbe8c  changelog: stack-health argo-down handling
```

`git -C <repo> status -sb` should show `ahead 2 / 1 / 2 / 1` respectively.

## 5. Tomorrow's test (the only untested path)

Reboot, then run `~/start-all.sh` from an interactive terminal.

**Expected:**
- Layer 1 starts argo-shim, polls from t=0, 110s budget (no blind 20s sleep).
- Layers 2 and 4 print `argo-shim (127.0.0.1:44497) — verify only` then
  `argo-shim healthy` and move on. Neither tries to start it.
- Exit 0, "All services healthy".

**If it fails, capture:** the exit code, which layer printed the failure, and
`tail -30 ~/code/spark-ai/argo-shim.log`.

**Exit code meanings:** `0` ok · `1` real stack fault · `3` argo-shim down and
the script doesn't own it (children only — run `~/start-all.sh`).

## 6. Verification already done (safe against the live stack)

- `bash -n` clean on all four scripts. shellcheck not installed.
- `grep -n 'pkill.*argo-shim'` → **no hits in either child**; master retains it.
- Dead-port test `ARGO_PORT=44599 ./start-all.sh` on both children → `exit 3`,
  correct message, **real shim untouched**.
- Healthy path both children → no-op, exit 0.
- `ARGO_PORT=44599 ~/start-all.sh --check` → kills nothing.
- Real `run-stack-health.sh` run → `CLEAN — no Slack post`.
- Cron dedup state machine tested standalone: post → suppress → suppress →
  clear on rc=0 → post again.
- **argo-shim PID 3476126 (started 14:54:54) survived every test unchanged.**

## 7. Open items for the next session

1. **Push** the four repos — only after the reboot test passes.
2. **`run-stack-health.sh` is UNTRACKED.** `/shared/` is gitignored and this
   script, unlike all 8 of its cron peers, was never force-added. The edit is
   live on disk but unversioned. Recommend `git add -f`. Only the CHANGELOG
   entry got committed.
3. **`~/start-all-stable-homes.sh` still exists.** My `rm` was blocked by the
   permission classifier — correctly, since Charlie never named that file. It
   was a symlink pinning the pre-`--host` master; now that the repo copy is
   updated it's a redundant alias. Needs his decision.
4. **Pre-existing, unexplained:** the 34 rc=1 runs are fully explained, but
   confirm the 3:30am series actually goes clean now — that's the regression
   signal.
5. Backup of the pre-symlink master: `~/start-all.sh.pre-symlink-20260813`.

## 8. Working agreement

Charlie validates infra/startup changes on a real reboot **before** pushing.
Commit locally, report what's unpushed, don't offer push as the obvious next
step. Fixes found during validation go on top as new commits, not amends.

Careful with `~/start-all.sh`: it is now a **symlink**. Edit through it or via
`code/DGX-Spark/ops/start-all.sh`; don't `cp` over the path or the link breaks.
