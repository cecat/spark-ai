#!/usr/bin/env python3
"""
apply-config.sh — Apply agent model assignments to the OpenClaw gateway.

Reads config.yaml and secrets.yaml, patches openclaw.json in the Docker volume,
and restarts the gateway.

Usage:
    ./apply-config.sh [--dry-run]

Requirements:
    pip install --break-system-packages pyyaml
"""

import json
import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(SCRIPT_DIR, "config.yaml")
SECRETS_PATH = os.path.join(SCRIPT_DIR, "secrets.yaml")
COMPOSE_FILE = os.path.join(SCRIPT_DIR, "openclaw", "docker-compose.yml")
VOLUME_NAME = "openclaw_openclaw-config"

# Anthropic models to register in openclaw.json when the anthropic provider is used.
# Extend this list as Anthropic releases new models.
ANTHROPIC_MODELS = [
    {"id": "claude-haiku-4-5",  "name": "claude-haiku-4-5",  "contextWindow": 200000, "maxTokens": 8192},
    {"id": "claude-sonnet-4-6", "name": "claude-sonnet-4-6", "contextWindow": 200000, "maxTokens": 8192},
    {"id": "claude-opus-4-6",   "name": "claude-opus-4-6",   "contextWindow": 200000, "maxTokens": 32768},
]

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

    # --- Ensure models structure exists ---
    ocjson.setdefault("models", {})
    ocjson["models"].setdefault("mode", "merge")
    ocjson["models"].setdefault("providers", {})
    providers = ocjson["models"]["providers"]

    # --- Add/update anthropic provider ---
    if "anthropic" in needed_providers:
        providers["anthropic"] = {
            "apiKey": secrets["anthropic_api_key"],
            "api": "anthropic",
            "models": [
                {
                    "id": m["id"],
                    "name": m["name"],
                    "reasoning": False,
                    "input": ["text"],
                    "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
                    "contextWindow": m["contextWindow"],
                    "maxTokens": m["maxTokens"],
                }
                for m in ANTHROPIC_MODELS
            ],
        }
        print("  Updated anthropic provider (API key set, models registered)")

    # Remove anthropic provider if no longer needed
    if "anthropic" not in needed_providers and "anthropic" in providers:
        del providers["anthropic"]
        print("  Removed anthropic provider (no agents using it)")

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

    print("\nDone. Agents are now using:")
    for agent_id, agent_cfg in agents_config.items():
        print(f"  {agent_id:12s}  {agent_cfg['model']}")


if __name__ == "__main__":
    main()
