#!/usr/bin/env bash
# Test: the Database act-half — data_export (fenced/gated/no-clobber, read-only-query
# + sandbox-oracle enforced) and xlsx reader support. Delegates to a body script so
# the harness is sourced in a clean bash 5.3 process. Offline for the security bits;
# uses real duckdb when present.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/db_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "db_actions_body OK" || { echo "$OUT"; exit 1; }
echo "db_actions OK"
exit 0
