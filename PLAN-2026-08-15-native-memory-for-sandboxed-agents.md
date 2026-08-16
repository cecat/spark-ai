# PLAN 2026-08-15 — Enable native memory tools for sandboxed agents

**Status:** awaiting approval. Nothing in this plan has been applied. All
findings below were verified live against the running stack on 2026-08-15.

> ### CORRECTION 2026-08-16 — read before acting on §3.1
>
> **§0 item 1 and §1.2 below are wrong about the mechanism.** I originally
> concluded the sandbox tool allowlist was blocking `memory_search`/`memory_get`.
> Re-checking against the gateway's own tool-policy audit log shows they were
> **never registered as tools at all** — so the sandbox never got the chance to
> block them.
>
> Evidence: the gateway logs every tool it strips. `web_search` appears in those
> `removedTools` lists 9 times (registered, then removed by sandbox policy).
> `memory_search` appears **zero** times — in any removal list, ever. A tool that
> was registered-then-blocked would be logged; a tool that was never created
> cannot be.
>
> Cause: `memory-core/index.js:265` wraps both tools in `createLazyMemoryTool`,
> which opens with `if (!hasMemoryToolContext(params.options)) return null`. That
> gate calls `resolveMemorySearchConfig`, which returns `null` when memory search
> resolves to disabled (`memory-search-CBXJuehI.js:325`). Registration returns
> `null`, and the tools simply never exist.
>
> **What this changes:** §3.1 (`alsoAllow: ["group:memory"]`) is probably
> *insufficient on its own*, not merely additive — the tools must first come into
> existence via working memory-search config (§3.2), and only then does sandbox
> policy become relevant. **Do §3.2 before §3.1**, and re-run `sandbox explain`
> between the two to see whether the allowlist is even load-bearing here. It may
> turn out that §3.1 is unnecessary; do not apply it blind.
>
> §1.1 (native layout, no migration), §1.3 (empty index), §1.4 (the Argo `user`
> gap), §4, and §5 are unaffected and were re-confirmed.

> ### OUTCOME 2026-08-16 — applied; BOTH steps were required
>
> Phase 1 is done and verified live. The important result: **§3.1 and §3.2 were
> each necessary and neither was sufficient.** The correction box above
> speculated §3.1 might turn out unnecessary — it did not.
>
> Executed in this order, re-checking between steps:
>
> 1. **§3.2 first.** Added a `memory:` block to `config.yaml`
>    (`provider: none`) and taught `apply-config.sh` to write
>    `agents.defaults.memorySearch`. Result: the 401 disappeared and
>    `memory index --force` produced `Indexed: 27/27` (luoji) and `41/41`
>    (cecat). **But the tools were still absent from the agent's tool list**,
>    and `memory_search` still appeared zero times in any `removedTools` entry.
> 2. **§3.1 second.** Added `sandbox.tools.also_allow: ["group:memory"]` per
>    agent in `config.yaml`, written to
>    `agents.list[].tools.sandbox.tools.alsoAllow`. Only then did
>    `sandbox explain` change from `allow (default): …` to
>    `allow (agent): …, memory_search, memory_get`, and only then did the
>    agents actually report the tools.
>
> So the mechanism is a *composite* of both faults, and the audit-log evidence
> (`memory_search` never in `removedTools`) is a genuine blind spot rather than
> proof that policy was innocent: the sandbox `allow` list blocks by omission,
> and a tool blocked by omission is never logged as removed. Do not use "absent
> from the removal log" as evidence that sandbox policy is not involved.
>
> End-to-end confirmed: luoji called `memory_search` for "heartbeat" and got 6
> results, top hit `memory/2026-04-07.md`.
>
> **One correction to §3.2's verification advice.** The obvious JSON health
> check is wrong in FTS-only mode — `embeddingProbe.error` is *populated on a
> healthy system* ("No embedding provider available (FTS-only mode)"), so
> asserting the error is empty reports a false failure. Use:
>
> ```bash
> memory status --json --deep --agent <id> \
>   | jq -e '.[0] | .status.files > 0 and (.status.provider == "none" or .embeddingProbe.ok == true)'
> ```
>
> Phase 2 (Argo embeddings, §3.3–3.4) is untouched and still needs Charlie at
> the console.

---

## 0. The short version

You assumed sandboxed agents lost memory because sandboxing stripped the memory
subsystem, and you wrote a file-convention workaround to compensate. The
workaround turned out to be **the same layout OpenClaw natively uses**, so no
data migration is needed. Three things are actually broken, and only the first
is about sandboxing:

1. **`memory_search` / `memory_get` are blocked by the sandbox tool allowlist.**
   The default sandbox allowlist simply does not name them, and a non-empty
   `allow` list blocks everything unlisted. One additive config key fixes this.
2. **The memory index is empty** — 0 of 27 files (luoji), 0 of 41 (cecat). Even
   unblocked, the tools would return nothing until an index is built.
3. **No working embedding provider.** Config requests `openai`, but the only
   key present is `OPENAI_API_KEY=dummy`. Argo *does* offer embedding models,
   but reaching them needs a small argo-shim change (§3.3) — and argo-shim is
   the one component this repo is not allowed to casually restart.

Your agents' `SOUL.md` files **already** instruct them to call `memory_search`
before saying "I don't know." That instruction has been dead the whole time —
the tool was never in their tool list.

---

## 1. What I verified (evidence)

### 1.1 The memory layout you invented is already the native one

`docs/concepts/memory.md` (shipped inside the 2026.6.11 image) specifies:

- `MEMORY.md` — long-term, loaded at the start of every DM session
- `memory/YYYY-MM-DD.md` — daily notes, indexed for `memory_search`/`memory_get`

Both agents already match this exactly:

```
luoji/MEMORY.md        + luoji/memory/2026-02-25.md … 2026-08-14.md   (26 dated files)
cecat/MEMORY.md        + cecat/memory/2026-03-17.md … 2026-05-20.md   (~38 dated files)
```

**Consequence: there is no memory migration.** No file renames, no content
rewrite. This is the single most important finding — it removes the riskiest
part of what you might have expected this plan to contain.

Slug variants (`YYYY-MM-DD-<slug>.md`) are also picked up, so if you ever wrote
`2026-08-14-standup.md` it indexes fine.

### 1.2 Root cause of the missing tools

```
$ docker exec openclaw-gateway node dist/index.js sandbox explain --agent luoji

  runtime: sandboxed
  mode: all   scope: agent
Sandbox tool policy:
  allow (default): exec, process, read, write, edit, apply_patch, image,
                   sessions_list, sessions_history, sessions_send,
                   sessions_spawn, sessions_yield, subagents, session_status
  deny  (default): browser, canvas, nodes, cron, gateway, …
```

`memory_search` and `memory_get` appear in **neither** list. Per
`docs/gateway/sandbox-vs-tool-policy-vs-elevated.md`:

> - `deny` always wins.
> - **If `allow` is non-empty, everything else is treated as blocked.**
> - `group:memory`: `memory_search`, `memory_get`

So the tools are blocked by omission, not by an explicit deny. This is a
sandbox **tool-policy** issue, not a sandbox **filesystem** issue — which is why
the agents can still read and write their memory files by hand.

The `memory-core` plugin is already **enabled** (`plugins list` → `enabled`,
`stock:memory-core/index.js`), so nothing needs installing.

### 1.3 The index is empty

```
$ docker exec openclaw-gateway node dist/index.js memory status --agent luoji
Indexed: 0/27 files · 0 chunks        Dirty: yes
Index identity: index metadata is missing
Vector search: paused until memory is rebuilt
Provider: openai (requested: openai)
FTS: ready
```

`cecat` is the same shape at `0/41`. Note **`FTS: ready`** — the SQLite
full-text (BM25) side is functional right now. Only the vector half is stalled.

The stale `~/.openclaw/memory/{luoji,main}.sqlite` files (dated Jul 10) are from
an older layout; the current per-agent store is
`~/.openclaw/agents/<id>/agent/openclaw-agent.sqlite`.

### 1.4 Embeddings: the real obstacle

There is no OpenAI key. `docker-compose.yml` sets `OPENAI_API_KEY=dummy`, and
`secrets.yaml` has anthropic / argo / brave / sage keys only.

Argo *does* expose embedding models:

| Argo display id          | internal_id | dims |
| ------------------------ | ----------- | ---- |
| Text Embedding 3 Small   | `v3small`   | 1536 |
| Text Embedding 3 Large   | `v3large`   | 3072 |
| Text Embedding Ada 002   | `ada002`    | 1536 |

I confirmed a real embedding round-trip through the shim, including from inside
the gateway container over the socat bridge:

```
$ docker exec openclaw-gateway curl -s -X POST http://172.18.0.1:44497/v1/embeddings \
    -H 'Content-Type: application/json' \
    -d '{"model":"v3small","input":"probe","user":"catlett"}'
{"object":"list","data":[{"object":"embedding","index":0,"embedding":[-0.0065…
```

**But that only works because I hand-supplied `"user":"catlett"` in the body.**

- Argo rejects the request without it: `ACCESS DENIED … username
  'openai-api-user' could not be validated`.
- The username **cannot** be passed as a header. I tested `Authorization:
  Bearer catlett`, `x-user`, `user`, and `X-Argo-User` — all rejected. Argo
  reads it from the JSON body only.
- OpenClaw never sends a `user` field. I checked the shipped embedding client
  (`dist/embeddings-http-Do-t00Iw.js`); it sends `input`, `model`,
  `dimensions`, `encoding_format` — and no `user`.
- argo-shim injects `user` **only on `/chat/completions`**
  (`argo_shim/_shim.py:576`), with an explicit comment that it deliberately
  does not touch other paths. `/v1/embeddings` falls through unmodified.

So the chain breaks at exactly one link: **nobody adds `user` to embedding
requests.** That is what §3.3 fixes.

Good news for compatibility — Argo tolerates the extra fields OpenClaw sends
(`dimensions: 1536` honored; batch `input: ["a","b"]` returns 2 vectors). It
ignores `encoding_format: base64` and returns floats, which OpenClaw handles.

### 1.5 Memory tools run on the host, not in the sandbox

Every memory-core bundle in `dist/` is `memory-core-host-*`. The tools execute
in the gateway process and return results to the sandboxed turn. This matters
for §5: allowing `group:memory` does **not** grant the sandbox new filesystem
reach, new network egress, or a way out of the jail. It exposes two read-only
tools scoped to that agent's own workspace memory.

---

## 2. Design decisions (and what I rejected)

**Use `alsoAllow`, not `allow`.** `alsoAllow` is additive; `allow` *replaces*
the default set. Writing `allow: ["group:memory"]` would silently strip `exec`,
`read`, `write` and brick both agents. This is the single most dangerous way to
get this change wrong, so it is called out here and again in §3.1.

**Per-agent, not global.** Applied under each agent entry, so a mistake affects
one agent and the hibernated `chattpc26` inherits nothing unexpectedly.

**Phase the embedding work behind the tool unblock.** Step §3.1 + §3.2 alone
give working BM25 keyword search (`FTS: ready` today) with zero argo-shim risk.
Embeddings are a separate, revertible phase. If you want to stop after Phase 1,
you get a real, indexed, searchable memory — just lexical rather than semantic.

**Rejected — disabling the sandbox** (`sandbox.mode=off`). Would work, and is
the fix-it key the docs list first, but it trades a two-line policy change for
the entire sandbox boundary. Not warranted.

**Rejected — local GGUF embeddings** (`@openclaw/llama-cpp-provider`). No
network dependency and no Argo involvement, which is genuinely attractive. But
it adds a plugin, a ~0.6 GB model download, and VRAM pressure on a box already
running vLLM. Worth reconsidering if §3.3 is rejected; noted as the fallback.

**Rejected — vLLM for embeddings.** The served model
(`Qwen/Qwen3-Coder-Next-FP8`) is a coder model; `/v1/models` lists no embedding
model. vLLM would need a second model loaded.

**Rejected — dreaming / active-memory / memory-wiki.** All available, all
disabled by default. Out of scope; revisit once basic recall is proven.

---

## 3. The plan

### Phase 1 — Unblock the tools and build the index (low risk, no argo-shim)

#### Step 3.1 — Grant `group:memory` inside the sandbox

Add to **each** of the two agent entries in `openclaw.json`
(`agents.list[]` where `id` is `luoji`, then `cecat`):

```json
"tools": {
  "deny": [],
  "sandbox": {
    "tools": {
      "alsoAllow": ["group:memory"]
    }
  }
}
```

Both agents already have a `tools: {"deny": []}` block, so this extends it.

> **Do not use `allow` here.** `allow` replaces the default sandbox tool set and
> would remove `exec`/`read`/`write` from the agent. `alsoAllow` is additive.

**Where to make the edit — decision needed, see §7.** `apply-config.sh` is the
declarative front-end, but it has no knob for sandbox tool policy today
(it handles only per-agent `tools.deny` and `sandbox.browser.enabled`,
`apply-config.sh:461-475`). It read-modify-writes the live `openclaw.json` and
preserves unknown keys, so a hand-edit survives the next run. Two options:

- **1a (recommended): teach `apply-config.sh` the key.** Add a `memory: true`
  (or `tools.sandbox.also_allow`) field per agent in `config.yaml` and ~6 lines
  in the agent loop. Keeps config.yaml authoritative, which is this repo's
  stated model.
- **1b: hand-edit `openclaw.json` in the volume.** Faster, survives
  `apply-config.sh`, but the setting then exists only in a Docker volume with
  no record in git — exactly the drift this repo's design avoids.

Verify before restarting anything:

```bash
docker exec openclaw-gateway node dist/index.js sandbox explain --agent luoji
# expect memory_search + memory_get to appear in the effective allow list
```

#### Step 3.2 — Build the index (FTS-only for now)

Set the provider to `none` for deliberate lexical-only recall. This matters:
per `docs/reference/memory-config.md`, an explicitly-configured remote provider
**fails closed** — leaving it as `openai` with a dummy key makes `memory_search`
return "unavailable" rather than falling back to keyword search.

```json5
{ agents: { defaults: { memorySearch: { provider: "none" } } } }
```

Then index both agents:

```bash
docker exec openclaw-gateway node dist/index.js memory index --force --agent luoji
docker exec openclaw-gateway node dist/index.js memory index --force --agent cecat
docker exec openclaw-gateway node dist/index.js memory status --agent luoji
# expect: Indexed: 27/27 files · N chunks   Dirty: no
```

**Exit criteria for Phase 1:** `sandbox explain` lists both memory tools;
`memory status` shows 27/27 and 41/41; and a live Slack message to luoji asking
about something recorded only in an old daily note comes back correct.

At this point the `SOUL.md` "search before you say you don't know" instruction
becomes true for the first time.

---

### Phase 2 — Semantic search via Argo embeddings (touches argo-shim)

Only start this after Phase 1 is confirmed good.

#### Step 3.3 — Teach argo-shim to inject `user` on `/v1/embeddings`

In `argo_shim/_shim.py`, the `user`-injection block is gated on
`"/chat/completions" in self.path` (line ~576). The change is to extend that
condition to also match `/embeddings`. Mechanically it is a one-line predicate
change plus a log-string tweak; the existing body already handles
"parse JSON → inject user if absent → re-serialize" and is defensive about
non-dict bodies.

Model-name normalization in the same block is a bonus: it maps
`text-embedding-3-small` → `v3small`, so OpenClaw can use the canonical name.
I verified both forms resolve correctly through the shim.

**Constraints that make this the sensitive step** (from `MEMORY.md` and
`HANDOFF-2026-08-13`):

- argo-shim is owned **solely** by the master `~/start-all.sh`. Nothing in this
  repo may start, restart, or kill it.
- Applying a code change requires a shim restart, and its SSH uses
  `BatchMode=yes`. `MAX_SSH_FAILURES=3` exists because CSPO blocks the source
  IP after repeated failed SSH auth against ALCF hosts.
- argo-shim 0.3.20 is a **pip-installed package**
  (`~/.local/lib/python3.12/site-packages/argo_shim/_shim.py`), not a checkout
  in one of your repos. A local edit is overwritten by the next
  `pip install --upgrade`. This needs a decision — see §7.

So this step is **yours to schedule**, deliberately, when you are at the console
and able to re-auth Duo if the tunnel drops. I will not touch argo-shim
unattended.

Test the shim change *before* pointing OpenClaw at it:

```bash
# after restarting the shim, with NO user field in the body:
curl -s -X POST http://127.0.0.1:44497/v1/embeddings \
  -H 'Content-Type: application/json' \
  -d '{"model":"text-embedding-3-small","input":"probe"}' | jq '.data[0].embedding|length'
# expect: 1536   (not an ACCESS DENIED error)
```

#### Step 3.4 — Point memory search at Argo

Add an embedding-capable provider and select it:

```json5
{
  models: { providers: { "argo-embed": {
    api: "openai-completions",
    baseUrl: "http://172.18.0.1:44497/v1",
    apiKey: "catlett",
    models: [{ id: "v3small" }],
  }}},
  agents: { defaults: { memorySearch: {
    provider: "argo-embed",
    model: "v3small",
    fallback: "none",
  }}},
}
```

`config.yaml` already has a `providers:` block that `apply-config.sh` writes
into `models.providers.*`, so this fits the existing mechanism — though the
`memorySearch` selection itself is a new key that needs the same §7 decision.

Then rebuild — **required**, because changing provider changes index identity
and OpenClaw deliberately pauses vector search rather than silently re-embedding:

```bash
docker exec openclaw-gateway node dist/index.js memory index --force --agent luoji
docker exec openclaw-gateway node dist/index.js memory index --force --agent cecat
docker exec openclaw-gateway node dist/index.js memory status --deep --agent luoji
# expect: Vector store: ready (or sqlite-vec fallback noted), no identity warning
```

Cost is zero (Argo is internal). Volume is a one-off ~68 files of small
Markdown, then incremental on a 1.5s debounced file watcher.

---

### Phase 3 — Reconcile the agent instructions

Once the tools work, the workaround prose should shrink, not grow.

- `luoji/TOOLS.md:9` already documents `memory_search` accurately — it becomes
  true rather than aspirational. No edit needed.
- `luoji/SOUL.md:64`, `cecat/SOUL.md:46` — "Search before saying you don't
  know." Keep as-is; now actually executable.
- `luoji/AGENTS.md:24-41` — the manual `memory/` + write-tool-false-failure
  workaround. Keep the file-writing convention (that is how memories are
  *created*), but consider trimming the fallback-path warning once verified.
- `cecat/memory/` holds nine non-`YYYY-MM-DD` files (`email-filters.json`,
  `triage-2026-07-13.md`, `pending-filters.json`, …). Only Markdown in the
  memory roots is indexed, so the `.json` operational state is ignored —
  harmless. `triage-2026-07-13.md` will *not* be indexed (no date prefix);
  rename to `2026-07-13-triage.md` if you want it searchable.

---

## 4. Rollback

| Phase | Undo |
| ----- | ---- |
| 3.1 | Remove the `sandbox.tools.alsoAllow` block; restart gateway. Tools vanish; agents fall back to reading files by hand, i.e. today's behavior. |
| 3.2 | Index is derived state in the per-agent SQLite. Delete/rebuild freely; **no memory content is at risk** — the `.md` files are the source of truth and are never rewritten by indexing. |
| 3.3 | `pip install --force-reinstall argo-shim==0.3.20` restores stock, then a master-owned restart. |
| 3.4 | Set `memorySearch.provider` back to `none`, re-index → back to Phase 1 state. |

The genuinely irreversible-feeling step is 3.3, and only because of the SSH
lockout hazard around restarting the shim — not because the code change is hard
to undo.

---

## 5. Security review of the sandbox change

Granting `group:memory` adds exactly `memory_search` and `memory_get`:

- Both run **host-side** in the gateway (`memory-core-host-*`), scoped to the
  requesting agent's own workspace memory. No cross-agent reach — luoji cannot
  search cecat's notes.
- Read-only. Neither tool writes files, executes commands, or opens sockets.
- No new bind mounts, no `dangerouslyAllowExternalBindSources` change, no
  network change, no `docker.sock` exposure.
- The sandbox already has `exec` + `read` over the same workspace, so the agent
  could already `grep` these files. This makes an existing capability efficient
  and indexed; it does not widen the blast radius.

Phase 2 sends memory-file **content** to Argo for embedding. Argo is the
internal ANL gateway you already route all agent traffic through, so this
crosses no new trust boundary — but it is worth stating plainly, since it means
daily-note text (not just chat) now leaves the box. If any memory file holds
material you would not send to Argo, resolve that before §3.4.

---

## 6. What I did NOT do

Per your instruction to develop the plan autonomously and wait: **no config was
changed, no file was edited, no service restarted, nothing indexed, nothing
committed.** Every command I ran was read-only inspection, plus embedding probes
against Argo that returned vectors and stored nothing.

One caveat on those probes: they consumed a handful of Argo embedding tokens
under your username. Trivial, but it did touch a remote service.

---

## 7. Decisions I need from you

1. **Config location — 1a or 1b?** (§3.1) Teach `apply-config.sh` the new keys
   (declarative, more code), or hand-edit the live `openclaw.json` (fast,
   invisible to git). I recommend **1a**, matching this repo's config model.
2. **Phase 2 at all?** FTS-only keyword search may be enough. Semantic search is
   the thing you actually asked for, but it is what forces the argo-shim change.
3. **How should the argo-shim patch be carried?** (§3.3) It is a pip package
   outside your repos, so an edit is lost on upgrade. Options: vendor a patched
   copy, maintain a `patches/` diff applied at install, or send the fix upstream
   if you own the package. This needs your call before I write any code.
4. **Scheduling 3.3.** Restarting the shim is master-owned and Duo-sensitive. I
   will not do it unattended — tell me when you want to sit with it.

---

## 8. Suggested order once approved

1. §3.1 + §3.2 together, gateway restart, verify (Phase 1 — ~15 min, low risk)
2. Live-test both agents in Slack; confirm recall of an old daily note
3. Decide on §7.2/§7.3
4. §3.3 with you at the console, then §3.4 and re-index
5. §3 Phase 3 doc trim
6. Commit — and per standing practice, hold the push until you have exercised
   it for real
