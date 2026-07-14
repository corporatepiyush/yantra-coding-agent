#!/usr/bin/env bash
# Test T10: Tool-result budgets + resource links
set -Euo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/tool_budgets_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "tool_budgets_body OK" || { echo "$OUT"; exit 1; }
echo "test_tool_budgets OK"
exit 0
