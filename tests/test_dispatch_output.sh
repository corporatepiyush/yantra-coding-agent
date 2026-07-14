#!/usr/bin/env bash
# Test: tool_dispatch returns a successful tool's output (not just failures).
# Regression guard for the bug where `out=$(fn) && return 0` swallowed all
# successful output, leaving the LLM loop blind to read/query/inspect results.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "MARKER_LINE_12345" > sample.txt
git add -A && git commit -qm init >/dev/null 2>&1

YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
export YCA_DIR HARNESS_UPDATE_ENABLED=false

# Source the harness in-process and dispatch the core `read` tool.
OUT=$(
  export YCA_PROJECT_DIR="$TMP"
  source "$YCA_DIR/harness/main.sh" 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; YCA_SAFETY_PATHS="$TMP"; YCA_UI_MODE=json
  YCA_CAT_ENABLED[core]=1
  tool_dispatch read "{\"path\":\"$TMP/sample.txt\"}"
)
echo "$OUT" | grep -q 'MARKER_LINE_12345' || { echo "tool_dispatch dropped successful output (got: '$OUT')"; exit 1; }

# And a failing tool still returns its error text.
OUT2=$(
  export YCA_PROJECT_DIR="$TMP"
  source "$YCA_DIR/harness/main.sh" 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; YCA_SAFETY_PATHS="$TMP"; YCA_UI_MODE=json
  YCA_CAT_ENABLED[core]=1
  tool_dispatch read "{\"path\":\"$TMP/does_not_exist.txt\"}"
)
echo "$OUT2" | grep -qi 'not found' || { echo "tool_dispatch dropped error output (got: '$OUT2')"; exit 1; }

echo "dispatch_output OK"
exit 0
