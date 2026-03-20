# Changelog — spark-ai

All changes to documentation files in this repo.

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
