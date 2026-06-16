# OpenClaw Upgrade Impact: 2026.4.2 → 2026.6.8

**Status as of 2026-06-16:** running container is `2026.4.2` (two months stale). The image tagged `ghcr.io/openclaw/openclaw:latest` on disk is already `2026.6.8` (pulled by `check-for-updates.sh` earlier today, container not yet restarted onto it). Twenty-three stable releases sit between current and pulled.

This document is the impact analysis. It does **not** perform the upgrade. The recommended upgrade sequence is at the end.

---

## Part 1: Hard breaking changes (REQUIRED action before/at restart)

These will cause crash-loop, silent feature loss, or unauthorized refusal at startup if not handled.

### 1. Slack channel plugin externalized — must be installed `(v2026.5.12)`

**Background:** OpenClaw previously bundled the Slack channel adapter into the gateway image. From 5.12 onward, Slack (along with WhatsApp, Bedrock, Vertex, OpenShell sandbox) is shipped as a separately-installable plugin.

**Symptom for us:** Gateway starts cleanly but Slack Socket Mode never connects. Our cron-driven `send-slack.sh` keeps writing JSON to `shared/slack/outbox/` and posting via the bot token directly via `curl` (which still works because that path bypasses the gateway), but the gateway's *inbound* Slack handling (DMs to the agents, channel routing per our `channels.slack.channels` allowlist) is gone — the agents go conversationally silent.

**Fix:** After image swap, install the externalized plugin:
```bash
docker exec openclaw-gateway node dist/index.js plugins install @openclaw/slack
```
Verify with `plugins list` and a Slack DM round-trip with each agent.

**Exposure:** **HIGH.** Slack is our primary control channel. This is the single most important post-restart action.

---

### 2. Gateway config now fails closed on invalid input `(v2026.5.3)`

**Background:** Prior to 5.3, a startup with invalid `openclaw.json` would auto-restore to a last-known-good. From 5.3 onward: invalid config crash-loops the gateway, and recovery requires `openclaw doctor --fix`.

**Symptom:** Gateway repeatedly restarts with `Gateway failed to start: …` and exits.

**Fix:** Pre-flight validation BEFORE the upgrade:
```bash
docker exec openclaw-gateway node dist/index.js config validate
```
If anything is flagged, run `doctor --fix` while still on 4.2 to clean it up before restarting onto 6.8.

**Exposure:** **HIGH.** Our `openclaw.json` has accumulated edits over two months; subtle key drift is plausible.

---

### 3. Provider `apiKey` no longer infers env-var names from raw strings `(v2026.5.12)`

**Background:** Pre-5.12, any apiKey string matching `^[A-Z_][A-Z0-9_]*$` was treated as an env-var name to look up. From 5.12 onward, env-var lookup requires a structured SecretRef like `{ envVar: "FOO" }` or a `secrets.providers.<id>` entry.

**Our exposure:** We have two custom providers:

| Provider | Current apiKey value | Risk |
|----------|---------------------|------|
| `vllm`   | `"VLLM_API_KEY"` (literal string matching env-var pattern) | **Affected** — was previously interpreted as env-var lookup; now treated as the literal string `"VLLM_API_KEY"`. Whether this matters depends on whether vLLM actually authenticates (it likely does not on our `nim_net` loopback). |
| `argo`   | `"catlett"` (literal username) | **Not affected** — doesn't match env-var pattern; was always a literal value. argo-shim uses it as identity, not auth. |
| `brave`  | actual key string | **Not affected** — already a literal key. |

**Fix (if vllm proves broken):** Convert to structured SecretRef in `openclaw.json`:
```json
"vllm": { "apiKey": { "envVar": "VLLM_API_KEY" } }
```
Or remove the apiKey entirely if vLLM accepts unauthenticated requests on our internal network.

**Exposure:** **MEDIUM.** Test vLLM as a fallback model after upgrade; if a probe to it succeeds, no action needed.

---

### 4. Sandbox/browser registry migrates to per-runtime shard files `(v2026.5.3)`

**Background:** Pre-5.3, OpenClaw stored sandbox container metadata in a monolithic `containers.json`. From 5.3 onward, per-runtime shard files reduce lock contention. Migration runs via `openclaw doctor --fix`.

**Symptom if migration is skipped:** Sandbox container reuse becomes inconsistent (matches the 2026.2.26 upgrade's experience documented in `UPGRADE-2026.2.26.md` § 6: stale `containers.json` caused "Tool exec not found"). With our `sandbox.mode: all` and currently-running 3-day-old sandbox containers (`openclaw-sbx-agent-luoji-b88d9626`, `openclaw-sbx-agent-cecat-f7952fcc`), we are exactly in the bucket where this matters.

**Fix:** Before starting 6.8, stop the gateway and remove the current sandbox containers, then run `doctor --fix` on first start so the migration produces clean shards:
```bash
# while gateway down
docker rm -f $(docker ps -aq --filter name=openclaw-sbx-agent)
# start gateway on 6.8
docker compose up -d
# then immediately
docker exec openclaw-gateway node dist/index.js doctor --fix
```

**Exposure:** **HIGH** because we run `sandbox.mode: all` with long-lived sandbox containers.

---

### 5. Restrictive `tools.profile` no longer implicitly widened by `tools.exec` / `tools.fs` `(v2026.4.29)`

**Background:** Pre-4.29, configuring `tools.exec` or `tools.fs` would implicitly add those capabilities even if the agent's `tools.profile` was `messaging` or `minimal`. From 4.29 onward, restricted profiles need an explicit `tools.alsoAllow`.

**Our exposure:** **None confirmed.** Audit of `openclaw.json` shows neither `luoji` nor `cecat` uses `tools.profile`. The `chattpc26` agent is hibernated (commented out in `config.yaml`); its preserved config also did not use a restricted profile.

**Fix (if you ever add one):** Add `tools.alsoAllow: ["exec", "fs"]` (or specific subtool IDs) explicitly.

**Exposure:** **LOW** (no action needed for current config).

---

### 6. Subagent bootstrap context narrowed `(v2026.5.22)`

**Background:** Pre-5.22, a subagent spawned via `sessions_spawn` inherited the parent's full Sacred Eight bootstrap context. From 5.22, subagents see only `AGENTS.md` and `TOOLS.md` by default — persona, identity, memory, heartbeat, and setup files are excluded.

**Our exposure:** **None.** `grep -rn sessions_spawn` across all three agent workspaces and `openclaw.json` returned zero matches. We do not currently spawn subagents.

**Fix (if you ever start):** Set `bootstrapContextFiles` per agent to opt back in to the files needed.

**Exposure:** **LOW.**

---

### 7. Setup-code / browser / Control UI pairing now requires explicit approval `(v2026.5.12)`

**Background:** New device pairing for the dashboard, the browser tool, and setup-code flow all require explicit `devices approve <uuid>` per the 2026.2.26 pattern. Existing paired devices keep working per the 5.3 fix.

**Our exposure:** Our currently-paired Control UI device (approved during 2026.2.26 upgrade per `UPGRADE-2026.2.26.md` § 2) should persist. **Any new browser** used to access the dashboard after upgrade will need re-pairing.

**Fix when prompted:** `docker exec openclaw-gateway node dist/index.js devices list` and `devices approve <uuid>`.

**Exposure:** **LOW** (only noticeable on first new-browser login).

---

### 8. `plugins.bundledDiscovery` migration on restrictive `plugins.allow` `(v2026.5.4)`

**Background:** If `openclaw.json` uses a restrictive `plugins.allow` list, bundled providers (including the anthropic provider we route argo through) may stop being auto-discovered. `doctor --fix` migrates legacy configs by adding `plugins.bundledDiscovery: "compat"`.

**Our exposure:** Our `plugins` block uses `entries` (per-plugin `enabled: true/false`), not `allow`. **Not affected**, but `doctor --fix` may still write the compat key — fine.

**Exposure:** **LOW.**

---

## Part 2: Soft breaking changes (notice but won't crash)

### 9. `agentRuntime.id` becomes canonical `(v2026.4.25)`

Legacy runtime-policy configs migrate via `doctor --fix`. Just re-commit `openclaw.json` after the first start.

### 10. `threadBindings.spawnSessions` replaces split toggles `(v2026.5.2)`

Slack channel `replyToMode` / first-message behavior unchanged. `doctor --fix` migrates.

### 11. Internal queues + plugin install index moved to SQLite `(v2026.6.1)`

OpenClaw-internal — our host-side `shared/email/outbox/` and `shared/slack/outbox/` JSON files (drained by our cron scripts) are **unaffected**. New SQLite + WAL files will appear in the config volume; back them up as a unit. Local disk only — the 6.5 caveat about SQLite on NFS does not apply to us.

### 12. Default compaction timeout lowered to 180 s `(v2026.6.6)`

May cause heavy session compactions to fail earlier. If heartbeat logs show compaction timeouts after upgrade, set explicit `agents.defaults.compaction.timeoutSeconds`.

### 13. No-auth Tailscale exposure rejected `(v2026.5.27)`

If no `gateway.auth.token` is set on a Tailscale-bound listener, fail closed. Our gateway already uses auth (the existing dashboard-pairing flow proves it); not affected.

### 14. Default web-search providers no longer auto-selected `(v2026.6.8)`

If any agent relied on automatic DuckDuckGo for `web_search`, it now needs an explicit `tools.web.search.provider`. Check whether any calendar/heartbeat task silently depends on web search; if so, configure explicitly.

### 15. Sessions hidden-context model `(v2026.4.25)`

Affects historical transcript bytes only. Not user-visible after the migration runs.

### 16. Image processing Sharp → Rastermill `(v2026.5.26)`

Transparent. No action.

---

## Part 3: New features worth knowing about

These overlap with the Phase 1–4 containment work we just shipped. Worth a closer look:

- **Native `untrusted` content wrappers + system-event scrubbing** `(v2026.5.26 #87094, v2026.6.6 #91529)` — overlaps directly with our `<<<UNTRUSTED:source>>>` markers from Phase 4d. Worth checking whether OpenClaw's native syntax is compatible or whether we should align naming to avoid double-wrapping.

- **`/allowlist configWrites` origin policy** `(v2026.5.27)` — could harden the gateway against agent-initiated config writes. Pairs well with our existing `commands.config: false` policy.

- **Policy plugin** `(v2026.5.20, v2026.5.28)` — channel/sandbox-posture conformance enforcement. Could codify our iptables + sandbox + bind-mount discipline as machine-enforced rather than human-checked.

- **Exec approvals fail closed on timeout** `(v2026.6.6)` — defense-in-depth on tool calls.

- **Workboard** `(v2026.5.28, v2026.6.1)` — agent coordination primitives. May overlap or replace our `TODO.md` / `CALENDAR.md` scaffolding. Worth a future look as scope expands.

- **Skill Workshop with governed proposals + rollback** `(v2026.6.1)` — formalized review flow that pairs with our outbox approval pattern.

- **OpenTelemetry GenAI semantics + Prometheus plugin** `(v2026.4.25 onward)` — could light up token-usage observability without our home-rolled `collect-token-usage.sh`.

---

## Part 4: Releases scanned with no relevant changes

23 releases read in full: 4.24, 4.25, 4.26, 4.27, 4.29, 5.2, 5.3, 5.4, 5.5, 5.6, 5.7, 5.12, 5.18, 5.19, 5.20, 5.22, 5.26, 5.27, 5.28, 6.1, 6.5, 6.6, 6.8. The following contained only channel-specific (Telegram, Discord, WhatsApp, iMessage, Matrix, Feishu, etc.), Codex/Claude-CLI runtime changes we don't use, voice/realtime/Talk fixes, mobile-app changes, or CI/release-validation work:

- 5.5, 5.6, 5.7 — small fix-only patches
- 5.20 — Discord voice, MCP, model-picker, MiMo TTS
- 6.5 — Parallel web search, Matrix voice, Vertex catalog

---

## Part 5: Pre-flight audit results

Already run against the live `2026.4.2` gateway on 2026-06-16:

| Item | Result |
|------|--------|
| `plugins.allow` restrictive list | Not present (uses `plugins.entries` instead) — safe |
| Bare env-var `apiKey` strings | `vllm: "VLLM_API_KEY"` (suspect); `argo: "catlett"` (safe, literal); `brave: <real-key>` (safe) |
| `tools.profile` of `messaging`/`minimal` | Neither luoji nor cecat uses it. `chattpc26` hibernated. |
| `sessions_spawn` usage in agent files | Zero matches |
| Running sandbox containers | Two, 3 days old (`openclaw-sbx-agent-luoji-b88d9626`, `…-cecat-f7952fcc`) — will need removal before restart |
| Currently-paired devices | One Control UI device approved during 2026.2.26 upgrade |
| 4.2 image still on disk for rollback | YES, by SHA `sha256:6e1c25ee00f28ec4…` (the `:latest` tag now points at 6.8) |

---

## Recommended upgrade sequence

This is the path implied by the analysis above. Steps marked **(needs sudo)** require your password; the rest run as catlett.

### Phase A — pre-flight (no service interruption)

1. Back up the config volume to a timestamped tarball:
   ```bash
   docker run --rm -v openclaw_openclaw-config:/data -v /tmp:/backup alpine \
     tar czf /backup/openclaw-config-pre-6.8-$(date -u +%Y%m%dT%H%M%SZ).tar.gz -C /data .
   ```
2. Back up `openclaw.json` outside the container:
   ```bash
   docker exec openclaw-gateway cat /home/node/.openclaw/openclaw.json \
     > /tmp/openclaw-pre-6.8.json
   ```
3. Validate current config against the running 4.2:
   ```bash
   docker exec openclaw-gateway node dist/index.js config validate
   ```
   If it warns or errors, run `doctor --fix` while still on 4.2 and re-validate before continuing.
4. Re-tag the running 4.2 image so the rollback path has a stable tag:
   ```bash
   docker tag sha256:6e1c25ee00f28ec45898351385b1077b72705b864ce19209c1772c268020530b \
     ghcr.io/openclaw/openclaw:rollback-4.2
   ```

### Phase B — pause and stop (~30 sec downtime starts here)

5. Pause everything cron- and agent-driven:
   ```bash
   bash ~/code/spark-ai-agents/shared/scripts/ops/pause.sh global \
     --reason "OpenClaw upgrade 4.2 → 6.8"
   ```
6. Stop the gateway and remove the two long-lived sandbox containers (so the 5.3 shard migration starts clean):
   ```bash
   cd ~/code/spark-ai/openclaw && docker compose stop
   docker rm -f $(docker ps -aq --filter name=openclaw-sbx-agent)
   ```

### Phase C — upgrade

7. Start the gateway on 6.8 (the `:latest` tag already points here):
   ```bash
   docker compose up -d
   ```
8. Run `doctor --fix` to perform migrations (sandbox registry shard, `agentRuntime.id`, `threadBindings`, possibly `plugins.bundledDiscovery`):
   ```bash
   docker exec openclaw-gateway node dist/index.js doctor --fix
   ```
9. Install the externalized Slack plugin:
   ```bash
   docker exec openclaw-gateway node dist/index.js plugins install @openclaw/slack
   ```

### Phase D — smoke test before unpausing

10. Verify the gateway is healthy:
    ```bash
    docker logs openclaw-gateway --tail 50
    curl -sS http://<TAILSCALE_IP>:18789/health
    ```
11. Verify Slack plugin loaded and the bot is connected:
    ```bash
    docker exec openclaw-gateway node dist/index.js plugins list
    docker logs openclaw-gateway 2>&1 | grep -i 'slack' | tail -10
    ```
12. Run the smoke tests:
    ```bash
    bash ~/code/spark-ai-agents/shared/scripts/tests/test-all.sh
    ```

### Phase E — resume and verify

13. Unpause:
    ```bash
    bash ~/code/spark-ai-agents/shared/scripts/ops/unpause.sh global
    ```
14. Watch one heartbeat cycle for each agent (15 min) via:
    ```bash
    bash ~/code/spark-ai-agents/shared/scripts/ops/audit-tail.sh -f
    ```
15. Send a Slack DM to LuoJi and confirm she replies; same for CeC-Admin.
16. Pull the updated `openclaw.json` back to host and commit it if `doctor --fix` rewrote keys:
    ```bash
    docker exec openclaw-gateway cat /home/node/.openclaw/openclaw.json \
      > /tmp/openclaw-post-6.8.json
    diff /tmp/openclaw-pre-6.8.json /tmp/openclaw-post-6.8.json
    ```

### Rollback (if Phase D smoke fails)

```bash
bash ~/code/spark-ai-agents/shared/scripts/ops/pause.sh global --reason "rollback to 4.2"
cd ~/code/spark-ai/openclaw && docker compose stop
docker rm -f $(docker ps -aq --filter name=openclaw-sbx-agent) || true
# Restore the pre-6.8 config volume from backup
docker run --rm -v openclaw_openclaw-config:/data -v /tmp:/backup alpine \
  sh -c "rm -rf /data/* && tar xzf /backup/openclaw-config-pre-6.8-<timestamp>.tar.gz -C /data"
# Edit docker-compose.yml: change image: line to ghcr.io/openclaw/openclaw:rollback-4.2
docker compose up -d
bash ~/code/spark-ai-agents/shared/scripts/ops/unpause.sh global
```

The 4.2 image is preserved on disk under tag `:rollback-4.2`; backup tar carries the pre-migration config.
