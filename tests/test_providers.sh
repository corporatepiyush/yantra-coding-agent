#!/usr/bin/env bash
# Test: multi-provider LLM routing (sticky, fall-down, mark-dead, env override,
# token resolution, session injection) + fuzz. Body lives in test_scripts/.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/providers_body.sh" "$YCA_DIR" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "providers_body OK" || { echo "$OUT"; exit 1; }
echo "providers OK"
exit 0
