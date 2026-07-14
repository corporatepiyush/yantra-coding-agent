#!/usr/bin/env bash
# Test: git introspection tools, text/encoding tools, git.worktree,
# test.flaky (no-test-command path), net.diagnose (offline paths only).
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "alpha" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1
echo "beta" >> a.txt
git add a.txt
git commit -qm second >/dev/null 2>&1

export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
# the CLI front door is gone; tools are reached over MCP with their categories
# enabled at launch (the gate itself is covered by test_tool_categories)
export MCP_FLAGS="--enable git"
tcall() { local t="$1"; shift; mcp_call "$HARNESS" "$t" "${1:-}"; }

# ── git tools (over MCP) ─────────────────────────────────────────────────────
OUT=$(tcall git_log '{"count":5}')
echo "$OUT" | grep -q "init" || { echo "git log missing init commit: $OUT"; exit 1; }
echo "$OUT" | grep -q "second" || { echo "git log missing second commit: $OUT"; exit 1; }

# pickaxe: 'beta' was introduced by the second commit only
OUT=$(tcall git_search_history '{"pattern":"beta"}')
echo "$OUT" | grep -q "second" || { echo "git search missed introducing commit: $OUT"; exit 1; }
echo "$OUT" | grep -q "init" && { echo "git search over-matched: $OUT"; exit 1; }

OUT=$(tcall git_file_history '{"file":"a.txt"}')
echo "$OUT" | grep -q "init" || { echo "git file_history missing init: $OUT"; exit 1; }

# diff with a path filter (regression: --stat must not land after `--`)
echo "gamma" >> a.txt
OUT=$(tcall git_diff '{"path":"a.txt"}')
echo "$OUT" | grep -q "gamma" || { echo "git diff --path missing change: $OUT"; exit 1; }
echo "$OUT" | grep -q "1 file changed" || { echo "git diff --path missing stat section: $OUT"; exit 1; }
git checkout -q -- a.txt
OUT=$(tcall git_diff)
echo "$OUT" | grep -q "no differences" || { echo "clean git diff should say no differences: $OUT"; exit 1; }

# outside a repo → friendly error (own mktemp dir: a subdir of $TMP would
# resolve up to $TMP's repo). git_log runs the same _git_repo_check.
NOREPO=$(mktemp -d)
OUT=$( (cd "$NOREPO" && mcp_call "$HARNESS" git_log) )
rm -rf "$NOREPO"
echo "$OUT" | grep -q "not a git repository" || { echo "git tool outside repo not friendly: $OUT"; exit 1; }

# ── git.worktree workflow ─────────────────────────────────────────────────────
unset MCP_FLAGS
mcp_wf "$HARNESS" git.worktree '{"action":"list"}' y >/dev/null || { echo "worktree list failed"; exit 1; }

mcp_wf "$HARNESS" git.worktree "{\"action\":\"add\",\"name\":\"wtbr\",\"path\":\"$TMP/wt1\"}" y >/dev/null || { echo "worktree add failed"; exit 1; }
[[ -d "$TMP/wt1" ]] || { echo "worktree dir not created"; exit 1; }
git -C "$TMP" branch --list | grep -q wtbr || { echo "worktree branch not created"; exit 1; }

mcp_wf "$HARNESS" git.worktree "{\"action\":\"remove\",\"path\":\"$TMP/wt1\"}" y >/dev/null || { echo "worktree remove failed"; exit 1; }
[[ -d "$TMP/wt1" ]] && { echo "worktree dir not removed"; exit 1; }

# ── test.flaky: no test command here → graceful ok:false ─────────────────────
mcp_wf "$HARNESS" test.flaky '{"runs":2}' y >/dev/null && { echo "test.flaky should fail without a test cmd"; exit 1; }

# ── net.diagnose: input validation + offline literal-IP path ────────────────
OUT=$(mcp_wf "$HARNESS" net.diagnose '{}' y) && { echo "net.diagnose missing-input should fail"; exit 1; }
echo "$OUT" | grep -q '422' || { echo "net.diagnose missing-input should 422: $OUT"; exit 1; }

# literal IP + (almost certainly) closed port: DNS skipped-ok, TCP fails → 1/2
OUT=$(mcp_wf "$HARNESS" net.diagnose '{"host":"127.0.0.1","port":1}' y) || true
echo "$OUT" | grep -q '"dns":true' || { echo "net.diagnose literal-IP dns not ok: $OUT"; exit 1; }

echo "git_text_tools OK"
exit 0
