# Changelog — spark-ai

All changes to documentation files in this repo.

## 2026-08-18 — Restore Sage MCP access for luoji (regression from the memory fix)

**Symptom:** Luoji could call the Sage Continuum MCP tools in April but not in
August. From inside the sandbox this is indistinguishable from a server that was
never configured — the tools are simply absent, with no error the agent can see.

**Cause:** not a Sage problem at all. The gateway connects to
`mcp.sagecontinuum.org` fine and receives all 33 tools; they were being stripped
afterwards by the *sandbox* tool policy, logged on every turn as:

```
[agents/tool-policy] tool policy removed 33 tool(s) via sandbox tools.allow: sage__*
```

`agents.list[].tools.sandbox.tools.alsoAllow` is a second allow gate applied
after the MCP handshake, and it is deny-by-omission **only once non-empty**. An
empty list permits everything; the image's `DEFAULT_TOOL_ALLOW` names 15
built-ins and has never named MCP or plugin tools. So the 2026-08-16 memory
repair (`e1af454`), which added `also_allow: [group:memory]`, flipped luoji's
list from open to closed and silently revoked Sage in the same move. One tool
restored, another lost, no error either way.

Changes:

- `config.yaml`: added `bundle-mcp` to luoji's `sandbox.tools.also_allow`, plus
  a comment on the second-gate behavior so the next `also_allow` edit doesn't
  repeat this. `cecat` deliberately left out — Sage has been luoji-only since
  2026-04-11, so `doctor` still warns about `agents.list[1]` by design.

Verified live: `sandbox explain --agent luoji` lists `bundle-mcp`, the `sage__*`
stripping is gone from the gateway logs, and a real luoji turn calling
`sage__list_all_nodes` returned 295 nodes.

**Known remaining, same cause:** luoji still loses `web_search`, `web_fetch`,
`agents_list`, `message`, `tts`, and the three `*_goal` tools to this gate every
turn. `web_search`/`web_fetch` are `enabled: true` with a live Brave key and
have been unreachable since 2026-08-16. Left alone pending a deliberate call on
which of these luoji should actually have.

**Diagnostic note:** `docker logs openclaw-gateway | grep "tool policy removed"`
names every stripped tool on every turn. Check it first when an agent reports a
missing tool — the evidence exists only on the host, so the agent itself will
mis-diagnose this.

## 2026-07-28 — Bind-mount Luoji session logs to a host path (spark-fabric FALDA prep)

**Context:** The `spark-fabric` project (shared memory substrate for the two
agents) needs to tail Luoji's raw session logs into FALDA. Those logs live in
the `openclaw_openclaw-config` named volume at
`agents/luoji/sessions/`, reachable only via `docker exec` — not a host path.
Surfacing them to the host makes the FALDA tap a plain file reader. See
`spark-fabric/runlog/RUNLOG-2026-07-28-bringup.md` for the full episode.

Changes:

- `openclaw/docker-compose.yml`: added one bind mount —
  `/home/catlett/.openclaw-sessions/luoji → /home/node/.openclaw/agents/luoji/sessions:rw`.
  Host dir is in `$HOME`, deliberately **outside** any repo and **outside** the
  luoji sandbox's `/workspace` mount (`spark-ai-agents/luoji`), so the agent
  cannot see or rewrite its own raw session logs. uid alignment is clean
  (gateway `node` = uid 1000 = `catlett`).

Migration performed (one-time, not in repo):

- Snapshot of the config volume:
  `~/backups/openclaw/openclaw-config-pre-bindmount-20260728T194143Z.tar.gz`.
- Compose backup: `openclaw/docker-compose.yml.bak-pre-bindmount-20260728T194500Z`
  (local only).
- Copied the 20 existing session items to the host dir before recreating the
  gateway, so the bind mount didn't shadow Luoji's history.

Verified: mount live and writable, history intact through the mount, sandbox
isolation holds (luoji sandbox sees `/workspace` but not the sessions dir), and
a real Slack DM to Luoji was read back from the host path.

**Note:** stayed on pinned `2026.6.11` — did not take the `2026.7.x` major
during this change (deliberate; keeps the fabric bring-up focused).

## 2026-07-10 — Gateway recovery + upgrade 4.2 → 6.11; apply-config.sh 6.x schema migrations

**Context:** `check-for-updates.sh` had pulled `ghcr.io/openclaw/openclaw:latest`
weeks earlier (which by then meant 2026.6.8), and some later restart cycled the
container onto that image without any of the migration steps documented in
`UPGRADE-2026.6.8.md`. The gateway went into an infinite crash-loop on the
4.2-era `openclaw.json`, and cron `stack-health` was posting failure alerts.
Recovery ended up being the natural moment to also close out to the current
line-of-latest (2026.6.11) so `apply-config.sh` stops shipping schema drift.

Changes:

- `openclaw/docker-compose.yml`: pinned image to `ghcr.io/openclaw/openclaw:2026.6.11`
  (was `:latest`). Prevents another unattended auto-upgrade. Bump this tag
  deliberately per the sequence in `UPGRADE-2026.6.8.md`.

- `apply-config.sh`: migrations for the 5.x/6.x strict schema, so the script
  stops writing config that the gateway rejects. All are silent — you can
  keep the legacy key names in `config.yaml` and this script will translate:
    * `browser.ssrfPolicy.allowPrivateNetwork` → `dangerouslyAllowPrivateNetwork`
    * `channels.slack.streaming: bool` → `{mode: "off"|"block"}`
    * `channels.slack.channels.<id>.allow` → `.enabled`
    * `bindings[]` entries for inactive agents are dropped (6.8 cross-validates
      `agentId` against `agents.list`). Hibernating an agent no longer requires
      also stripping its Slack bindings.
  Also new: preflight check that any non-bundled `tools.web.search.provider`
  (e.g. `brave`, from 5.12) is installed AND enabled in the gateway before
  writing config — a missing/disabled provider plugin crash-loops the gateway.

- `apply-config.sh`: `gateway_has_plugin()` helper parses `plugins list --json`
  correctly (the 6.11 output shape is `{"plugins": [{id, enabled, status, ...}, ...]}`
  with prefix migration-warning lines that must be sliced past).

- `config.yaml`: `browser.ssrfPolicy` now written with the new key name
  (`dangerouslyAllowPrivateNetwork`) plus a comment on the migration. The
  `tools.web.search` block gained a note about the plugin dependency
  (`clawhub:@openclaw/brave-plugin`, requires runtime ≥6.11).

- Gateway state changes (not in code, but recorded here for the audit trail):
    * Backups: `/tmp/openclaw-config-pre-6.8-20260710T115727Z.tar.gz` (before
      the schema patches) and `/tmp/openclaw-config-pre-6.11-20260710T184323Z.tar.gz`
      (before the 6.11 hop). Move these somewhere durable if you want to keep
      rollback safety across reboots.
    * `ghcr.io/openclaw/openclaw:rollback-4.2` tag added to the image `6e1c25ee00f2`
      still on disk, per `UPGRADE-2026.6.8.md` § Rollback.
    * Installed plugins: `@openclaw/slack` (2026.6.8), `@openclaw/brave-plugin`
      (2026.6.11). Both were bundled in 4.2 and became externalized in 5.12.

- `start-all.sh`: `export PATH="$HOME/.local/bin:$PATH"` at the top so cron
  callers (which do not source ~/.profile) can find `argo-shim`. The
  `stack-health` cron was silently failing on this even when the stack was
  otherwise fine.

## 2026-06-01 — Hibernate chattpc26 agent (TPC26 complete)

`config.yaml`: comment out the chattpc26 agent block. TPC26 conference is
over; agent hibernated until TPC27 prep begins (~6-8 months). All settings
preserved as inline comments so the agent can be restored by uncommenting
the block and re-running `apply-config.sh`. See
`spark-ai-agents/chattpc26/HIBERNATION.md` for the full shutdown/wake-up
checklist (single source of truth).

## 2026-06-11 — Gateway DNS fix and start-all.sh Duo/timeout improvements

- `openclaw/docker-compose.yml`: added explicit `dns:` entries (`10.0.4.1`,
  `1.1.1.1`) to the `openclaw-gateway` service. Without this, the container
  inherited the host's `nameserver 127.0.0.53` (systemd-resolved stub), which
  inside a container points at the container's own loopback — causing all
  external lookups (e.g. `slack.com`) to fail with `EAI_AGAIN` and the Slack
  socket-mode provider to never connect. With the explicit DNS list, Docker's
  internal resolver (`127.0.0.11`) forwards to the listed upstream servers.
- `start-all.sh`: raised health-check timeouts that were too tight in practice:
  argo-shim 60s → 90s; gateway 60s → 180s (gateway's Slack socket-mode retry
  backoff alone can consume most of a 60s budget).
- `start-all.sh`: added a 20-second quiet window before the argo-shim
  "warming up" progress line begins, with an on-screen note telling the user
  to enter their Duo passcode if prompted. Previously the `\r`-redrawn
  progress line could overwrite the Duo prompt on a cold start.

## 2026-05-22 — Idempotent start-all.sh, retire Lambda5 references

- `start-all.sh`: rewritten as an idempotent restorer. Safe to run any time.
  Performs deep end-to-end health checks (POSTs `claudesonnet46` through each
  layer) on all four components — vLLM, argo-shim, socat bridge, OpenClaw
  gateway — and restarts only the components that are unhealthy. Auto-starts
  `argo-shim` if missing (logs to `argo-shim.log`). Implements a cascade rule:
  if vLLM is restarted, socat and the gateway are also restarted (because
  `nim_net` and the `172.18.0.1` host interface get recreated). Replaces
  three previous scripts.
- Deleted `start-shim.sh`, `start-openclaw.sh`, `start-socat-bridge.sh` —
  their responsibilities are now folded into the unified `start-all.sh`.
- `config.yaml`: removed obsolete comment that described the old
  `ssh -N -L 8443:lambd5:443 <user>@lambda.lcrc.anl.gov` tunnel. Replaced
  with a description of the current shim/socat path managed by `start-all.sh`.
- `argo_lambda_tunnel_guide.md`: marked OBSOLETE at the top with a banner
  pointing to the current shim-based path. Content preserved for historical
  reference and for anyone debugging a similar SSH-tunnel scenario.
- `argo-list-models.sh`: rewritten to query the local shim
  (`http://127.0.0.1:44497/v1/models`) instead of running `curl` over
  `ssh -J logins,homes catlett@lambda5.cels.anl.gov`. Now a one-line script.
- `shutdown.sh`: previously untracked, now committed since `CLAUDE.md` in the
  `spark-ai-agents` repo references it as the canonical shutdown entry point.
- `.gitignore`: added `archive/`, `socat-bridge.log`, `argo-shim.log`.
- New `archive/` folder: holds stale snapshots and one-off scratch files
  (`argo-models*.txt`, `deepseek-r1/`, `qwen3.5/`, `temp.json`,
  `openclaw/reconstruct-temp.txt`). Gitignored.

## 2026-04-11
- `config.yaml`: added `mcp:` section — declarative MCP server configuration;
  each entry specifies a url, optional transport (default: `streamable-http`),
  and an auth block with `token_secret` (key name in secrets.yaml), optional
  `username`, and `token_format` (default: `"Bearer {token}"`; use
  `"Bearer {username}:{token}"` for servers requiring a username prefix)
- `apply-config.sh`: added MCP server handling as the fifth managed section —
  reads `mcp.servers` from config.yaml, resolves tokens from secrets.yaml,
  builds the `mcp.servers` block in openclaw.json; config.yaml is authoritative
  (stale entries removed on each run); if `mcp:` key is absent from config.yaml
  the existing openclaw.json mcp block is left untouched for backward compat;
  tokens logged as `<redacted>` in output; docstring updated to reflect five sections
- Initial MCP server configured: SAGE Continuum (`https://mcp.sagecontinuum.org/mcp`),
  token stored as `sage_mcp_token` in secrets.yaml

## 2026-04-05

- `openclaw/docker-compose.yml`: upgraded OpenClaw gateway image from 2026.2.17 →
  2026.4.2 — pulled new image, ran `doctor --fix`, restarted gateway; all agents
  (luoji, cecat, chattpc26) operational post-upgrade
- `check_openclaw.sh`: no changes — used to confirm new image digest prior to pull

## 2026-03-28
- `config.yaml`: added `defaults:` section with `fallback_model` — sets a global
  fallback model for all agents; OpenClaw automatically retries with this model when
  the primary is unreachable (connection refused, timeout, HTTP 5xx, rate limit);
  default value is `vllm/Qwen/Qwen3-Coder-Next-FP8` so agents keep working if the
  Argo tunnel goes down
- `config.yaml`: added `#agent-main-test` (C0AMBT2GD97) channel binding → `main` agent
- `apply-config.sh`: added global fallback model support — reads `defaults.fallback_model`
  and writes it to `agents.defaults.model.fallbacks` in `openclaw.json`
- `apply-config.sh`: fixed bug where adding a channel to `config.yaml channels:` updated
  `bindings` but not `channels.slack.channels` (the event delivery allowlist); the script
  now syncs both on every run — channels not in `config.yaml` are removed from the allowlist
- `README.md`: updated "Model configuration" section — added `defaults.fallback_model`
  docs and example; expanded supported providers table to include Argo models
- `README.md`: updated "Adding a new agent" step 4 — `apply-config.sh` now handles both
  `bindings` and `channels.slack.channels` automatically
- `README.md`: updated "Multi-agent setup" — added note that both lists are managed by
  `apply-config.sh` and should not be edited manually
- `TROUBLESHOOT.md`: updated "Agent not responding in a channel" checklist to reflect that
  `apply-config.sh` manages both `bindings` and `channels.slack.channels` in sync
- `TROUBLESHOOT.md`: updated "Multi-agent routing not working" — same

## 2026-03-20
- `config.yaml`: added `notify:` section — deployment settings for the daily
  sync/notification pipeline; `dry_run_slack_channel_id` (Slack channel for
  `--dry-run` test posts, currently `#openclaw-test`) and `system_owner_email`
  (email address that receives all redirected emails during a dry run); values
  are extracted by `run-notify.sh` at startup and passed as Docker env vars
  (`DRY_RUN_CHANNEL`, `SYSTEM_OWNER_EMAIL`) — `notify.py` reads them from the
  environment so no YAML parser is needed inside the container

## 2026-03-19
- `config.yaml`: added `channels:` section — replaces `spark-ai-agents/CHANNELS.md` as
  source of truth for Slack channel → agent bindings; each entry has `id` (channel ID),
  `name` (human-readable label), and `agent`; default agent (main) handles DMs and unbound
  channels without needing an explicit entry
- `apply-config.sh`: extended to manage Slack channel bindings in addition to model
  assignments; reads `channels:` from `config.yaml`, rebuilds the `bindings[]` array in
  `openclaw.json` completely on each run; missing agent references produce a warning and
  are skipped; adds summary printout of active bindings after apply; updated docstring

## 2026-03-13
- `openclaw/docker-compose.yml`: added read-only mount of `~/.config/slack` into gateway — same pattern as existing gogcli credential mount; required by `send-slack-posts.sh` cron script for Slack bot token access
- `openclaw/docker-compose.yml`: tightened security comment to clarify that scoped `~/.config/<tool>` mounts are the established credential pattern (not a blanket prohibition)
- `README.md`: updated repo tree to include `send-slack-posts.sh` and `shared/slack-outbox/`, `shared/slack-sent/` directories
- `README.md`: added outbound Slack post setup to Step 11 (Connect Slack) — bot token storage, cron entry, outbox directories
- `README.md`: added full crontab reference to Step 14 (session management) documenting all five host-side cron scripts

## 2026-03-10
- `config.yaml`: added — per-agent model assignment config; default is local vLLM
- `secrets.yaml.example`: added — template for API credentials (copy to `secrets.yaml`, gitignored)
- `apply-config.sh`: added — reads `config.yaml` + `secrets.yaml`, patches `openclaw.json` in the Docker volume, and restarts the gateway; supports `--dry-run`; auto-reverts to local vLLM if a crash-loop is detected within 20 seconds of restart
- `revert-to-local.sh`: added — emergency fallback; strips all remote-model config from `openclaw.json` and restarts the gateway; no config files needed
- `.gitignore`: added `secrets.yaml`
- `README.md`: added "Model configuration" section documenting per-agent model switching
- `TROUBLESHOOT.md`: updated "Model configuration" entry to reflect automatic post-restart health check

## 2026-03-03
- README.md: added PATHS.md to agent workspace structure diagram (both agents)
- README.md: updated "Adding a new agent" step 2 — added PATHS.md guidance and absolute path warning
- README.md: moved "Sandbox gotchas" section to TROUBLESHOOT.md; replaced with pointer
- README.md: moved "openclaw.json key config notes" section to TROUBLESHOOT.md; replaced with pointer
- PLAN.md: fixed stale workspace path (~/openclaw-workspace → ~/code/spark-ai-agents) throughout
- PLAN.md: removed outdated agent.json snippet in use case section; replaced with current approach
- PLAN.md: added PATHS.md reference to openclaw-workspace status table entry
- TROUBLESHOOT.md: added "openclaw.json key config notes" section (moved from README)
- TROUBLESHOOT.md: added "Sandbox gotchas" section (moved from README) with new "Absolute paths in agent markdown files" subsection covering PATHS.md strategy and ../shared vs /shared pitfall
- CHANGELOG.md: created this file
- check_openclaw.sh: created — checks GHCR for a newer OpenClaw image digest without pulling; --update pulls and generates upgrade analysis prompt
- check_model.sh: created — checks HuggingFace for a newer model commit without downloading; --update prompts for HF token and downloads (~46GB, resumable)
- openclaw/GMAIL.md: contacts check architecture — deterministic gog checks owned by chattpc26 (queue time) and cron (send time); main focuses on content screening only
- scripts/send-approved-emails.sh: fixed duplicate-send bug (original outbox file not removed after send); fixed contacts check to use gog contacts list --json instead of gog contacts search (which matches by name, not email); added REJECTED_DIR variable
