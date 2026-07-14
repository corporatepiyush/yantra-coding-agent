#!/usr/bin/env bash
# Test: the machine-mode consent gate covers writes|destructive|dangerous, so the
# more-severe tokens can't fall through fail-open; known-dangerous tools keep a
# gated token. See harness/core/tools.sh danger_needs_confirm.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/danger_gate_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "danger_gate_body OK" || { echo "$OUT"; exit 1; }
echo "danger_gate OK"
exit 0
