#!/usr/bin/env python3
"""
apply-config.sh — Apply agent configuration to the OpenClaw gateway.

Reads config.yaml and secrets.yaml, patches openclaw.json in the Docker volume,
and restarts the gateway.

Usage:
    ./apply-config.sh [--dry-run]

Requirements:
    pip install --break-system-packages pyyaml

Manages three sections of openclaw.json:

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

  Slack channel bindings (config.yaml channels:):
    - Replaces the entire bindings[] array in openclaw.json with the list from
      config.yaml; each entry maps a Slack channel ID to an agent
    - The default agent (marked "default": true in openclaw.json agents.list) handles
      all DMs and any channel not in the bindings list
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
                print(f"  {agent_id:12s} → {model_str}")
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
    else:
        print("No channels section in config.yaml — leaving bindings unchanged")

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
    if channels_config:
        print("\nSlack channel bindings:")
        for ch in channels_config:
            print(f"  {ch.get('name', ch.get('id')):20s}  → {ch.get('agent')}")


if __name__ == "__main__":
    main()
