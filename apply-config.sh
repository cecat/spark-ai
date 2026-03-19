#!/usr/bin/env python3
"""
apply-config.sh — Apply agent configuration to the OpenClaw gateway.

Reads config.yaml and secrets.yaml, patches openclaw.json in the Docker volume,
and restarts the gateway.

Usage:
    ./apply-config.sh [--dry-run]

Requirements:
    pip install --break-system-packages pyyaml

Manages two sections of openclaw.json:

  Model assignments (config.yaml agents:):
    - Anthropic: native support — API key goes in openclaw.json env.ANTHROPIC_API_KEY,
      no providers block needed. Model format: anthropic/claude-sonnet-4-6
      Ref: https://docs.openclaw.ai/providers/anthropic
    - vLLM: custom provider block under models.providers.vllm (already configured
      via the onboarding wizard — this script does not touch it)

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
HEALTH_CHECK_SECONDS = 20      # how long to watch logs after restart
HEALTH_POLL_INTERVAL = 3       # seconds between log checks

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
    "ZodError",           # Zod schema validation failure
    "Cannot find module", # JS import failure (misconfigured provider module)
    "SyntaxError",        # malformed JSON passed to the gateway
]


def watch_for_crash_loop(timeout=HEALTH_CHECK_SECONDS, poll=HEALTH_POLL_INTERVAL):
    """
    Poll openclaw-gateway logs for `timeout` seconds looking for config errors.
    Returns (crashed: bool, evidence: str).
    Ctrl-C skips the check without triggering a revert.
    """
    # Capture a baseline timestamp so --since only returns post-restart logs
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


# ---------------------------------------------------------------------------

def main():
    dry_run = "--dry-run" in sys.argv

    # --- Load config and secrets ---
    for path, label in [(CONFIG_PATH, "config.yaml"), (SECRETS_PATH, "secrets.yaml")]:
        if not os.path.exists(path):
            print(f"ERROR: {label} not found at {path}")
            if label == "secrets.yaml":
                print("       Copy secrets.yaml.example → secrets.yaml and fill in your API key.")
            sys.exit(1)

    config = load_yaml(CONFIG_PATH)
    secrets = load_yaml(SECRETS_PATH)

    agents_config = config.get("agents", {})
    if not agents_config:
        print("ERROR: no agents defined in config.yaml")
        sys.exit(1)

    # --- Determine which providers are needed ---
    needed_providers = set()
    for agent_id, agent_cfg in agents_config.items():
        model_str = agent_cfg.get("model", "")
        if "/" not in model_str:
            print(f"ERROR: agent '{agent_id}' model must be 'provider/model-id', got: '{model_str}'")
            sys.exit(1)
        needed_providers.add(model_str.split("/")[0])

    # --- Validate secrets ---
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

    # --- Clean up any stale custom anthropic provider block (not needed for native support) ---
    providers = ocjson.get("models", {}).get("providers", {})
    if "anthropic" in providers:
        del providers["anthropic"]
        print("  Removed stale models.providers.anthropic block (using native support instead)")

    # --- Manage ANTHROPIC_API_KEY in openclaw.json env section ---
    ocjson.setdefault("env", {})
    if "anthropic" in needed_providers:
        ocjson["env"]["ANTHROPIC_API_KEY"] = secrets["anthropic_api_key"]
        print("  Set env.ANTHROPIC_API_KEY")
    else:
        if "ANTHROPIC_API_KEY" in ocjson["env"]:
            del ocjson["env"]["ANTHROPIC_API_KEY"]
            print("  Removed env.ANTHROPIC_API_KEY (no agents using Anthropic)")
        if not ocjson["env"]:
            del ocjson["env"]  # clean up empty env block

    # --- Update per-agent model assignments ---
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
                print(f"  Agent '{agent_id}' → {model_str}")
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
