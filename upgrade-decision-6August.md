# OpenClaw Upgrade Decision — 2026.6.11 → latest (2026.7.1)

**Date:** 2026-08-06
**Author:** investigation by Claude (Claude Code session), for the maintainer (catlett)
**Status:** ADVISORY — no upgrade performed. This is a decision memo, not a runbook.

---

## The question asked

> "We are using version 2026.6.11 — what will break if we migrate to the latest? Investigate and advise."

The software in question is the **OpenClaw gateway**, a self-hosted multi-agent
messaging/AI gateway running as a Docker container on an NVIDIA DGX Spark host.
It fronts two live agents — `luoji` and `cecat` — over Slack, routing their model
calls through a local **argo-shim** to Argonne's Argo API, with a local vLLM
(`Qwen/Qwen3-Coder-Next-FP8`) as automatic fallback.

Repo: `~/code/spark-ai`. Config is declarative: edit `config.yaml`, run
`./apply-config.sh`, which patches `openclaw.json` inside the `openclaw-config`
Docker volume and restarts the gateway.

---

## Current state (verified 2026-08-06)

| Fact | Value | How verified |
|------|-------|--------------|
| Running gateway | `2026.6.11`, `Up 20 hours (healthy)` | `docker ps` + `docker exec … --version` |
| Compose pin (`openclaw-gateway`) | `ghcr.io/openclaw/openclaw:2026.6.11` | `openclaw/docker-compose.yml:24` |
| Compose pin (`openclaw-cli`) | `ghcr.io/openclaw/openclaw:latest` ⚠️ | `openclaw/docker-compose.yml:73` |
| Local `:latest` Docker tag | **STALE** — points at `9ac90fcd6a7e` = 6.11, pulled 2026-06-29 | `docker images` |
| Local `:rollback-4.2` tag | `6e1c25ee00f2` (kept from prior upgrade) | `docker images` |
| Plugins installed | 49/68 enabled, incl. `@openclaw/slack`, `@openclaw/brave-plugin` | `plugins list` |

**"Latest" upstream, as of 2026-08-06:**
- **Stable: `2026.7.1`** (hotfixed to `2026.7.1-2` on 2026-08-04)
- Pre-release: `2026.7.2-beta.7` and earlier betas
- The GitHub release list jumps **straight from 6.11 to 7.1** — no `2026.7.0`
  tag exists (7.x line starts at 7.1). Could not confirm whether intermediate
  6.12+ patches ever existed; treat the 7.1 notes as the full delta.

**This is a major-version boundary (6.x → 7.x)** — the exact jump the team
**deliberately deferred** on 2026-07-28. From `CHANGELOG.md`:
> "stayed on pinned `2026.6.11` — did not take the `2026.7.x` major during this
> change (deliberate; keeps the fabric bring-up focused)."

---

## Two facts that correct likely assumptions

1. **The local `:latest` tag is stale, not current.** It still resolves to 6.11.
   Nothing 7.x has been pulled. `check-for-updates.sh` will report "new version
   available" the moment it runs `docker pull`, but the running gateway is
   untouched until deliberately restarted onto a new image.

2. **The `openclaw-cli` service still references `:latest`.** Currently harmless
   (same digest as the pinned gateway), but a stray `docker compose pull` would
   silently drift *that* service to 7.x. Recommend pinning it to `2026.6.11` too.

---

## What will break / needs action on a 6.11 → 7.1 upgrade

Ordered by exposure for **this specific deployment**. Deployment-specific risks
(1–3) matter far more than the generic 7.x changelog items.

### HIGH — deployment-specific

**1. Slack + brave plugins must be reinstalled / revalidated.**
Both `@openclaw/slack` (installed at 6.8) and `@openclaw/brave-plugin` (installed
at 6.11) are *externalized* plugins — not bundled in the image since 5.12. Slack
is the **primary control channel**; brave is the web-search provider.
`apply-config.sh` has a preflight (line ~166) that **crash-loops the gateway** if
`tools.web.search.provider = brave` is referenced but the plugin isn't
present+enabled (config.yaml:76). A major bump can force plugin re-resolution.
→ After upgrade: `plugins list`, confirm both enabled, do a Slack DM round-trip
with each agent before unpausing.

**2. Custom `argo` provider (`api: "anthropic-messages"`) — the entire model path.**
Both live agents route through this:
- `luoji` → `argo/claudeopus47`
- `cecat` → `argo/claudesonnet46`

Defined in `config.yaml` `providers.argo` with `baseUrl:
"http://172.18.0.1:44497"` (the socat bridge to argo-shim) and
`api: "anthropic-messages"`. `apply-config.sh:253` (`build_provider_block`)
writes this into `models.providers.argo` in `openclaw.json`.
**Could not confirm from 7.x docs that the `anthropic-messages` custom-provider
API shape is unchanged.** If it shifted, *both agents lose their primary model*.
The `vllm/Qwen3-Coder-Next-FP8` fallback (`defaults.fallback_model`) would catch
it but degraded. → Highest-risk item. Probe argo immediately post-upgrade.

**3. Gateway crash-loop behavior changed (7.x).**
7.x replaces infinite auto-restart with a **supervised recovery mode requiring
manual intervention** (a `doctor` repair path). This is *safer* than the 6.8
crash-loop incident this deployment already suffered (see
`UPGRADE-2026.6.8.md` / CHANGELOG 2026-07-10), but it means a bad config will
**not** self-recover — an operator must drive `doctor` by hand.

### MEDIUM / LOW — generic 7.x changelog

**4. `doctor --fix` now merges retired model names** into current ones (preserving
aliases + tuning params). Model IDs here are custom argo internal_names
(`claudesonnet46`, `claudeopus47`, `claudehaiku45`) — low risk of unwanted
merging, but verify model selection after `doctor --fix`.

**5. `doctor` refuses to replace an unreadable `openclaw.json`** (fails closed —
same spirit as the 5.3 change already handled). Pre-flight `config validate` on
6.11 before upgrading still applies.

**6. Node-only SQLite enforcement** — 7.x blocks non-Node runtimes (e.g. Bun) from
opening SQLite-backed state. **No impact** — this deployment runs the stock Node
image. Noted for completeness.

**7. CLI-container caveat persists** — run CLI commands via
`docker exec openclaw-gateway node dist/index.js <cmd>`, NOT the `openclaw-cli`
compose service (it can't reach the Tailscale-bound gateway over the Docker
network). Documented in `openclaw/UPGRADE-2026.2.26.md` §5.

### Not applicable to this deployment
Telegram/Discord/Nextcloud Talk changes, Codex subagent delegation changes,
mobile-app and Control-UI overhaul — none of these features are used here.

---

## Recommendation

**Do NOT take 7.x yet, absent a specific reason.**

- 6.11 is healthy and stable.
- 7.x's headline features (Control UI overhaul, mobile apps, new model families
  like GPT-5.6 / Tencent Hy3 / Meta Muse) are **not used** by this deployment.
- The real cost is **unverified compatibility** across a major boundary for the
  two load-bearing, deployment-specific pieces: the `argo` custom provider and
  the externalized Slack/brave plugins.

**Two things worth doing regardless of the upgrade decision:**
1. Pin the `openclaw-cli` service to `2026.6.11` (docker-compose.yml:73), so a
   stray `docker compose pull` can't drift it onto 7.x.
2. Note that the docs release page collapses everything between 6.11 and 7.1 —
   the 7.1 notes were treated as the full delta because no intermediate tags
   were found.

---

## If/when the upgrade IS taken — proven playbook

Follow the exact sequence in `UPGRADE-2026.6.8.md` § "Recommended upgrade
sequence" (it worked for 4.2 → 6.11). Adapt version numbers. Key steps:

1. **Back up** the config volume to a timestamped tarball + copy `openclaw.json`
   out.
2. **`config validate`** on the running 6.11 first; `doctor --fix` while still on
   6.11 if it flags anything.
3. **Re-tag the current 6.11 image** as `:rollback-6.11` (mirror the existing
   `:rollback-4.2` pattern) so rollback has a stable tag.
4. **Pause** cron/agent activity
   (`spark-ai-agents/shared/scripts/ops/pause.sh global`).
5. **Stop gateway; remove long-lived sandbox containers**
   (`docker rm -f $(docker ps -aq --filter name=openclaw-sbx-agent)`) so registry
   migration starts clean.
6. **Bump the pin** in `docker-compose.yml` to `2026.7.1` (NOT `:latest`),
   `docker compose up -d`.
7. **`doctor --fix`** to run migrations.
8. **Verify/reinstall plugins:** `plugins list`; reinstall `@openclaw/slack` and
   `@openclaw/brave-plugin` if missing.
9. **Probe argo** (POST `claudesonnet46` through the stack) to confirm the custom
   provider still works — highest-risk check.
10. **Smoke test**, then unpause, then Slack DM round-trip with luoji and cecat.
11. Pull `openclaw.json` back to host, `diff` against pre-upgrade, commit if
    `doctor --fix` rewrote keys.

**Rollback:** restore the config-volume tarball, switch compose image to
`:rollback-6.11`, `docker compose up -d`, unpause.

---

## Sources

- GitHub: `https://github.com/openclaw/openclaw/releases` (release list, tags,
  dates)
- GitHub: `https://github.com/openclaw/openclaw/releases/tag/v2026.7.1`
- Docs: `https://docs.openclaw.ai/releases/2026.7.1` (breaking changes)
- Local: `docker ps`, `docker images`, `docker exec … --version`,
  `plugins list`
- Local repo: `openclaw/docker-compose.yml`, `config.yaml`, `apply-config.sh`,
  `CHANGELOG.md`, `UPGRADE-2026.6.8.md`, `openclaw/UPGRADE-2026.2.26.md`
