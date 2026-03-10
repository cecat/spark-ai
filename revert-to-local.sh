#!/usr/bin/env python3
"""
revert-to-local.sh — Emergency fallback: restore all agents to local vLLM model.

Removes Anthropic config from openclaw.json and restarts the gateway.
No config.yaml or secrets.yaml needed — run this any time things go wrong.

Usage:
    ./revert-to-local.sh
"""

import json
import subprocess
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_FILE = os.path.join(SCRIPT_DIR, "openclaw", "docker-compose.yml")
VOLUME_NAME = "openclaw_openclaw-config"


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


def main():
    print("Reading openclaw.json from Docker volume...")
    try:
        ocjson = docker_read_json(VOLUME_NAME, "openclaw.json")
    except subprocess.CalledProcessError as e:
        print(f"ERROR: could not read openclaw.json — is Docker running?")
        print(e.stderr)
        sys.exit(1)

    # Remove Anthropic API key from env section
    if "ANTHROPIC_API_KEY" in ocjson.get("env", {}):
        del ocjson["env"]["ANTHROPIC_API_KEY"]
        print("  Removed env.ANTHROPIC_API_KEY")
    if ocjson.get("env") == {}:
        del ocjson["env"]

    # Remove any stale models.providers.anthropic block
    providers = ocjson.get("models", {}).get("providers", {})
    if "anthropic" in providers:
        del providers["anthropic"]
        print("  Removed models.providers.anthropic block")

    # Remove per-agent model overrides so agents fall back to defaults (vllm/Qwen)
    for agent in ocjson.get("agents", {}).get("list", []):
        if "model" in agent:
            del agent["model"]
            print(f"  Agent '{agent['id']}' → reverted to default (vllm/Qwen/Qwen3-Coder-Next-FP8)")

    print("Writing openclaw.json...")
    docker_write_json(VOLUME_NAME, "openclaw.json", ocjson)

    print("Restarting openclaw-gateway...")
    subprocess.run(
        ["docker", "compose", "-f", COMPOSE_FILE, "restart", "openclaw-gateway"],
        check=True,
    )

    print("\nDone. All agents are back on local vLLM model.")
    print("Verify with: docker logs openclaw-gateway --tail 20")


if __name__ == "__main__":
    main()
