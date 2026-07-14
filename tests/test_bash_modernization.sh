#!/usr/bin/env bash
# Test: the Bash-5.3 modernization doesn't rot. Fails if deprecated idioms or the
# removed feature-detection fallbacks are reintroduced into harness/ code.
#
# PRE-PUSH CHECK: run this once before every push (it is a static lint — it does
# not exercise runtime, so running it once before pushing is sufficient):
#     bash tests/test_bash_modernization.sh ./yantra-mcp-server.sh /tmp
set -uo pipefail
HARNESS="$1"; TMP="$2"
ROOT="$(cd "$(dirname "$HARNESS")" && pwd)/harness"

fail=0
flag() { echo "MODERNIZATION REGRESSION: $1"; echo "$2" | sed 's/^/    /'; fail=1; }

# 1) Removed Bash-feature-detection flags must not come back (5.3 is guaranteed).
hits=$(grep -rnE 'YCA_HAVE_(BASH53|NAMEREF|EPOCHREAL|WAIT_N|MAPFILE)' "$ROOT" || true)
[[ -z "$hits" ]] || flag "reintroduced Bash-feature-detection flag" "$hits"

# 2) date +%s / date +%Y… forks — use \$EPOCHSECONDS or now_stamp instead.
hits=$(grep -rnE '\$\(date \+%' "$ROOT" || true)
[[ -z "$hits" ]] || flag "date fork (use \$EPOCHSECONDS / now_stamp)" "$hits"

# 3) $(cat "$var") slurp — use $(<"$var").
hits=$(grep -rnE '\$\(cat "\$' "$ROOT" || true)
[[ -z "$hits" ]] || flag "\$(cat ...) slurp (use \$(<...))" "$hits"

# 4) Deprecated $[ … ] arithmetic — use $(( … )).
hits=$(grep -rnE '\$\[[^[]' "$ROOT" || true)
[[ -z "$hits" ]] || flag "deprecated \$[..] arithmetic (use \$((..)))" "$hits"

# 5) Entry-point guard is intact (still enforces 5.3, exit 3).
grep -q 'requires Bash 5.3' "$(dirname "$ROOT")/yantra-mcp-server.sh" \
    || { echo "entry guard lost its Bash 5.3 requirement message"; fail=1; }

[[ "$fail" == 0 ]] || exit 1
echo "bash_modernization OK"
exit 0
