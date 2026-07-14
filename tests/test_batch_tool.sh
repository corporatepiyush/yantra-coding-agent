#!/usr/bin/env bash
# Test: the `batch` core tool + the search→files category merge.
#
# batch is a thin loop over tool_dispatch, so it must: run every sub-call,
# annotate each result with index/tool/rc, keep going past a failure, and refuse
# to nest. The merged `files` category must expose the former `search` tools.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"

cat > "$TMP/body.sh" <<'SCRIPT'
set -Euo pipefail
YCA_DIR="$1"; TMP="$2"
export YCA_DIR
YCA_PROJECT_DIR="$TMP"
export YCA_PROJECT_DIR
source "$YCA_DIR/harness/main.sh"
# constants.sh (sourced above) resets these, so set them AFTER sourcing.
YCA_UI_MODE="json"               # so confirm_action honors auto-confirm
YCA_AUTO_CONFIRM=true            # skip confirm_action prompts for writes/bash
# Enable the categories we exercise (core is always-on; files was merged).
YCA_CAT_ENABLED[core]=1
YCA_SAFETY_PATHS="$TMP"

fail() { echo "FAIL: $1"; exit 1; }

printf 'hello-from-file\n' > "$TMP/a.txt"

# ── batch: multiple calls in one shot ───────────────────────────────────────
calls='{"calls":[{"tool":"read","args":{"path":"'"$TMP"'/a.txt"}},{"tool":"bash","args":{"command":"echo BATCH_MARKER_42"}}]}'
out=$(tool_dispatch batch "$calls"); rc=$?
echo "$out" | grep -q 'hello-from-file'    || fail "batch: read sub-call output missing"
echo "$out" | grep -q 'BATCH_MARKER_42'    || fail "batch: bash sub-call output missing"
echo "$out" | grep -q '^\[0\] read'        || fail "batch: missing [0] read annotation"
echo "$out" | grep -q '^\[1\] bash'        || fail "batch: missing [1] bash annotation"
[[ "$rc" -eq 0 ]]                          || fail "batch: rc=$rc for all-successful batch"

# ── batch: a failing sub-call doesn't abort the batch, rc reflects it ────────
calls='{"calls":[{"tool":"read","args":{"path":"/no/such/file"}},{"tool":"bash","args":{"command":"echo STILL_RAN"}}]}'
out=$(tool_dispatch batch "$calls"); rc=$?
echo "$out" | grep -q 'STILL_RAN'          || fail "batch: kept going after a failing call? missing later output"
[[ "$rc" -ne 0 ]]                          || fail "batch: rc should be non-zero when a sub-call fails"

# ── batch: nested batch is refused ──────────────────────────────────────────
calls='{"calls":[{"tool":"batch","args":{"calls":[]}}]}'
out=$(tool_dispatch batch "$calls");
echo "$out" | grep -q 'nested batch not allowed' || fail "batch: nested batch was not rejected"

# ── batch: empty / malformed input ──────────────────────────────────────────
# `calls` is schema-required, so the T7 validation gate reports it (naming the
# field) before batch's own guard would; either corrective message is acceptable
# as long as the missing field is named.
out=$(tool_dispatch batch '{}')
echo "$out" | grep -qiE 'requires .calls|missing required field.*calls' \
    || fail "batch: missing .calls not reported (got: $out)"

# ── batch: at most 100 calls; 101 is refused, 100 runs ───────────────────────
mk_calls() { # $1 = count → {"calls":[{"tool":"bash","args":{"command":"true"}}, …]}
    local n="$1" i
    printf '{"calls":['
    for (( i=0; i<n; i++ )); do (( i > 0 )) && printf ','; printf '{"tool":"bash","args":{"command":"true"}}'; done
    printf ']}'
}
out=$(tool_dispatch batch "$(mk_calls 101)"); rc=$?
echo "$out" | grep -qi 'too many calls' || fail "batch: 101 calls not refused (got: $out)"
[[ "$rc" -ne 0 ]]                        || fail "batch: over-limit batch should return non-zero"
out=$(tool_dispatch batch "$(mk_calls 100)"); rc=$?
echo "$out" | grep -qi 'too many calls' && fail "batch: 100 calls was refused but should run"
[[ "$rc" -eq 0 ]]                        || fail "batch: exactly 100 successful calls should return zero (rc=$rc)"

# ── search+files → fs merge: former search_*/files_* tools live under `fs` now ─
# Disabled by default → dispatch is blocked.
out=$(tool_dispatch fs_search '{"pattern":"hello","path":"'"$TMP"'"}')
echo "$out" | grep -qi 'disabled' || fail "fs_search should be blocked while fs is disabled"
# Enable fs → the same tool now runs and finds the match.
YCA_CAT_ENABLED[fs]=1
out=$(tool_dispatch fs_search '{"pattern":"hello-from-file","path":"'"$TMP"'"}'); rc=$?
echo "$out" | grep -q 'hello-from-file' || fail "fs_search under fs category did not find match (got: $out)"

echo "batch body OK"
exit 0
SCRIPT

OUT=$(bash "$TMP/body.sh" "$(dirname "$HARNESS")" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "batch body OK" || { echo "$OUT"; exit 1; }

echo "batch_tool OK"
exit 0
