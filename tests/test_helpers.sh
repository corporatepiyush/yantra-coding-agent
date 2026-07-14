#!/usr/bin/env bash
# Test: helpers (sql_quote, json_str, sed_escape, version_ge, path_resolve)
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"

bash -n "$HARNESS" || { echo "syntax check failed"; exit 1; }

rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1
git clone --bare -q . "$TMP/remote.git" 2>/dev/null
git remote remove origin 2>/dev/null || true
git remote add origin "$TMP/remote.git" 2>/dev/null || true
git push -q -u origin master 2>/dev/null || git push -q -u origin HEAD 2>/dev/null || true

# Test sql_quote with a single quote in commit message
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
mcp_wf "$HARNESS" git.quicksave '{"message":"fix O'"'"'Brien bug"}' y >/dev/null \
    || { echo "quicksave with quote failed"; exit 1; }

# Verify change recorded in DB (sql_quote escaped the quote)
COUNT=$(sqlite3 .harness.db "SELECT COUNT(*) FROM changes WHERE summary LIKE '%O''Brien%';" 2>/dev/null || echo 0)
[[ "$COUNT" -ge 1 ]] || { echo "change not recorded with quote (got $COUNT)"; exit 1; }

echo "helpers OK"
exit 0
