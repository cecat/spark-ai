#!/usr/bin/env python3
"""Smoke test: vLLM endpoint reachable from Docker network.

Spins up a temporary container on qwen3-coder-next_nim_net, sends a minimal
prompt to http://nim:8000/v1/chat/completions, and validates the response.

Usage (from the Spark, with vLLM container running):
    python3 tests/test_vllm.py
"""

import json
import subprocess
import time
import unittest

DOCKER_NETWORK = "qwen3-coder-next_nim_net"
VLLM_URL = "http://nim:8000/v1/chat/completions"
EXPECTED_MODEL = "Qwen/Qwen3-Coder-Next-FP8"
TIMEOUT_SECONDS = 120  # generous — first request after model load may be slow


class TestVLLMEndpoint(unittest.TestCase):
    """Smoke tests for vLLM inference endpoint via Docker network."""

    response = None
    http_status = None
    elapsed = None
    setup_error = None

    @classmethod
    def setUpClass(cls):
        """Send a single inference request via a temporary Docker container."""
        payload = {
            "model": EXPECTED_MODEL,
            "messages": [{"role": "user", "content": "Say hello in one sentence."}],
            "max_tokens": 32,
        }
        cmd = [
            "docker", "run", "--rm",
            "--network", DOCKER_NETWORK,
            "curlimages/curl:latest",
            "-s", "-S",
            "-w", "\n%{http_code}",
            "--max-time", str(TIMEOUT_SECONDS),
            "-H", "Content-Type: application/json",
            "-d", json.dumps(payload),
            VLLM_URL,
        ]
        try:
            start = time.time()
            result = subprocess.run(
                cmd, capture_output=True, text=True,
                timeout=TIMEOUT_SECONDS + 30,
            )
            cls.elapsed = time.time() - start

            if result.returncode != 0:
                cls.setup_error = (
                    f"curl failed (rc={result.returncode}): {result.stderr}"
                )
                return

            # curl -w "\n%{{http_code}}" appends the status code on the last line
            lines = result.stdout.rsplit("\n", 1)
            body = lines[0]
            cls.http_status = int(lines[1]) if len(lines) > 1 else None
            cls.response = json.loads(body)

        except subprocess.TimeoutExpired:
            cls.setup_error = "Docker curl command timed out"
        except json.JSONDecodeError as exc:
            cls.setup_error = (
                f"Invalid JSON from vLLM: {exc}\nRaw output: {result.stdout[:500]}"
            )
        except Exception as exc:
            cls.setup_error = f"Unexpected error: {exc}"

    def setUp(self):
        if self.setup_error:
            self.fail(self.setup_error)

    # ------------------------------------------------------------------
    # Assertions
    # ------------------------------------------------------------------

    def test_http_200(self):
        """vLLM responds with HTTP 200."""
        self.assertEqual(self.http_status, 200)

    def test_response_has_choices(self):
        """Response JSON includes a non-empty choices array."""
        self.assertIn("choices", self.response)
        self.assertGreater(len(self.response["choices"]), 0)

    def test_content_nonempty(self):
        """choices[0].message.content is a non-empty string."""
        content = self.response["choices"][0]["message"]["content"]
        self.assertIsInstance(content, str)
        self.assertTrue(content.strip(), "Response content is empty")

    def test_model_name(self):
        """Response model field matches expected model."""
        self.assertEqual(self.response.get("model"), EXPECTED_MODEL)

    def test_response_time(self):
        """Response completes within timeout threshold."""
        self.assertIsNotNone(self.elapsed)
        self.assertLess(
            self.elapsed, TIMEOUT_SECONDS,
            f"Response took {self.elapsed:.1f}s (limit: {TIMEOUT_SECONDS}s)",
        )


if __name__ == "__main__":
    unittest.main()
