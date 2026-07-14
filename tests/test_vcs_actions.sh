#!/usr/bin/env bash
# Test: the VCS "ship a change" act-half — git.ship/release/pr/quicksave/sync,
# git.conflict-assist, pr.merge/pr.review-triage. Everything outward is gated and
# validated, and a failed push is reported as a failure (never masked as success).
# Offline. Args: $1=HARNESS $2=TMP.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/vcs_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "vcs_actions_body OK" || { echo "$OUT"; exit 1; }
echo "vcs_actions OK"
exit 0
