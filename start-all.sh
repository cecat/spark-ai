#!/usr/bin/env bash
# SHIM — real file moved to spark-ops/ops/layers/spark-ai-layer.sh (Phase 4.6).
# Renamed on the way: it is a LAYER of the top-level start-all, not a start-all
# in its own right, and three files named start-all.sh calling each other was a
# standing source of confusion.
# Remove only after `journalctl -t spark-ops-shim` is empty across a full
# reboot cycle, and only with Charlie's approval (C-0b).
logger -t spark-ops-shim "shim hit: $0 by PPID $PPID ($(ps -o comm= -p $PPID 2>/dev/null))"
exec /home/catlett/code/spark-ops/ops/layers/spark-ai-layer.sh "$@"
