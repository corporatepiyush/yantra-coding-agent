#!/usr/bin/env bash
# Test: injection / ungated-mutation guards (OWASP A03) added to
# ssh/docker/data/pg/mysql/debug — host option-injection, remote arg-injection,
# docker_run eval removal, duckdb file/network escape, SQL ;-chaining, and the
# read-only-query / gated-exec split. Offline (no live host/db/docker required).
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/security_hardening_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "security_hardening_body OK" || { echo "$OUT"; exit 1; }
echo "security_hardening OK"
exit 0
