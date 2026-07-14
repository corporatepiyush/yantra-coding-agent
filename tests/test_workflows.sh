#!/usr/bin/env bash
# Test: workflow layer — registration, MCP wf__ dispatch, missing impl
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

# Registration: key workflows exist in the sourced registry (the NDJSON --list
# catalog died with the surface; the registry is the source of truth).
MISSING=$(HARNESS_UPDATE_ENABLED=false YCA_DIR="$PROJ_ROOT" bash -c '
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  for wf in git.quicksave tools.enable build.run; do
    [[ -n "${YCA_WF_REGISTRY[$wf]:-}" ]] || echo "$wf"
  done')
[[ -z "$MISSING" ]] || { echo "workflows missing from registry: $MISSING"; exit 1; }

# Unknown workflow -> unknown tool error over MCP
OUT=$(mcp_call "$HARNESS" "wf__nope_nope" '{}' y) && { echo "expected error for unknown workflow"; exit 1; }
echo "$OUT" | grep -q "unknown tool" || { echo "unknown workflow got wrong message: $OUT"; exit 1; }

# Critical workflows must not return 501
for wf in harness.doctor git.quicksave git.undo tools.status harness.cost project.overview; do
    OUT=$(mcp_wf "$HARNESS" "$wf" '{}' y) || true
    if echo "$OUT" | grep -q '"code":"501"'; then
        echo "$wf returned 501 (not implemented)"
        exit 1
    fi
done

echo "workflows OK"
exit 0
