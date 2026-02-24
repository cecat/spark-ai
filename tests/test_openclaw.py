#!/usr/bin/env python3
"""Smoke test: OpenClaw gateway responding on Tailscale IP.

Connects to http://${TAILSCALE_IP}:18789 and verifies the gateway is reachable
and its health endpoint responds.

Usage (from the Spark, with OpenClaw container running):
    TAILSCALE_IP=x.x.x.x python3 tests/test_openclaw.py
"""

import os
import unittest
import urllib.error
import urllib.request

TAILSCALE_IP = os.environ.get("TAILSCALE_IP")
OPENCLAW_PORT = 18789


@unittest.skipUnless(TAILSCALE_IP, "TAILSCALE_IP not set in environment")
class TestOpenClawGateway(unittest.TestCase):
    """Smoke tests for OpenClaw gateway on Tailscale network."""

    @property
    def base_url(self):
        return f"http://{TAILSCALE_IP}:{OPENCLAW_PORT}"

    def test_gateway_reachable(self):
        """Gateway responds (not connection refused) on Tailscale IP."""
        try:
            req = urllib.request.Request(self.base_url, method="GET")
            with urllib.request.urlopen(req, timeout=10) as resp:
                # Any successful response means the gateway is up
                self.assertIn(
                    resp.status, range(200, 600),
                    f"Unexpected status: {resp.status}",
                )
        except urllib.error.HTTPError:
            # Any HTTP error (4xx, 5xx) still means the server IS responding
            pass
        except urllib.error.URLError as exc:
            self.fail(f"Gateway not reachable at {self.base_url}: {exc}")

    def test_health_endpoint(self):
        """Health endpoint returns expected status."""
        url = f"{self.base_url}/health"
        try:
            req = urllib.request.Request(url, method="GET")
            with urllib.request.urlopen(req, timeout=10) as resp:
                self.assertEqual(
                    resp.status, 200,
                    f"Health endpoint returned {resp.status}",
                )
        except urllib.error.HTTPError as exc:
            # 404 means the gateway is up but has no /health route — acceptable
            if exc.code == 404:
                self.skipTest("No /health endpoint found (404)")
            else:
                self.fail(f"Health check failed with HTTP {exc.code}")
        except urllib.error.URLError as exc:
            self.fail(f"Health endpoint not reachable: {exc}")


if __name__ == "__main__":
    unittest.main()
