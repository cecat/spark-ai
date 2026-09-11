# Handoff: OpenClaw fallback repair + Qwen distiller promotion

**Host:** `spark-960b` (NVIDIA GB10 / DGX Spark, 121 GiB **unified** CPU+GPU memory)
**Written:** 2026-08-08
**Audience:** an agent running unattended (`--dangerously-skip-permissions`)

There are exactly **two** changes to make. Everything else in this document is
context to keep you from breaking something that is working correctly.

Read the "DO NOT TOUCH" section before making any change.

---

## Autonomy boundary

You MAY, without asking:
- Edit `~/code/spark-ai/config.yaml`, `~/code/Spark-Hermes/litellm/config.yaml`,
  `~/.config/falda/distiller-*.env`
- Run `~/code/spark-ai/apply-config.sh`
- Restart: `openclaw-gateway` container, `gandalf-litellm.service`,
  `falda-distiller-gandalf.service`, `falda-distiller-luoji.service` (all user units)
- Read the OpenClaw gateway's runtime config via `docker exec openclaw-gateway`

You MUST NOT, without stopping and reporting:
- Restart or reconfigure the `vllm-qwen3-coder-next` container (see DO NOT TOUCH)
- Stop, disable, or reconfigure `ollama.service`
- Change anything under `~/.falda/data/`
- Change `--gpu-memory-utilization` or any vLLM launch flag

Take backups (`cp X X.bak-20260808`) before editing any config. Report at the end
with: what you changed, verification output, and anything you could not confirm.

---

## Background: what is actually running

| Component | Role | Notes |
|---|---|---|
| `vllm-qwen3-coder-next` (container) | Serves `Qwen/Qwen3-Coder-Next-FP8` on :8000 | Holds ~98.5 GiB of the unified pool. **Load-bearing.** ~4 min cold start. |
| `argo-shim` (:44497) | Production path to remote Claude models | Healthy: 795× HTTP 200, 23× 400, **zero 5xx** on 2026-08-08. Slow, not broken. |
| LiteLLM (:4000) | OpenAI-shape proxy, routes to argo-shim or vLLM | `~/code/Spark-Hermes/litellm/config.yaml` |
| `openclaw-gateway` (container) | OpenClaw agents (luoji, cecat) | 172.18.0.3 |
| FALDA distillers ×2 | Hourly memory synthesis for gandalf + luoji | The **only** consumers of vLLM today |
| Ollama (:11434) | FALDA's **embedder** (`nomic-embed-text`, 768-dim) | ~37 MB idle. NOT a distiller. |

**Verified 2026-08-08:** 100% of vLLM traffic is the two FALDA distillers, matched
second-for-second between `~/.falda/distiller-*.log` and the vLLM container access log.
No OpenClaw traffic reaches vLLM at all — which is bug #1 below.

---

## Fix 1 — OpenClaw's vLLM fallback has never worked

### Symptom
When Argo times out, agents fail instead of falling back. Gateway logs show, on
every one of 12 recent attempts (11 `reason=timeout`, 1 `reason=auth`):

```
[model-fallback/decision] decision=candidate_failed requested=argo/claudeopus47
  candidate=argo/claudeopus47 reason=timeout next=none detail=fetch failed
```

`next=none` means no fallback candidate was resolvable. Broken since the feature
was added — commit `f406aa1`, 2026-03-28.

### Root cause (two compounding issues)

1. **The `vllm` provider config is missing or wrong in the gateway's runtime config.**
   `~/code/spark-ai/config.yaml:47` sets:
   ```yaml
   defaults:
     fallback_model: vllm/Qwen/Qwen3-Coder-Next-FP8
   ```
   But `vllm` is a **native** OpenClaw provider (`apply-config.sh:104`,
   `NATIVE_PROVIDERS = {"anthropic", "vllm"}`), so `apply-config.sh` deliberately
   does NOT write a `providers:` block for it. Per the comment at `apply-config.sh:33`,
   it was "already configured via the onboarding wizard — this script does not touch it."
   That wizard config lives in the Docker named volume `openclaw_openclaw-config`
   (mountpoint `/var/lib/docker/volumes/openclaw_openclaw-config/_data`, root-only on host).
   **The bug is in that volume, not in `config.yaml`.**

2. **`fallback_model` is never validated.** Validation at `apply-config.sh:305-310`
   iterates only over `agents_config`, so a bad fallback value writes through silently.

### Steps

1. Read the gateway's live config (this is the one place you need `docker exec`):
   ```
   docker exec openclaw-gateway sh -c 'cat /home/node/.openclaw/openclaw.json'
   ```
   Inspect `models.providers.vllm` and `agents.defaults.model.fallbacks`.

2. Ensure a `vllm` provider exists with a **base URL the container can reach**.
   Networking is NOT the obstacle — `openclaw-gateway` (172.18.0.3) and
   `vllm-qwen3-coder-next` (172.18.0.2) are both on the Docker network
   `qwen3-coder-next_nim_net`. Use either:
   - `http://vllm-qwen3-coder-next:8000/v1`, or
   - `http://nim:8000/v1` (alias already present as `OPENAI_API_BASE` in
     `~/code/spark-ai/openclaw/docker-compose.yml:63`)

   Do **not** use `127.0.0.1:8000` or `172.18.0.1:8000` from inside the container.
   Port 8000 is not published by Docker; host access only works via socat bridges.

3. Model id must be exactly `Qwen/Qwen3-Coder-Next-FP8` (confirm against
   `curl -s http://127.0.0.1:8000/v1/models`).

4. Re-run `~/code/spark-ai/apply-config.sh`, restart `openclaw-gateway`.

5. **Add validation** to `apply-config.sh` so `fallback_model` is checked the same
   way agent models are (provider exists / is native, `provider/model-id` shape).
   This is what let the bug rot for four months.

### Verification
Do not assume success from a clean config write. Confirm a fallback actually
resolves — either force a failure against Argo, or watch the gateway log for the
next natural timeout and confirm the decision line shows a real candidate
(`next=vllm/...`) instead of `next=none`.

---

## Fix 2 — Make Qwen the primary distiller model

### Why
The distillers request `claudeopus47`. LiteLLM's `request_timeout: 120` expires
against Argo on their large synthesis prompts (~16k prompt tokens), so nearly every
hourly cycle burns 120 seconds waiting, then falls back to Qwen and succeeds.
LiteLLM log shows **792 Argo timeouts / 4268 fallback mentions**.

Argo is not failing — it is too slow for this specific workload. Distillation is
extraction/compression, not frontier reasoning, and Qwen's output is good
(inspect `~/.falda/data/tenants/gandalf/self/blobs/core.md` — substantive and
well-structured). vLLM counters: 11,184 × `finished_reason=stop`, 1 × `length`,
**0 aborts, 0 errors**.

So: stop paying the timeout tax to end up on Qwen anyway. Make it primary.

### Steps

1. In **both** `~/.config/falda/distiller-gandalf.env` and
   `~/.config/falda/distiller-luoji.env`:
   ```
   DISTILLER_MODEL=Qwen/Qwen3-Coder-Next-FP8
   ```
   (was `claudeopus47`). Leave `LLM_BASE_URL=http://127.0.0.1:4000/v1` alone —
   still routed through LiteLLM. The comment above that line explaining the old
   choice is now stale; update it.

2. In `~/code/Spark-Hermes/litellm/config.yaml`, **invert the fallback** so Qwen
   has somewhere to go. Currently `Qwen` is a fallback target with no fallback of
   its own, which produces this real failure mode in the log:
   ```
   No fallback model group found for original model_group=Qwen/Qwen3-Coder-Next-FP8
   ```
   Add to `litellm_settings.fallbacks`:
   ```yaml
   - Qwen/Qwen3-Coder-Next-FP8: ["claudeopus47"]
   ```
   Keep the existing `claudeopus47 → Qwen` entries — they still serve the
   interactive Hermes/Gandalf paths.

3. Restart, in order:
   ```
   systemctl --user restart gandalf-litellm.service
   systemctl --user restart falda-distiller-gandalf.service
   systemctl --user restart falda-distiller-luoji.service
   ```

### Verification
Watch `~/.falda/distiller-gandalf.log` for the next `L2: scene written`. It should
appear **without** a preceding ~120 s stall, and
`~/code/Spark-Hermes/runlog/litellm.log` should stop accruing new
`APITimeoutError ... timeout value=120.0` entries from distiller traffic.
Cadence is hourly: gandalf ~:57, luoji ~:04 past the hour (UTC).

---

## DO NOT TOUCH

**Ollama.** It is FALDA's **embedder**, not a distiller. This is the single most
commonly confused thing in this stack.
- Embedder: `~/.config/falda/falda.env` → `FALDA_EMBED_MODEL=nomic-embed-text`, `FALDA_DIM=768`
- Distiller: `~/.config/falda/distiller-*.env` → `DISTILLER_MODEL` (the thing Fix 2 changes)

`~/.falda/data/EMBEDDING.json` is `{"model":"nomic-embed-text","dim":768,"locked":true}`
and `~/code/falda/src/gateway.ts:91` FATAL-exits on mismatch ("Serving would corrupt
recall"). Ollama idles at ~37 MB with no model resident; stopping it reclaims nothing
meaningful and breaks all dense recall. Hermes native memory is OFF, so FALDA is the
agent's only memory. Qwen3-Coder has no embeddings endpoint and cannot substitute.

**vLLM's memory / on-demand start.** ~98.5 GiB of the unified pool, ~9.9 GiB
`available`. This is expected on GB10 (`nvidia-smi` reports `memory.used [N/A]`;
use `--query-compute-apps` instead). Do not move vLLM to on-demand — after Fix 2 it
is FALDA's primary path on an hourly schedule, and cold start is ~4 minutes. Do not
change `--gpu-memory-utilization`.

**The cron exclusion.** `~/code/Spark-Hermes/gandalf/plugins/falda/__init__.py:238`
skips `agent_context in ("cron","flush")`, and the tap's SQL filters
`s.source IN ('telegram','slack')`. This deliberately keeps scheduled output (e.g. the
`daily-briefing` job, `7 13 * * *` UTC = 08:07 CDT) out of FALDA. Working as designed —
owner explicitly declined changing it.

**The FALDA "atom flatline" is NOT a bug.** L1 atom totals have been flat since
2026-08-04 because chat volume was genuinely low (22 turns over nine days) and
`L1_EVERY_N=10` gates extraction. A run logging `10 new turns -> 0 atoms` on a
conversation with no durable facts is correct behavior. Identical `core.md` byte sizes
across runs are correct for the same atom set. Do not "fix" this.

---

## Gotchas that will waste your time

- **`journalctl --user -u <unit>` shows only systemd lifecycle lines** for the
  distillers and LiteLLM. Their real logs are file-append:
  - `~/.falda/distiller-{gandalf,luoji}.log`
  - `~/.falda/tap_{gandalf,luoji}.log`
  - `~/code/Spark-Hermes/runlog/litellm.log`

  An empty journal here means nothing. This produced two wrong conclusions during
  diagnosis.

- **`docker logs` on `vllm-qwen3-coder-next` truncates at a rotation boundary.**
  Full reads and `--since` both silently stop at 2026-05-28. Use bounded
  `--tail N` (e.g. `--tail 20000`) to see recent entries.

- **A source IP of `172.18.0.1` in vLLM's log does NOT prove the caller is the host.**
  Two socat bridges (`127.0.0.1:8000` and `172.19.0.1:8000` → `172.18.0.2:8000`) make
  host traffic and 172.19.x container traffic look identical. Correlate by timestamp
  against caller logs instead.

- Every distiller log line is written **twice**. Dedupe with `sort -u` before counting.
