#!/usr/bin/env bash
# Test T12: Plan store - tools + resource + decoration
set -Euo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/plan_store_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "plan_store_body OK" || { echo "$OUT"; exit 1; }
echo "test_plan_store OK"
exit 0
