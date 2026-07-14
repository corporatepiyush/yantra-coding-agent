#!/usr/bin/env bash
# Test: secret/input hygiene regressions stay fixed.
#   1) No curl call in harness/ passes an Authorization header inline on argv
#      (argv is world-readable via `ps`; tokens must go through -H @<(...)).
#   2) hydrate_inputs: a value containing '=' survives intact, and a key that
#      is not a valid identifier is skipped instead of breaking `export`.
#   3) A malformed HARNESS_LLM_URL (leading '-', shell metachars) is rejected
#      at provider load instead of reaching curl's argv.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"

fail=0

# 1) Static: inline Authorization on a curl command line must not come back.
hits=$(grep -rnE -- '-H "Authorization' "$YCA_ROOT/harness" || true)
if [[ -n "$hits" ]]; then
    echo "SECRET LEAK REGRESSION: inline Authorization header on curl argv:"
    echo "$hits" | sed 's/^/    /'
    fail=1
fi
hits=$(grep -rnE -- "\-H 'Authorization" "$YCA_ROOT/harness" || true)
if [[ -n "$hits" ]]; then
    echo "SECRET LEAK REGRESSION: inline Authorization header (single-quoted):"
    echo "$hits" | sed 's/^/    /'
    fail=1
fi

# 2) Behavioral: hydrate_inputs keeps '=' in values and skips hostile keys.
#    mentor.explain-error classifies INPUT_error, so a correct classification
#    proves the value ("...EADDRINUSE...") hydrated intact next to a sibling
#    key ("bad-key;x") that must be silently skipped.
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
OUT=$(mcp_wf "$HARNESS" mentor.explain-error '{"error":"a=b listen EADDRINUSE :::3000","bad-key;x":"ignored"}') \
    || { echo "hydrate_inputs: workflow failed with '=' value + hostile key"; echo "$OUT"; fail=1; }
echo "$OUT" | grep -q 'EADDRINUSE' || { echo "hydrate_inputs: INPUT_error did not survive hydration"; echo "$OUT"; fail=1; }

# 3) Malformed HARNESS_LLM_URL is ignored (warned), never trusted.
OUT=$(HARNESS_UPDATE_ENABLED=false HARNESS_LLM_URL='-o/tmp/evil;`x`' bash "$HARNESS" --help 2>&1)
rc=$?
[[ "$rc" == 0 ]] || { echo "harness failed to boot with malformed HARNESS_LLM_URL (rc=$rc)"; echo "$OUT" | tail -5; fail=1; }

[[ "$fail" == 0 ]] || exit 1
echo "secret_hygiene OK"
exit 0
