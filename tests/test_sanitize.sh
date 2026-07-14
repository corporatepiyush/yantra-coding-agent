#!/usr/bin/env bash
# Test: input-injection sanitizers (url/sql-fragment/int/line/shell) + fuzz.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/sanitize_body.sh" "$YCA_DIR" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "sanitize_body OK" || { echo "$OUT"; exit 1; }
echo "sanitize OK"
exit 0
