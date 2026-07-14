#!/usr/bin/env bash
# Test: composition seams — tool_invoke (gate-bypassing) + wf_call (child frames
# suppressed so a composite workflow emits exactly one result).
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

# 1) tool_invoke unit body.
OUT=$(bash "$YCA_DIR/tests/test_scripts/composition_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "composition_body OK" || { echo "$OUT"; exit 1; }

# 2) wf_call: pipeline.fix composes fmt.all + lint.fix but emits exactly one
# result frame. The frame stream is internal now (MCP wraps it), so assert at
# the seam itself: run_workflow with the frame fd captured to a file.
N=$(YCA_DIR="$YCA_DIR" TMP="$TMP" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; YCA_SAFETY_PATHS="$TMP"; YCA_UI_MODE=json
  YCA_AUTO_CONFIRM=true
  exec {fd}>"$TMP/frames.ndjson"; YCA_OUT_FD=$fd
  run_workflow pipeline.fix >/dev/null 2>&1 || true
  exec {fd}>&-
  jq -c "select(.type==\"result\")" "$TMP/frames.ndjson" | wc -l | tr -d " "')
[[ "$N" == "1" ]] || { echo "pipeline.fix emitted $N result frames (expected 1 — wf_call should suppress child frames)"; exit 1; }

echo "composition OK"
exit 0
