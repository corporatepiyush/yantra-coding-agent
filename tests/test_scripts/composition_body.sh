#!/usr/bin/env bash
# tests/test_scripts/composition_body.sh — unit body: tool_invoke bypasses the
# category gate that tool_dispatch enforces. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json
printf 'NEEDLE_42\n' > "$2/f.txt"

# fs disabled → the gated dispatcher blocks the tool.
YCA_CAT_ENABLED[fs]=0
out=$(tool_dispatch fs_search "{\"pattern\":\"NEEDLE_42\",\"path\":\"$2\"}")
echo "$out" | grep -qi 'disabled' || { echo "tool_dispatch should block fs when disabled (got: $out)"; exit 1; }

# tool_invoke composes the SAME tool regardless of the gate.
out=$(tool_invoke fs_search "{\"pattern\":\"NEEDLE_42\",\"path\":\"$2\"}")
echo "$out" | grep -q 'NEEDLE_42' || { echo "tool_invoke should bypass the gate and find the match (got: $out)"; exit 1; }

# unknown tool is reported, not crashed.
out=$(tool_invoke nope_tool '{}'); echo "$out" | grep -qi 'unknown tool' || { echo "tool_invoke unknown-tool not reported"; exit 1; }

echo "composition_body OK"
