# Changelog — spark-ai

All changes to documentation files in this repo.

## 2026-03-10
- `config.yaml`: added — per-agent model assignment config; default is local vLLM
- `secrets.yaml.example`: added — template for API credentials (copy to `secrets.yaml`, gitignored)
- `apply-config.sh`: added — reads `config.yaml` + `secrets.yaml`, patches `openclaw.json` in the Docker volume, and restarts the gateway; supports `--dry-run`
- `revert-to-local.sh`: added — emergency fallback; strips all remote-model config from `openclaw.json` and restarts the gateway; no config files needed
- `.gitignore`: added `secrets.yaml`
- `README.md`: added "Model configuration" section documenting per-agent model switching

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
