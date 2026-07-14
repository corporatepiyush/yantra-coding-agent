#!/usr/bin/env bash
# Test: per-language dep_add (add-a-dependency) — cargo add / npm add / go get /
# bundle add / composer require / … . The one capability that was missing in all
# 10 language modules. Guards: package-name validation (no option injection, no
# shell metacharacters) runs before the tool-present check so it works offline;
# the real-fetch adds are gated `writes`; machine mode denies them without
# consent; and the toolchain-aware deps.add workflow is wired up.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

OUT=$(bash "$YCA_DIR/tests/test_scripts/dep_add_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "dep_add_body OK" || { echo "$OUT"; exit 1; }

echo "dep_add OK"
exit 0
