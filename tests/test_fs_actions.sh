#!/usr/bin/env bash
# Test: the files act-half (move/copy/organize/rename/dedupe/apply-glob/sync) —
# fence-confined, confirmed, non-clobbering; the glob primitive fs_apply batches
# any single-file tool across a folder. Offline.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/fs_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "fs_actions_body OK" || { echo "$OUT"; exit 1; }
echo "fs_actions OK"
exit 0
