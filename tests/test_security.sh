#!/usr/bin/env bash
# Test: security — path guard, consent gating (over MCP)
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1

# Path guard: doc.extract with a file truly outside PROJECT_DIR -> error 403
OUTSIDE_FILE="/tmp/yca_outside_test_$$/file.txt"
mkdir -p "$(dirname "$OUTSIDE_FILE")"
echo "text" > "$OUTSIDE_FILE"
OUT=$(mcp_wf "$HARNESS" doc.extract "{\"file\":\"$OUTSIDE_FILE\"}" y) && { echo "path guard did not refuse outside file"; exit 1; }
echo "$OUT" | grep -q '403' || { echo "expected a 403 error payload, got: $OUT"; exit 1; }
rm -rf "$(dirname "$OUTSIDE_FILE")"

# Without consent, a writes workflow is cancelled (fail-closed)…
OUT=$(mcp_wf "$HARNESS" build.clean '{}') && { echo "build.clean should be cancelled without consent"; exit 1; }
echo "$OUT" | grep -qi 'consent\|cancel' || { echo "deny message not instructive: $OUT"; exit 1; }

# …and a safe workflow still runs without consent (no over-gating)
mcp_wf "$HARNESS" sec.shellcheck '{"path":"a.txt"}' >/dev/null || { echo "safe workflow over-gated"; exit 1; }

# With consent, build.clean proceeds
mcp_wf "$HARNESS" build.clean '{}' y >/dev/null || { echo "build.clean failed with consent"; exit 1; }

echo "security OK"
exit 0
