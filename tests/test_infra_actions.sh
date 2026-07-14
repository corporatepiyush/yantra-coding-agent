#!/usr/bin/env bash
# Test: the k8s/helm act-half (rollout/scale/apply/delete/exec/port-forward,
# upgrade/rollback/uninstall) — flag-injection-safe args, explicit targets (no
# --all), consent-gated. Offline (validated before the kubectl/helm check).
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/infra_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "infra_actions_body OK" || { echo "$OUT"; exit 1; }
echo "infra_actions OK"
exit 0
