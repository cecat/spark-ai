#!/usr/bin/env python3
"""Quick test of the vLLM endpoint on the Spark."""

import sys
import urllib.request
import json

URL = "http://localhost:8000/v1/chat/completions"
MODEL = "Qwen/Qwen3-Coder-Next-FP8"
DEFAULT_PROMPT = "What is the best time of year to visit Chicago in terms of pleasant weather, and what is the one thing you'd recommend a person should do if they have only one day to spend.?"

PROMPT = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_PROMPT

payload = json.dumps({
    "model": MODEL,
    "messages": [{"role": "user", "content": PROMPT}],
    "max_tokens": 100,
}).encode()

req = urllib.request.Request(URL, data=payload, headers={"Content-Type": "application/json"})

print(f"Sending: {PROMPT}")
print("-" * 40)

with urllib.request.urlopen(req, timeout=30) as resp:
    result = json.loads(resp.read())

print(result["choices"][0]["message"]["content"])
print("-" * 40)
print(f"Tokens — prompt: {result['usage']['prompt_tokens']}, "
      f"completion: {result['usage']['completion_tokens']}")
