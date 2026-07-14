#!/usr/bin/env bash
# Test T11: Discovery backend - search tools + menu mode
set -Euo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/discovery_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "discovery_body OK" || { echo "$OUT"; exit 1; }
echo "test_discovery OK"
exit 0
