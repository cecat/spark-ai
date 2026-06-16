# Changelog — spark-ai

All changes to documentation files in this repo.

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
