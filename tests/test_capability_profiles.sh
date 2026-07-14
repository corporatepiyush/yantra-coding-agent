#!/usr/bin/env bash
# Test T9: Capability profiles - host + provider detection
set -Euo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/capability_profiles_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "capability_profiles_body OK" || { echo "$OUT"; exit 1; }
echo "test_capability_profiles OK"
exit 0
