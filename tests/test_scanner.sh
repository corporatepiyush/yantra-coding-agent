#!/usr/bin/env bash
# Test: the startup scanner produces accurate recommendations with no nullglob
# false positives (e.g. must not claim "docker-compose found" when only a
# Dockerfile exists), and pipeline.ci is a registered workflow.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add -A && git commit -qm init >/dev/null 2>&1

# Only a Dockerfile — no compose file, no Containerfile.
printf 'FROM alpine\n' > Dockerfile

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
SCAN=$(printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | timeout 25 env HARNESS_UPDATE_ENABLED=false bash "$HARNESS" 2>&1 >/dev/null)

echo "$SCAN" | grep -qi 'Dockerfile found' || { echo "scanner missed the Dockerfile"; exit 1; }
echo "$SCAN" | grep -qi 'docker-compose found' && { echo "nullglob false positive: docker-compose reported without a compose file"; exit 1; }
echo "$SCAN" | grep -qi 'Containerfile found' && { echo "nullglob false positive: Containerfile reported without one"; exit 1; }

# pipeline.ci must be a registered workflow (referenced throughout the docs).
YCA_DIR="$PROJ_ROOT" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  [[ -n "${YCA_WF_REGISTRY[pipeline.ci]:-}" ]]' \
    || { echo "pipeline.ci workflow not registered"; exit 1; }

echo "scanner OK"
exit 0
