# FINDINGS 2026-08-16 — Why the broken memory subsystem went undetected

Companion to `PLAN-2026-08-15-native-memory-for-sandboxed-agents.md`. This
document answers two questions asked after reviewing `~/code/OpenClaw-Tutorial`:

1. At what point should I have known to provide an OpenAI key?
2. At what point did I overlook a warning or error?

It also records a **correction** to the mechanism described in the 2026-08-15
plan. See §5.

---

## 1. Short answer

**You should never have needed an OpenAI key** — and there was no warning you
overlooked, because the system never emitted one on any path you were on.

---

## 2. "At what point should I have known to provide an OpenAI key?"

No point. That framing concedes too much:

- **Keyword search needs no key at all.** `memory status` reports `FTS: ready`
  right now. BM25 full-text search over your memory files has been available
  this entire time.
- **You already own embeddings.** Argo serves `v3small` (1536 dims), `v3large`
  (3072), and `ada002`. You didn't need to buy anything; the connection was
  just never wired.
- **The default silently pointed at OpenAI.** `memorySearch.provider` defaults
  to `openai`, and `openclaw/docker-compose.yml` sets `OPENAI_API_KEY=dummy`.
  So the config *looked* populated. The nearest thing to a "should have known"
  moment was writing that `dummy` — but that was for the vLLM/NIM path, and
  nothing in the system connected it to memory.

---

## 3. "At what point did I overlook a warning or error?"

You didn't miss one. All four channels that could have told you were silent:

| Channel | What it said |
| --- | --- |
| `openclaw doctor` | Flags plaintext secrets and LAN binding. **Says nothing about memory.** |
| Gateway tool-policy log | Logs every stripped tool. `memory_search` appears **zero times**. |
| Agent behavior | Said "I don't know" — indistinguishable from not having been told. |
| `openclaw memory status` | Would have shown `Indexed: 0/27` — but nothing prompted you to run it. |

> **Amended by §5A.** This table is right that nothing *reached* you unprompted,
> but two entries are too soft. The docs **did** state the key requirement, and
> `memory status --deep` **does** emit an excellent 401 error. See §5A.

### 3.1 The trap in row three

Your Enhancement 6 diagnosis — *"agents don't use tools they aren't told to
use"* — is **correct and well-researched**. It is a real OpenClaw behavior, you
documented it more precisely than the official docs do, and you fixed it
properly with the two `SOUL.md` rules.

But it produces the *same symptom* as a missing tool: the agent says "I don't
know."

You had a true explanation that fully accounted for the observed evidence, so
the investigation stopped there. That is not negligence — it is a correct
hypothesis masking a second, independent fault. Both were real. Fixing the
first could never have revealed the second, because the fix's success criterion
(the agent *tries* to search) and the hidden fault's symptom (the search
subsystem is empty and toolless) are invisible to each other from the outside.

---

## 4. The one thing that would have caught it

Line 1149 of `OpenClaw-Tutorial.md` contains the tell:

> "an agent... that **has memory search fully operational** — and that will say
> 'I don't know'"

That clause is an assumption stated as fact.

Enhancement 6 has a four-step behavioral lock-in procedure
(edit → reset → tell → **verify**), which is good practice and is applied
consistently elsewhere in the tutorial. But step 4 verifies the *agent's
behavior*, never the *subsystem the behavior depends on*.

Across 165 KB, the tutorial never once instructs the reader to run
`openclaw memory status`. The only occurrence of the phrase "memory index" is
prose at line 1598 asserting that content *is* in the index. One command, at
the top of §E6.4, would have printed `Indexed: 0/27` and ended this in March.

### 4.1 The gap is structural, not personal

You verified the layer you were changing (instructions) and inherited the layer
beneath it (indexing, tool registration) as working. That is the normal and
usually correct thing to do — you cannot re-verify the whole stack on every
edit. It fails specifically when a lower layer has *never* been exercised, so
its failure has no history to distinguish it from silence.

**Suggested tutorial change:** add a substrate-verification step to §E6.4 before
the instruction work:

```bash
openclaw memory status --agent <id>     # expect Indexed: N/N, not 0/N
```

Generalized, this is a fifth step for the lock-in procedure: **verify the
substrate before instructing the agent to use it.** The existing four steps
assume the capability exists and only lock in whether the agent *elects* to use
it.

---

## 5. Correction to the 2026-08-15 plan

Investigating the gateway logs for this write-up disproved §1.2 of the plan.

**What I said:** sandbox tool policy was *blocking* `memory_search` /
`memory_get`, because the default sandbox allowlist doesn't name them and a
non-empty `allow` list blocks everything unlisted.

**What is actually true:** the tools were **never registered**, so the sandbox
never got the chance to block them.

**Evidence.** The gateway logs every tool it strips, with the rule that stripped
it. Comparing occurrences in those `removedTools` lists:

- `web_search` — appears **9 times** (registered, then removed by sandbox policy)
- `memory_search` — appears **0 times**, in any removal list, ever

A tool that was registered-then-blocked gets logged. A tool that was never
created cannot be.

**Cause.** `dist/extensions/memory-core/index.js:265` wraps both tools in
`createLazyMemoryTool`, which opens with:

```js
if (!hasMemoryToolContext(params.options)) return null
```

That gate calls `resolveMemorySearchConfig`, which returns `null` when memory
search resolves to disabled (`dist/memory-search-CBXJuehI.js:325`). Registration
returns `null` and the tools simply never exist.

### 5.1 What this changes operationally

- **Do §3.2 (provider config + index build) BEFORE §3.1 (`alsoAllow`).** The
  tools must first come into existence via working memory-search config; only
  then does sandbox tool policy become relevant at all.
- **Do not apply §3.1 blind.** Re-run `openclaw sandbox explain --agent luoji`
  after §3.2 to see whether the allowlist is actually load-bearing. It may turn
  out that `alsoAllow: ["group:memory"]` is unnecessary.
- Still true: never use `allow` in place of `alsoAllow` — `allow` *replaces* the
  default sandbox tool set and would strip `exec`/`read`/`write`.

### 5.2 What is unaffected

Re-confirmed and unchanged:

- §1.1 — your `MEMORY.md` + `memory/YYYY-MM-DD.md` layout is already the native
  one; **no data migration**
- §1.3 — index is empty (0/27 luoji, 0/41 cecat)
- §1.4 — the Argo embeddings gap: `user` must be in the JSON body, cannot be a
  header, OpenClaw never sends it, argo-shim injects it only on
  `/chat/completions`
- §4 — rollback table
- §5 — security review of the sandbox change

---

## 5A. Addendum 2026-08-16 — the docs *did* say it, and the error *does* exist

Two follow-up questions, both of which land.

### 5A.1 "Did the documentation not say to provide a key?"

**Yes, it did.** `docs/concepts/memory-builtin.md` §"Getting started" — shipped
inside the image you are running — says plainly:

> By default, the builtin engine uses OpenAI embeddings. If you already have
> `OPENAI_API_KEY` or `models.providers.openai.apiKey` configured, vector search
> works with no extra memory config.

and then documents ten alternate providers, with troubleshooting at line 120:
*"Memory search disabled? Check `openclaw memory status`. If no provider is
detected, set one explicitly or add an API key."*

So §2's "you should never have needed an OpenAI key" is correct on the
*substance* — Argo embeddings and FTS were both available to you, and buying an
OpenAI key was never the only option — but it was **too generous about the
documentation**. The requirement to configure *something* was documented, and
the exact diagnostic command was named in the troubleshooting section. That is
a genuine miss, not an undocumented trap. The mitigating factor is real but
smaller than §2 implied: the docs are organized so that this only reaches you
if you were already reading the memory backend page, and nothing in the setup
path routes you there.

### 5A.2 "Shouldn't a failed embeddings call throw an error or warning?"

**It does — and it is excellent.** It is just hidden behind a flag you had no
reason to pass:

```
$ openclaw memory status --deep --agent luoji
Embeddings: unavailable
Embeddings error: openai embeddings failed: 401 {"error":{"message":
  "Incorrect API key provided: dummy...","code":"invalid_api_key"}}
```

That is a perfect diagnostic — exact provider, exact HTTP status, the offending
value (`dummy`), and the fix. It names the problem better than I did on the
first pass.

**But `--deep` is required to see it.** Plain `memory status` reports only
`Provider: openai (requested: openai)`, which reads like success. So your
instinct is right, and the failure is worse than "no warning existed":

| Surface | Reports the 401? |
| --- | --- |
| `openclaw doctor` | **No** — 0 mentions of memory or embeddings |
| Gateway runtime logs | **No** — no embedding error events |
| `openclaw memory status` | **No** — shows `Provider: openai`, looks healthy |
| `openclaw memory status --deep` | **Yes** — full 401 with the fix |

I verified the log line myself: the only `Embeddings error` text in the log
buffer is the echo of my own `--deep` invocation, carrying no timestamp and no
subsystem tag. There is no runtime-emitted embedding failure event.

The design flaw is that the 401 is only produced **on demand**, when a human
explicitly asks for a deep check. Indexing 27 files against a bad key should
have failed loudly and repeatedly at write time. Instead the failure is latent:
it materializes only when interrogated, which is precisely when you already
suspect a problem. A diagnostic that only speaks once you suspect the fault
cannot be what causes you to suspect the fault.

Worth reporting upstream: **`doctor` should surface `Embeddings: unavailable`.**
It already warns about plaintext secrets and LAN binding, so it has the right
shape for this; a broken memory backend is at least as operationally
significant.

### 5A.3 Revised failure count

Your framing — "it would seem to me that there were two failures" — is right,
and the split is cleaner than §6 originally had it:

1. **No tool was ever registered** (§5) — so even a perfect index was
   unreachable.
2. **No indexing was happening anyway** — the 401 against `dummy` meant 0/27
   files were ever chunked or embedded.

These are independent. Fixing either alone leaves memory non-functional, which
is why the plan's Phase 1 must do both (register the tools *and* build the
index) before any behavioral test can pass.

---

## 6. Summary

Two independent faults produced one symptom:

1. **Agents weren't instructed to search memory.** You found this, diagnosed it
   correctly, and fixed it in Enhancement 6.
2. **The memory subsystem was never operational** — no registered tools, empty
   index, no reachable embedding provider. This was invisible because the
   symptom was already fully explained by fault 1, and no diagnostic surfaced it
   unprompted.

The missing safeguard was not knowledge or attention. It was a verification step
for the substrate, at the one moment you were writing documentation that assumed
the substrate worked.
