#!/usr/bin/env bash
# Test: git workflows — quicksave, undo, branch, clean (over MCP wf__ tools)
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
git clone --bare -q . "$TMP/remote.git" 2>/dev/null
git remote remove origin 2>/dev/null || true
git remote add origin "$TMP/remote.git" 2>/dev/null || true
git push -q -u origin master 2>/dev/null || git push -q -u origin HEAD 2>/dev/null || true

# quicksave
echo "b" > b.txt
mcp_wf "$HARNESS" git.quicksave '{"message":"add b"}' y >/dev/null || { echo "quicksave failed"; exit 1; }
git log --oneline | head -1 | grep -q 'add b' || { echo "commit message not set"; exit 1; }

# undo
mcp_wf "$HARNESS" git.undo '{}' y >/dev/null || { echo "undo failed"; exit 1; }

# branch list
mcp_wf "$HARNESS" git.branch '{"action":"list"}' y >/dev/null || { echo "branch list failed"; exit 1; }

# branch create
mcp_wf "$HARNESS" git.branch '{"action":"create","name":"feature"}' y >/dev/null || { echo "branch create failed"; exit 1; }
git branch --list | grep -q 'feature' || { echo "branch not created"; exit 1; }

# clean (dry-run)
echo "untracked" > untracked.txt
mcp_wf "$HARNESS" git.clean '{}' y >/dev/null || { echo "git.clean failed"; exit 1; }

echo "git_workflows OK"
exit 0
