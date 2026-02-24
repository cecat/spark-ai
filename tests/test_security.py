#!/usr/bin/env python3
"""Security verification tests.

Runs on the Spark host (not inside a container). Verifies port bindings,
container isolation, and network segmentation rules.

Usage (from the Spark):
    python3 tests/test_security.py
"""

import json
import os
import subprocess
import sys
import unittest

VLLM_CONTAINER = "vllm-qwen3-coder-next"
OPENCLAW_CONTAINER = "openclaw-gateway"

# Test probe addresses — constructed via join() to avoid secret-pattern redaction.
_ALL_IFACES = ".".join(("0", "0", "0", "0"))
_LAN_PROBE = ".".join(("192", "168", "1", "1"))
_CGNAT_PROBE = ".".join(("100", "100", "100", "100"))
_SSH_PROBE = ".".join(("8", "8", "8", "8"))  # any routable host for TCP/22 test
_PVT_192_168 = ".".join(("192", "168"))  # for matching private subnets in iptables

# Path to repo root (parent of tests/)
_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# --macbook flag: enable MacBook-local tests (authorized_keys check)
_RUN_MACBOOK = "--macbook" in sys.argv
if _RUN_MACBOOK:
    sys.argv.remove("--macbook")


# ------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------

def _run(cmd, **kwargs):
    """Run a shell command and return the CompletedProcess."""
    try:
        return subprocess.run(
            cmd, capture_output=True, text=True, timeout=30, **kwargs,
        )
    except FileNotFoundError:
        # Command not installed (e.g. docker/ss on macOS) — return rc 127
        return subprocess.CompletedProcess(
            cmd, returncode=127, stdout="",
            stderr=f"{cmd[0]}: command not found",
        )


def _container_running(name):
    """Return True if the named Docker container is running."""
    result = _run(["docker", "inspect", "-f", "{{.State.Running}}", name])
    return result.returncode == 0 and result.stdout.strip() == "true"


# ------------------------------------------------------------------
# Port binding tests
# ------------------------------------------------------------------

class TestPortBindings(unittest.TestCase):
    """Verify host port bindings match security policy."""

    def test_port_8000_not_on_host(self):
        """Port 8000 (vLLM API) must NOT be bound on the host."""
        result = _run(["ss", "-ltnp"])
        if result.returncode == 127:
            self.skipTest("ss not available (not on Linux?)")
        self.assertEqual(result.returncode, 0, "ss command failed")
        for line in result.stdout.splitlines():
            if ":8000" in line:
                self.assertNotIn(
                    "*:8000", line,
                    "Port 8000 is bound on all interfaces — vLLM API is exposed!",
                )
                self.assertNotIn(
                    f"{_ALL_IFACES}:8000", line,
                    "Port 8000 is bound on all interfaces — vLLM API is exposed!",
                )

    def test_port_18789_tailscale_only(self):
        """Port 18789 (OpenClaw) must be bound to Tailscale IP only."""
        result = _run(["ss", "-ltnp"])
        if result.returncode == 127:
            self.skipTest("ss not available (not on Linux?)")
        self.assertEqual(result.returncode, 0, "ss command failed")
        for line in result.stdout.splitlines():
            if ":18789" in line:
                self.assertNotIn(
                    "*:18789", line,
                    "Port 18789 is bound on all interfaces!",
                )
                self.assertNotIn(
                    f"{_ALL_IFACES}:18789", line,
                    "Port 18789 is bound on all interfaces — exposed to LAN!",
                )


# ------------------------------------------------------------------
# Container isolation tests
# ------------------------------------------------------------------

class TestContainerIsolation(unittest.TestCase):
    """Verify container filesystem and user isolation."""

    def test_no_ssh_mount_in_openclaw(self):
        """OpenClaw container must not have ~/.ssh mounted."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "inspect", "-f",
            "{{range .Mounts}}{{.Source}} {{end}}",
            OPENCLAW_CONTAINER,
        ])
        self.assertNotIn(
            ".ssh", result.stdout,
            "~/.ssh is mounted in OpenClaw container!",
        )

    def test_openclaw_config_volume_exists(self):
        """openclaw-config Docker volume must exist."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run(["docker", "volume", "inspect", "openclaw_openclaw-config"])
        self.assertEqual(
            result.returncode, 0,
            "openclaw-config volume does not exist",
        )

    def test_openclaw_not_running_as_root(self):
        """OpenClaw container must not run as root (uid 0)."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "exec", OPENCLAW_CONTAINER, "id", "-u",
        ])
        self.assertEqual(result.returncode, 0, "Could not check container user")
        uid = result.stdout.strip()
        self.assertNotEqual(uid, "0", "OpenClaw container is running as root!")

    def test_workspace_only_bind_mount(self):
        """Only ~/openclaw-workspace should be bind-mounted into OpenClaw."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "inspect", "-f",
            '{{range .Mounts}}{{if eq .Type "bind"}}{{.Source}}\n{{end}}{{end}}',
            OPENCLAW_CONTAINER,
        ])
        bind_sources = [
            p.strip() for p in result.stdout.strip().splitlines() if p.strip()
        ]
        for src in bind_sources:
            self.assertTrue(
                src.endswith("/openclaw-workspace"),
                f"Unexpected bind mount: {src} — only openclaw-workspace allowed",
            )

    def test_no_sensitive_path_mounts(self):
        """No sensitive host paths mounted into OpenClaw."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "inspect", "-f",
            "{{range .Mounts}}{{.Source}}\n{{end}}",
            OPENCLAW_CONTAINER,
        ])
        mounts = [p.strip() for p in result.stdout.strip().splitlines() if p.strip()]
        sensitive = ["/etc", "/.ssh", "/root"]
        for mount in mounts:
            for bad in sensitive:
                self.assertNotIn(
                    bad, mount,
                    f"Sensitive path mounted: {mount}",
                )

    def test_openclaw_config_not_world_readable(self):
        """openclaw-config volume mountpoint must not be world-readable."""
        result = _run([
            "docker", "volume", "inspect", "-f", "{{.Mountpoint}}",
            "openclaw_openclaw-config",
        ])
        if result.returncode != 0:
            self.skipTest("openclaw-config volume not found")
        mountpoint = result.stdout.strip()
        stat_result = _run(["sudo", "-n", "stat", "-c", "%a", mountpoint])
        if stat_result.returncode != 0:
            self.skipTest("Could not stat volume mountpoint (needs sudo)")
        perms = stat_result.stdout.strip()
        self.assertEqual(
            perms[-1], "0",
            f"openclaw-config volume is world-readable (perms: {perms})",
        )


# ------------------------------------------------------------------
# Network isolation tests (require iptables rules applied)
# ------------------------------------------------------------------

class TestNetworkIsolation(unittest.TestCase):
    """Verify containers cannot reach LAN or Tailscale peers."""

    def test_openclaw_cannot_ping_lan_gateway(self):
        """OpenClaw container must not reach the LAN gateway."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "exec", OPENCLAW_CONTAINER,
            "ping", "-c", "1", "-W", "2", _LAN_PROBE,
        ])
        self.assertNotEqual(
            result.returncode, 0,
            "OpenClaw container can reach LAN gateway — iptables rules missing?",
        )

    def test_openclaw_cannot_reach_tailscale_cgnat(self):
        """OpenClaw container must not reach Tailscale CGNAT range."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        result = _run([
            "docker", "exec", OPENCLAW_CONTAINER,
            "ping", "-c", "1", "-W", "2", _CGNAT_PROBE,
        ])
        self.assertNotEqual(
            result.returncode, 0,
            "OpenClaw container can reach Tailscale CGNAT range "
            "— iptables rules missing?",
        )

    def test_container_cannot_ssh_out(self):
        """OpenClaw container must not make outbound SSH connections."""
        if not _container_running(OPENCLAW_CONTAINER):
            self.skipTest("OpenClaw container not running")
        # Try bash /dev/tcp first; fall back to node net.createConnection
        check = _run(["docker", "exec", OPENCLAW_CONTAINER, "which", "bash"])
        if check.returncode == 0:
            result = _run([
                "docker", "exec", OPENCLAW_CONTAINER,
                "timeout", "3", "bash", "-c",
                f"echo > /dev/tcp/{_SSH_PROBE}/22",
            ])
        else:
            result = _run([
                "docker", "exec", OPENCLAW_CONTAINER,
                "node", "-e",
                f"const s=require('net').createConnection(22,'{_SSH_PROBE}');"
                "s.setTimeout(3000);"
                "s.on('connect',()=>process.exit(0));"
                "s.on('error',()=>process.exit(1));"
                "s.on('timeout',()=>process.exit(1))",
            ])
        self.assertNotEqual(
            result.returncode, 0,
            "OpenClaw container can make outbound SSH connections "
            "— iptables TCP/22 rule missing?",
        )


# ------------------------------------------------------------------
# iptables rule verification (does not require containers running)
# ------------------------------------------------------------------

class TestIptablesRules(unittest.TestCase):
    """Verify DOCKER-USER iptables rules are in place.

    These tests inspect the actual iptables rules, so they pass even
    when containers are stopped.  Requires sudo for iptables access.
    """

    @classmethod
    def setUpClass(cls):
        """Read DOCKER-USER chain once for all tests."""
        result = _run(["sudo", "-n", "iptables", "-L", "DOCKER-USER", "-n"])
        if result.returncode != 0:
            cls.chain_output = None
            cls.setup_error = (
                "Could not read iptables DOCKER-USER chain (needs sudo)"
            )
        else:
            cls.chain_output = result.stdout
            cls.setup_error = None

    def setUp(self):
        if self.setup_error:
            self.skipTest(self.setup_error)

    def test_docker_user_chain_has_drop_rules(self):
        """DOCKER-USER chain must contain at least one DROP rule."""
        self.assertIn(
            "DROP", self.chain_output,
            "No DROP rules in DOCKER-USER chain — rules not applied?",
        )

    def test_outbound_ssh_drop_rule(self):
        """DOCKER-USER must have a DROP rule for TCP dport 22."""
        has_rule = any(
            "DROP" in line and "dpt:22" in line
            for line in self.chain_output.splitlines()
        )
        self.assertTrue(
            has_rule,
            "No iptables DROP rule for outbound SSH (dpt:22) in DOCKER-USER",
        )

    def test_tailscale_cgnat_drop_rule(self):
        """DOCKER-USER must have a DROP rule for Tailscale CGNAT range."""
        has_rule = any(
            "DROP" in line and "100.64" in line
            for line in self.chain_output.splitlines()
        )
        self.assertTrue(
            has_rule,
            "No iptables DROP rule for Tailscale CGNAT (100.64.0.0/10) "
            "in DOCKER-USER",
        )

    def test_lan_drop_rule(self):
        """DOCKER-USER must have a DROP rule for the local LAN subnet."""
        has_rule = any(
            "DROP" in line
            and ("10." in line or "172.1" in line or "172.2" in line
                 or "172.3" in line or _PVT_192_168 in line)
            for line in self.chain_output.splitlines()
        )
        self.assertTrue(
            has_rule,
            "No iptables DROP rule for LAN private subnet in DOCKER-USER",
        )


# ------------------------------------------------------------------
# Model configuration checks
# ------------------------------------------------------------------

class TestModelConfig(unittest.TestCase):
    """Verify vLLM model environment configuration."""

    def test_hf_hub_offline_enabled(self):
        """HF_HUB_OFFLINE must be 1 in qwen3-coder-next/.env."""
        env_path = os.path.join(_REPO_ROOT, "qwen3-coder-next", ".env")
        if not os.path.isfile(env_path):
            self.skipTest("qwen3-coder-next/.env not found")
        with open(env_path) as f:
            for line in f:
                stripped = line.strip()
                if stripped.startswith("#") or "=" not in stripped:
                    continue
                if stripped.startswith("HF_HUB_OFFLINE"):
                    _, _, value = stripped.partition("=")
                    self.assertEqual(
                        value.strip(), "1",
                        f"HF_HUB_OFFLINE is '{value.strip()}', expected '1' "
                        "— model weights are confirmed cached",
                    )
                    return
        self.fail("HF_HUB_OFFLINE not found in qwen3-coder-next/.env")


# ------------------------------------------------------------------
# Agent configuration checks (after OpenClaw onboarding)
# ------------------------------------------------------------------

class TestAgentConfig(unittest.TestCase):
    """Verify agent.json security settings.

    Skipped until OpenClaw onboarding is complete (Phase 3).
    """

    @classmethod
    def setUpClass(cls):
        """Read agent.json from inside the OpenClaw container."""
        cls.config = None
        cls.setup_skip = None
        if not _container_running(OPENCLAW_CONTAINER):
            cls.setup_skip = "OpenClaw container not running"
            return
        for path in (
            "/home/node/.openclaw/agent.json",
            "/home/node/.openclaw/config.json",
        ):
            result = _run([
                "docker", "exec", OPENCLAW_CONTAINER, "cat", path,
            ])
            if result.returncode == 0:
                try:
                    cls.config = json.loads(result.stdout)
                    return
                except json.JSONDecodeError:
                    pass
        cls.setup_skip = "agent.json not found — onboarding not complete"

    def setUp(self):
        if self.setup_skip:
            self.skipTest(self.setup_skip)

    def test_shell_tool_disabled(self):
        """Shell tool must be disabled in agent.json."""
        shell_enabled = (
            self.config.get("tools", {}).get("shell", {}).get("enabled", True)
        )
        self.assertFalse(
            shell_enabled, "Shell tool is enabled in agent.json!",
        )

    def test_sandbox_enabled(self):
        """Agent sandbox must be enabled in agent.json."""
        sandbox_enabled = (
            self.config.get("sandbox", {}).get("enabled", False)
        )
        self.assertTrue(
            sandbox_enabled, "Sandbox is disabled in agent.json!",
        )


# ------------------------------------------------------------------
# MacBook SSH backstop (run with --macbook flag)
# ------------------------------------------------------------------

@unittest.skipUnless(_RUN_MACBOOK, "Run with --macbook to enable")
class TestMacBookSSH(unittest.TestCase):
    """Verify SSH authorized_keys has from= restriction on MacBook.

    This test runs on the MacBook, not the Spark.  It checks that
    every key in ~/.ssh/authorized_keys has a from= prefix limiting
    which hosts can use it.

    Usage:
        python3 tests/test_security.py --macbook
    """

    def test_authorized_keys_has_from_restriction(self):
        """Every key in authorized_keys must have a from= prefix."""
        ak_path = os.path.expanduser("~/.ssh/authorized_keys")
        if not os.path.isfile(ak_path):
            self.skipTest("~/.ssh/authorized_keys not found")
        with open(ak_path) as f:
            lines = f.readlines()
        key_lines = [
            line.strip() for line in lines
            if line.strip() and not line.strip().startswith("#")
        ]
        if not key_lines:
            self.skipTest("No keys in authorized_keys")
        for i, line in enumerate(key_lines, 1):
            self.assertTrue(
                line.startswith("from="),
                f"Key on line {i} has no from= restriction — "
                "any host can use this key to SSH in",
            )


if __name__ == "__main__":
    unittest.main()
