#!/usr/bin/env bash
# List available Argo models via the local argo-shim.
# Requires start-all.sh to be running (shim listens on 127.0.0.1:44497).
curl -s http://127.0.0.1:44497/v1/models | jq
