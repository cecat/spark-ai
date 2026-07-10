#!/usr/bin/env python3
"""
apply-config.sh — Apply agent configuration to the OpenClaw gateway.

Reads config.yaml and secrets.yaml, patches openclaw.json in the Docker volume,
and restarts the gateway.

Usage:
    ./apply-config.sh [--dry-run]

Requirements:
    pip install --break-system-packages pyyaml

Manages five sections of openclaw.json:

  Global defaults (config.yaml defaults:):
    - fallback_model: written to agents.defaults.model.fallbacks — OpenClaw
      automatically tries this model if the primary is unreachable (tunnel down,
      provider outage, connection timeout, HTTP 5xx). Applies to all agents.

  Custom provider registration (config.yaml providers:):
    - Writes each custom provider's block into models.providers in openclaw.json
    - API key is read from secrets.yaml using the key {provider_name}_api_key
    - Provider block includes baseUrl, apiKey, api type, and model definitions
    - Models require id, name, contextWindow, maxTokens; defaults are applied
      for reasoning (false), input ([text]), and cost (all zeros for internal
      providers — override in config.yaml if needed)

  Model assignments (config.yaml agents:):
    - Anthropic: native support — API key goes in openclaw.json env.ANTHROPIC_API_KEY,
      no providers block needed. Model format: anthropic/claude-sonnet-4-6
      Ref: https://docs.openclaw.ai/providers/anthropic
    - vLLM: custom provider block under models.providers.vllm (already configured
      via the onboarding wizard — this script does not touch it)
    - Custom providers (e.g. argo): defined in config.yaml providers: section,
      registered automatically. Model format: argo/model-id

  Web tools (config.yaml tools:):
    - tools.web.search: enabled/provider/apiKey -- sets tools.web.search in openclaw.json
      Provider "brave" reads brave_search_api_key from secrets.yaml
    - tools.web.fetch: enabled -- sets tools.web.fetch.enabled in openclaw.json
    - Per-agent tools.deny: written to each agent entry to restrict tool access
      (e.g. chattpc26 has web_search and web_fetch in its deny list)

  Slack channel bindings (config.yaml channels:):
    - Replaces the entire bindings[] array in openclaw.json with the list from
      config.yaml; each entry maps a Slack channel ID to an agent
    - Also updates channels.slack.channels allowlist so the gateway actually
      delivers events from each listed channel (both must be set for a channel
      to work; this script keeps them in sync automatically)
    - The default agent (marked "default": true in openclaw.json agents.list) handles
      all DMs and any channel not in the bindings list
    - After updating bindings, generates {OPENCLAW_WORKSPACE}/shared/CHANNELS.md —
      a markdown table of channel name, ID, and agent, readable by all agent sandboxes
      at /shared/CHANNELS.md; this is the single source of truth for channel IDs so
      agents never need hardcoded IDs in PATHS.md

  MCP servers (config.yaml mcp:):
    - Replaces the entire mcp.servers dict in openclaw.json with the list from
      config.yaml; stale entries not present in config.yaml are removed
    - If the mcp: key is absent from config.yaml entirely, the existing
      openclaw.json mcp block is left untouched (backward compatibility)
    - Auth tokens are read from secrets.yaml via token_secret key name; the
      Authorization header value is built from token_format (default: "Bearer {token}";
      use "Bearer {username}:{token}" for servers that require a username prefix)
    - Tokens are never written to config.yaml — only the key name appears there

OpenClaw 2026.6.8 schema migrations handled transparently:

  - browser.ssrfPolicy.allowPrivateNetwork -> dangerouslyAllowPrivateNetwork
    (renamed by 5.x; strict object schema rejects the legacy key)
  - channels.slack.streaming: bool -> {mode: "off"|"block"}
    (SlackStreamingConfigSchema became an object)
  - channels.slack.channels.<id>.allow -> .enabled
    (per-channel schema rename)
  - bindings[] entries for hibernated/removed agents are dropped
    (bindings.agentId is now cross-validated against agents.list)
  - Preflight: if tools.web.search.provider is a non-bundled provider
    (e.g. brave, from 2026.5.12), verify the plugin is installed before
    writing config, since a missing plugin crash-loops the gateway.

If you edit config.yaml with the legacy key names (e.g. allowPrivateNetwork),
this script migrates them silently on write. Update config.yaml at your leisure.
"""

import json
import subprocess
import sys
import os
import time
from datetime import datetime, timezone

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.yaml")
SECRETS_PATH = os.path.join(SCRIPT_DIR, "secrets.yaml")
COMPOSE_FILE = os.path.join(SCRIPT_DIR, "openclaw", "docker-compose.yml")
ENV_PATH = os.path.join(SCRIPT_DIR, "openclaw", ".env")
REVERT_SCRIPT = os.path.join(SCRIPT_DIR, "revert-to-local.sh")
VOLUME_NAME = "openclaw_openclaw-config"
HEALTH_CHECK_SECONDS = 20
HEALTH_POLL_INTERVAL = 3

# Providers with native OpenClaw support — no custom provider block needed
NATIVE_PROVIDERS = {"anthropic", "vllm"}

# Default values applied to model definitions for custom providers
MODEL_DEFAULTS = {
    "reasoning": False,
    "input": ["text"],
    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
}

# ---------------------------------------------------------------------------

def read_env_file(path):
    """Read KEY=VALUE pairs from a .env file, return as dict. Ignores comments and blank lines."""
    env = {}
    if not os.path.exists(path):
        return env
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                key, _, val = line.partition("=")
                env[key.strip()] = val.strip()
    return env


def load_yaml(path):
    try:
        import yaml
    except ImportError:
        print("ERROR: pyyaml not installed. Run: pip install --break-system-packages pyyaml")
        sys.exit(1)
    with open(path) as f:
        return yaml.safe_load(f)


def docker_read_json(volume, path):
    result = subprocess.run(
        ["docker", "run", "--rm", "-v", f"{volume}:/data", "alpine", "cat", f"/data/{path}"],
        capture_output=True, text=True, check=True,
    )
    return json.loads(result.stdout)


def docker_write_json(volume, path, data):
    content = json.dumps(data, indent=2)
    subprocess.run(
        ["docker", "run", "--rm", "-i", "-v", f"{volume}:/data", "alpine",
         "sh", "-c", f"cat > /data/{path}"],
        input=content, text=True, check=True,
    )


def restart_gateway():
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "restart", "openclaw-gateway"],
        check=True,
    )


def gateway_has_plugin(plugin_id):
    """Return True if the running gateway has the named plugin ENABLED.

    Since 2026.5.12, web-search providers other than the bundled defaults
    (e.g. "brave") ship as separately-installed plugins. Referencing a
    provider without its plugin installed AND enabled crash-loops the
    gateway with "web_search provider is not available". Check before
    writing.

    Returns False if the container is not running (fresh install), which
    lets the caller give an actionable error message.

    `plugins list --json` on 6.11 returns {"registry":..., "plugins":[...]}
    with entries containing id/name/state/source fields. Prefix log lines
    (e.g. [state-migrations]) may precede the JSON, so slice from the first
    '{'.
    """
    try:
        result = subprocess.run(
            ["docker", "exec", "openclaw-gateway",
             "node", "openclaw.mjs", "plugins", "list", "--json"],
            capture_output=True, text=True, timeout=15,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError):
        return False
    if result.returncode != 0:
        return False
    stdout = result.stdout
    idx = stdout.find("{")
    if idx < 0:
        return False
    try:
        data = json.loads(stdout[idx:])
    except (ValueError, json.JSONDecodeError):
        return False
    plugins = data.get("plugins") if isinstance(data, dict) else data
    if not isinstance(plugins, list):
        return False
    for entry in plugins:
        if not isinstance(entry, dict):
            continue
        if entry.get("id") != plugin_id and entry.get("name") != plugin_id:
            continue
        # Require the plugin be enabled AND loaded; a disabled or errored
        # plugin still crash-loops the gateway on a provider reference.
        enabled = bool(entry.get("enabled", True))
        status = str(entry.get("status", "loaded")).lower()
        return enabled and status == "loaded"
    return False


# Patterns that indicate OpenClaw rejected the config and is crash-looping
CRASH_PATTERNS = [
    "Config invalid",
    "config invalid",
    "ZodError",
    "Cannot find module",
    "SyntaxError",
]


def watch_for_crash_loop(timeout=HEALTH_CHECK_SECONDS, poll=HEALTH_POLL_INTERVAL):
    """
    Poll openclaw-gateway logs for `timeout` seconds looking for config errors.
    Returns (crashed: bool, evidence: str).
    Ctrl-C skips the check without triggering a revert.
    """
    since = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    deadline = time.time() + timeout

    print(f"  Watching gateway logs for {timeout}s (Ctrl-C to skip)...", flush=True)
    try:
        while time.time() < deadline:
            time.sleep(poll)
            result = subprocess.run(
                ["docker", "compose", "-f", COMPOSE_FILE, "logs",
                 "--no-color", f"--since={since}", "openclaw-gateway"],
                capture_output=True, text=True,
            )
            logs = result.stdout + result.stderr
            for pattern in CRASH_PATTERNS:
                if pattern in logs:
                    return True, f"'{pattern}' detected in logs"
    except KeyboardInterrupt:
        print("\n  (health check skipped by user)")
        return False, "skipped"

    return False, "clean"


def build_provider_block(name, provider_cfg, api_key):
    """Build the openclaw.json models.providers entry for a custom provider."""
    models = []
    for m in provider_cfg.get("models", []):
        entry = {}
        # Apply defaults first, then config.yaml values override
        for k, v in MODEL_DEFAULTS.items():
            entry[k] = v
        entry.update(m)
        # Ensure required fields are present
        for required in ("id", "name", "contextWindow", "maxTokens"):
            if required not in entry:
                print(f"ERROR: provider '{name}' model missing required field '{required}': {m}")
                sys.exit(1)
        models.append(entry)

    if not models:
        print(f"ERROR: provider '{name}' has no models defined in config.yaml")
        sys.exit(1)

    return {
        "baseUrl": provider_cfg["baseUrl"],
        "apiKey": api_key,
        "api": provider_cfg["api"],
        "models": models,
    }


# ---------------------------------------------------------------------------

def main():
    dry_run = "--dry-run" in sys.argv

    # --- Load config and secrets ---
    for path, label in [(CONFIG_PATH, "config.yaml"), (SECRETS_PATH, "secrets.yaml")]:
        if not os.path.exists(path):
            print(f"ERROR: {label} not found at {path}")
            sys.exit(1)

    config = load_yaml(CONFIG_PATH)
    secrets = load_yaml(SECRETS_PATH)

    defaults_config = config.get("defaults", {})
    agents_config = config.get("agents", {})
    providers_config = config.get("providers", {})

    if not agents_config:
        print("ERROR: no agents defined in config.yaml")
        sys.exit(1)

    # --- Determine which providers are needed by agents ---
    needed_providers = set()
    for agent_id, agent_cfg in agents_config.items():
        model_str = agent_cfg.get("model", "")
        if "/" not in model_str:
            print(f"ERROR: agent '{agent_id}' model must be 'provider/model-id', got: '{model_str}'")
            sys.exit(1)
        needed_providers.add(model_str.split("/")[0])

    # --- Validate custom providers are defined and have API keys ---
    custom_providers_needed = needed_providers - NATIVE_PROVIDERS
    for name in custom_providers_needed:
        if name not in providers_config:
            print(f"ERROR: agent references provider '{name}' but it is not defined in config.yaml providers:")
            print(f"  Add a providers.{name} block with baseUrl, api, and models.")
            sys.exit(1)
        key_name = f"{name}_api_key"
        if key_name not in secrets:
            print(f"ERROR: provider '{name}' requires '{key_name}' in secrets.yaml")
            sys.exit(1)
        if not secrets[key_name] or secrets[key_name] == "REPLACE_ME":
            print(f"ERROR: '{key_name}' not set in secrets.yaml")
            sys.exit(1)

    # --- Validate Brave Search API key if web search is configured ---
    tools_web_cfg = config.get("tools", {}).get("web", {})
    brave_needed = (
        tools_web_cfg.get("search", {}).get("enabled", False) and
        tools_web_cfg.get("search", {}).get("provider", "") == "brave"
    )
    if brave_needed:
        brave_key = secrets.get("brave_search_api_key", "")
        if not brave_key or brave_key == "REPLACE_ME":
            print("ERROR: tools.web.search enabled with provider=brave but brave_search_api_key not set in secrets.yaml")
            print("  Sign up at https://api.search.brave.com (free tier: 2,000 queries/month)")
            sys.exit(1)
        # 6.8 preflight: brave web-search shipped as a separately-installed
        # plugin from 5.12 onward. Writing this config without the plugin
        # crash-loops the gateway with "web_search provider is not available".
        if not gateway_has_plugin("brave"):
            print("ERROR: tools.web.search.provider=brave but the 'brave' plugin is not installed in the gateway")
            print("  Install it, then re-run this script:")
            print("    docker exec openclaw-gateway node openclaw.mjs plugins install @openclaw/brave")
            print("  Or disable brave web search: set tools.web.search.enabled: false in config.yaml.")
            sys.exit(1)

    # --- Validate Anthropic key if needed ---
    if "anthropic" in needed_providers:
        api_key = secrets.get("anthropic_api_key", "")
        if not api_key or api_key == "REPLACE_ME":
            print("ERROR: anthropic_api_key not set in secrets.yaml")
            sys.exit(1)

    # --- Read current openclaw.json ---
    print("Reading openclaw.json from Docker volume...")
    try:
        ocjson = docker_read_json(VOLUME_NAME, "openclaw.json")
    except subprocess.CalledProcessError as e:
        print(f"ERROR: could not read openclaw.json — is Docker running and volume '{VOLUME_NAME}' present?")
        print(e.stderr)
        sys.exit(1)

    ocjson.setdefault("models", {})
    ocjson["models"].setdefault("providers", {})
    providers = ocjson["models"]["providers"]

    # --- Clean up stale native anthropic provider block ---
    if "anthropic" in providers:
        del providers["anthropic"]
        print("  Removed stale models.providers.anthropic block (using native support instead)")

    # --- Write custom provider blocks ---
    if custom_providers_needed:
        print("Registering custom providers...")
    for name in sorted(custom_providers_needed):
        provider_cfg = providers_config[name]
        api_key = secrets[f"{name}_api_key"]
        block = build_provider_block(name, provider_cfg, api_key)
        providers[name] = block
        model_ids = [m["id"] for m in block["models"]]
        print(f"  Provider '{name}': {len(model_ids)} model(s): {', '.join(model_ids)}")

    # --- Remove custom provider blocks that are no longer needed ---
    stale = [k for k in list(providers.keys()) if k not in NATIVE_PROVIDERS and k not in custom_providers_needed]
    for name in stale:
        del providers[name]
        print(f"  Removed stale provider block: '{name}'")

    # Clean up empty providers dict
    if not providers:
        del ocjson["models"]["providers"]
    if not ocjson["models"]:
        del ocjson["models"]

    # --- Manage ANTHROPIC_API_KEY in env ---
    ocjson.setdefault("env", {})
    if "anthropic" in needed_providers:
        ocjson["env"]["ANTHROPIC_API_KEY"] = secrets["anthropic_api_key"]
        print("  Set env.ANTHROPIC_API_KEY")
    else:
        if "ANTHROPIC_API_KEY" in ocjson["env"]:
            del ocjson["env"]["ANTHROPIC_API_KEY"]
            print("  Removed env.ANTHROPIC_API_KEY (no agents using Anthropic)")
    if not ocjson["env"]:
        del ocjson["env"]

    # --- Write global fallback model ---
    fallback_model = defaults_config.get("fallback_model", "").strip()
    ocjson.setdefault("agents", {}).setdefault("defaults", {})
    defaults = ocjson["agents"]["defaults"]
    if fallback_model:
        existing_primary = defaults.get("model", {})
        if isinstance(existing_primary, str):
            existing_primary = {"primary": existing_primary}
        existing_primary = dict(existing_primary) if existing_primary else {}
        existing_primary["fallbacks"] = [fallback_model]
        defaults["model"] = existing_primary
        print(f"Setting global fallback model: {fallback_model}")
    else:
        # Clear fallbacks if not configured
        if isinstance(defaults.get("model"), dict) and "fallbacks" in defaults["model"]:
            del defaults["model"]["fallbacks"]
            print("Cleared global fallback model (not set in config.yaml)")

    # --- Update per-agent model assignments ---
    print("Updating agent model assignments...")
    agents_list = ocjson.get("agents", {}).get("list", [])
    agent_ids_in_file = {a["id"] for a in agents_list}

    for agent_id, agent_cfg in agents_config.items():
        model_str = agent_cfg["model"]
        if agent_id not in agent_ids_in_file:
            print(f"  WARNING: agent '{agent_id}' not found in openclaw.json — skipping")
            continue
        for entry in agents_list:
            if entry["id"] == agent_id:
                entry["model"] = {"primary": model_str}
                # Handle per-agent tools deny list
                agent_tools_cfg = agent_cfg.get("tools", {})
                deny_list = agent_tools_cfg.get("deny", None)
                if deny_list is not None:
                    entry.setdefault("tools", {})["deny"] = deny_list
                    print(f"  {agent_id:12s} → {model_str}  (deny: {deny_list})")
                else:
                    print(f"  {agent_id:12s} → {model_str}")
                # Handle per-agent sandbox.browser.enabled
                sandbox_cfg = agent_cfg.get("sandbox", {})
                browser_sandbox = sandbox_cfg.get("browser", {})
                if "enabled" in browser_sandbox:
                    entry.setdefault("sandbox", {}).setdefault("browser", {})["enabled"] = browser_sandbox["enabled"]
                    if not browser_sandbox["enabled"]:
                        print(f"  {agent_id:12s}   sandbox.browser.enabled = false")
                break

    # --- Update Slack channel bindings ---
    channels_config = config.get("channels", [])
    if channels_config:
        print("Updating Slack channel bindings...")
        new_bindings = []
        for ch in channels_config:
            channel_id = ch.get("id", "")
            agent_id = ch.get("agent", "")
            name = ch.get("name", channel_id)
            if not channel_id or not agent_id:
                print(f"  WARNING: channel entry missing id or agent — skipping: {ch}")
                continue
            if agent_id not in agent_ids_in_file:
                print(f"  WARNING: agent '{agent_id}' for channel {name} not found in openclaw.json — skipping")
                continue
            new_bindings.append({
                "agentId": agent_id,
                "match": {
                    "channel": "slack",
                    "peer": {"kind": "channel", "id": channel_id}
                }
            })
            print(f"  {name} ({channel_id}) → {agent_id}")
        ocjson["bindings"] = new_bindings
        print(f"  {len(new_bindings)} binding(s) written (default agent handles DMs and unbound channels)")

        # Sync the Slack channel allowlist (channels.slack.channels).
        # Both bindings[] and this allowlist must include a channel for it to work.
        # 6.8 schema note: per-channel field is `enabled` (was `allow` in 4.2);
        # renamed by the 5.x SlackChannelSchema.strict() migration.
        slack_cfg = ocjson.get("channels", {}).get("slack", {})
        if slack_cfg:
            existing_slack_channels = slack_cfg.get("channels", {})
            new_slack_channels = {}
            for ch in channels_config:
                channel_id = ch.get("id", "")
                if not channel_id:
                    continue
                # Preserve existing per-channel settings (e.g. requireMention),
                # defaulting to enabled=True, requireMention=True for new entries.
                # Also migrate any legacy `allow` key on existing entries.
                existing = dict(existing_slack_channels.get(channel_id, {}))
                if "allow" in existing:
                    existing["enabled"] = existing.pop("allow")
                new_slack_channels[channel_id] = existing if existing else {
                    "enabled": True,
                    "requireMention": True,
                }
            slack_cfg["channels"] = new_slack_channels
            print(f"  Slack channel allowlist synced: {', '.join(new_slack_channels.keys())}")

            # 6.8 schema note: channels.slack.streaming must be an object per
            # SlackStreamingConfigSchema (was a bare boolean in 4.2). Migrate
            # any legacy boolean value to the new shape without changing intent.
            streaming = slack_cfg.get("streaming")
            if isinstance(streaming, bool):
                slack_cfg["streaming"] = {"mode": "block" if streaming else "off"}
                print(f"  Migrated channels.slack.streaming: {streaming} -> {slack_cfg['streaming']}")

        # 6.8 schema note: bindings[].agentId is cross-validated against
        # agents.list. Drop bindings that point at agents not present in the
        # active list (e.g. hibernated agents commented out in config.yaml)
        # so the gateway doesn't crash-loop on startup.
        active_agent_ids = {a["id"] for a in ocjson.get("agents", {}).get("list", [])}
        pruned = [b for b in ocjson["bindings"] if b.get("agentId") in active_agent_ids]
        if len(pruned) != len(ocjson["bindings"]):
            dropped = {b.get("agentId") for b in ocjson["bindings"]} - active_agent_ids
            print(f"  Dropped bindings for inactive agents: {', '.join(sorted(dropped))}")
            ocjson["bindings"] = pruned
    else:
        print("No channels section in config.yaml — leaving bindings unchanged")

    # --- Generate /shared/CHANNELS.md ---
    # Single source of truth for channel IDs readable by all agent sandboxes.
    # Agents reference /shared/CHANNELS.md; never hardcode channel IDs in PATHS.md.
    if channels_config:
        env_vars = read_env_file(ENV_PATH)
        workspace = env_vars.get("OPENCLAW_WORKSPACE", "").strip()
        if workspace:
            channels_md_path = os.path.join(workspace, "shared", "CHANNELS.md")
            now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
            lines = [
                "# CHANNELS.md — Slack Channel Reference",
                "",
                "Auto-generated by `apply-config.sh` from `config.yaml`.",
                "**Do not edit** — this file is overwritten on every `apply-config.sh` run.",
                f"Last updated: {now}",
                "",
                "| Channel | ID | Agent |",
                "|---|---|---|",
            ]
            for ch in channels_config:
                name = ch.get("name", ch.get("id", "?"))
                ch_id = ch.get("id", "?")
                agent = ch.get("agent", "?")
                lines.append(f"| {name} | `{ch_id}` | {agent} |")
            lines.append("")
            content = "\n".join(lines)
            if dry_run:
                print(f"\n[dry-run] Would write {channels_md_path}:")
                print(content)
            else:
                os.makedirs(os.path.dirname(channels_md_path), exist_ok=True)
                with open(channels_md_path, "w") as f:
                    f.write(content)
                print(f"  Generated {channels_md_path}")
        else:
            print("  WARNING: OPENCLAW_WORKSPACE not set in openclaw/.env — skipping CHANNELS.md generation")

    # --- Write web tools config ---
    tools_config = config.get("tools", {})
    web_config = tools_config.get("web", {})

    if web_config:
        print("Configuring web tools...")
        ocjson.setdefault("tools", {}).setdefault("web", {})

        search_cfg = web_config.get("search", {})
        if search_cfg.get("enabled", False):
            provider = search_cfg.get("provider", "")
            if provider == "brave":
                brave_key = secrets.get("brave_search_api_key", "")
                ocjson["tools"]["web"]["search"] = {
                    "enabled": True,
                    "provider": "brave",
                    "apiKey": brave_key,
                }
                print("  web_search: enabled (provider: brave)")
            else:
                print(f"  WARNING: unknown search provider '{provider}' -- skipping")
        else:
            web_tools = ocjson.get("tools", {}).get("web", {})
            if "search" in web_tools:
                del web_tools["search"]
            print("  web_search: disabled")

        fetch_cfg = web_config.get("fetch", {})
        if fetch_cfg.get("enabled", False):
            ocjson["tools"]["web"]["fetch"] = {"enabled": True}
            print("  web_fetch: enabled")
        else:
            web_tools = ocjson.get("tools", {}).get("web", {})
            if "fetch" in web_tools:
                del web_tools["fetch"]
            print("  web_fetch: disabled")

    # --- Write browser config ---
    # 6.8 schema note: browser.ssrfPolicy is a .strict() object with keys
    # `dangerouslyAllowPrivateNetwork` / `allowedHostnames` / `hostnameAllowlist`.
    # The 4.2-era `allowPrivateNetwork` key is rejected. This block migrates the
    # legacy name from config.yaml transparently so upgrading the doc is optional.
    browser_config = config.get("browser", {})
    if browser_config.get("enabled", False):
        print("Configuring browser tool...")
        browser_block = {"enabled": True}

        ssrf_policy = dict(browser_config.get("ssrfPolicy", {}) or {})
        if "allowPrivateNetwork" in ssrf_policy:
            ssrf_policy["dangerouslyAllowPrivateNetwork"] = ssrf_policy.pop("allowPrivateNetwork")
            print("  Migrated ssrfPolicy.allowPrivateNetwork -> dangerouslyAllowPrivateNetwork")
        if ssrf_policy:
            browser_block["ssrfPolicy"] = ssrf_policy

        ocjson["browser"] = browser_block
        allow_private = ssrf_policy.get("dangerouslyAllowPrivateNetwork", False)
        print(f"  browser: enabled  ssrfPolicy.dangerouslyAllowPrivateNetwork = {str(allow_private).lower()}")
    elif "browser" in browser_config or not browser_config:
        # browser: block absent from config — leave openclaw.json browser section untouched
        pass

    # --- Write MCP server config ---
    # If mcp: is absent from config.yaml entirely, leave openclaw.json untouched.
    # If mcp: is present, replace mcp.servers completely (config.yaml is authoritative).
    if "mcp" in config:
        mcp_servers_cfg = config.get("mcp", {}).get("servers", {})
        if mcp_servers_cfg:
            print("Configuring MCP servers...")
            new_mcp_servers = {}
            for server_name, server_cfg in mcp_servers_cfg.items():
                url = server_cfg.get("url", "")
                if not url:
                    print(f"  ERROR: MCP server '{server_name}' missing required 'url' field")
                    sys.exit(1)

                block = {"url": url}

                transport = server_cfg.get("transport", "streamable-http")
                block["transport"] = transport

                auth_cfg = server_cfg.get("auth", {})
                if auth_cfg:
                    token_secret_key = auth_cfg.get("token_secret", "")
                    if not token_secret_key:
                        print(f"  ERROR: MCP server '{server_name}' auth block missing 'token_secret'")
                        sys.exit(1)
                    token = secrets.get(token_secret_key, "")
                    if not token or token == "REPLACE_ME":
                        print(f"  ERROR: MCP server '{server_name}': '{token_secret_key}' not found or not set in secrets.yaml")
                        sys.exit(1)

                    token_format = auth_cfg.get("token_format", "Bearer {token}")
                    if "{token}" not in token_format:
                        print(f"  ERROR: MCP server '{server_name}' token_format must contain '{{token}}' placeholder")
                        sys.exit(1)

                    username = auth_cfg.get("username", "")
                    auth_value = token_format.format(token=token, username=username)
                    block["headers"] = {"Authorization": auth_value}

                    display = token_format.format(token="<redacted>", username=username)
                    print(f"  {server_name}: {url}  auth: {display}")
                else:
                    print(f"  {server_name}: {url}  (no auth)")

                new_mcp_servers[server_name] = block

            ocjson.setdefault("mcp", {})["servers"] = new_mcp_servers
            print(f"  {len(new_mcp_servers)} MCP server(s) written: {', '.join(new_mcp_servers.keys())}")
        else:
            # mcp: present but servers: is empty — clear the block
            if "mcp" in ocjson:
                del ocjson["mcp"]
                print("MCP servers: none configured — cleared mcp block from openclaw.json")

    # --- Write back ---
    if dry_run:
        print("\n[dry-run] Would write openclaw.json:")
        print(json.dumps(ocjson, indent=2))
        print("\n[dry-run] Would restart openclaw-gateway")
        return

    print("Writing openclaw.json...")
    docker_write_json(VOLUME_NAME, "openclaw.json", ocjson)

    print("Restarting openclaw-gateway...")
    restart_gateway()

    # --- Post-restart health check ---
    crashed, reason = watch_for_crash_loop()
    if crashed:
        print(f"\nWARNING: crash-loop detected ({reason})")
        print("  Auto-reverting to local vLLM model via revert-to-local.sh ...")
        subprocess.run([sys.executable, REVERT_SCRIPT], check=True)
        print("\nGateway restored to local vLLM model.")
        print("Fix the config error above, then re-run ./apply-config.sh.")
        sys.exit(1)

    print("  Gateway looks healthy.")
    print("\nDone. Agents are now using:")
    for agent_id, agent_cfg in agents_config.items():
        print(f"  {agent_id:12s}  {agent_cfg['model']}")
    if fallback_model:
        print(f"  (fallback)    {fallback_model}")
    if channels_config:
        print("\nSlack channel bindings:")
        for ch in channels_config:
            print(f"  {ch.get('name', ch.get('id')):20s}  → {ch.get('agent')}")


if __name__ == "__main__":
    main()
