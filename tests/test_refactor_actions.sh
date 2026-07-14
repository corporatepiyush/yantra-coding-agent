#!/usr/bin/env bash
# Test: the refactor + scaffold ACT half actually mutates correctly and fails
# HONESTLY. Guards the fixes for four verified-broken workflows:
#   - refactor.extract-const inserts AFTER the header (not line 1) AND substitutes
#     the value (was: prepend to line 1 above package/import, never substitute).
#   - refactor.rename-symbol applies with -U and emit_fail when sg is absent or
#     nothing matched (was: dry-run only, then a lying emit_ok "renamed").
#   - refactor.signature is honest plan-only, never a false emit_ok for a no-op.
#   - scaffold.test-stub is a red arrange-act-assert skeleton, never `assert True`.
# See harness/workflows/refactor.sh and harness/workflows/scaffold.sh.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/refactor_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "refactor_actions_body OK" || { echo "$OUT"; exit 1; }
echo "refactor_actions OK"
exit 0
