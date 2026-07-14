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

# ── git.wipe-history — dangerous: backs up first, flattens to ONE root commit ──
# Run in an isolated sub-repo so the destructive rewrite can't disturb the above.
WR="$TMP/wipe_repo"; mkdir -p "$WR"
git -C "$WR" init -q -b main 2>/dev/null || { git -C "$WR" init -q; git -C "$WR" symbolic-ref HEAD refs/heads/main; }
git -C "$WR" config user.email t@t; git -C "$WR" config user.name t
for v in 1 2 3; do echo "$v" >> "$WR/f.txt"; git -C "$WR" add -A; git -C "$WR" commit -qm "c$v"; done
WR_TREE=$(git -C "$WR" rev-parse 'HEAD^{tree}')
export MCP_FLAGS="--project $WR"

# 1) dangerous → must auto-deny WITHOUT consent (no -y)
out=$(mcp_wf "$HARNESS" git.wipe-history '{"push":false}') && { echo "wipe ran WITHOUT consent"; exit 1; }
grep -qiE 'consent|auto-den|confirm' <<<"$out" || { echo "wipe deny message unexpected: $out"; exit 1; }

# 2) with consent, push=false → single ROOT commit, backup written, tree preserved,
#    and the verbose debug log is surfaced in the result (data.log → visible to host)
out=$(mcp_wf "$HARNESS" git.wipe-history '{"message":"snapshot","push":false}' y) || { echo "wipe failed: $out"; exit 1; }
[[ "$(git -C "$WR" rev-list --count main)" == "1" ]]                       || { echo "wipe: not a single commit"; exit 1; }
[[ "$(git -C "$WR" rev-list --parents -1 main | awk '{print NF-1}')" == "0" ]] || { echo "wipe: not a root commit"; exit 1; }
[[ "$(git -C "$WR" rev-parse 'HEAD^{tree}')" == "$WR_TREE" ]]              || { echo "wipe: file tree changed (content lost)"; exit 1; }
git -C "$WR" log -1 --format='%s' | grep -qx 'snapshot'                    || { echo "wipe: commit message not applied"; exit 1; }
ls "$WR"/.git/yca-history-backups/*.bundle >/dev/null 2>&1                 || { echo "wipe: no backup bundle written"; exit 1; }
grep -q 'byte-identical' <<<"$out"                                        || { echo "wipe: debug log not surfaced in result"; exit 1; }

# 3) push=true to a local bare remote → the remote is flattened too, reported honestly
WRR="$TMP/wipe_remote.git"; git clone --bare -q "$WR" "$WRR"
git -C "$WR" remote add origin "$WRR"
out=$(mcp_wf "$HARNESS" git.wipe-history '{"message":"snapshot2","push":true}' y) || { echo "wipe push failed: $out"; exit 1; }
grep -q '"pushed":true' <<<"$out"                       || { echo "wipe: push not reported: $out"; exit 1; }
[[ "$(git -C "$WRR" rev-list --count main)" == "1" ]]   || { echo "wipe: remote not flattened to one commit"; exit 1; }
unset MCP_FLAGS

echo "git_workflows OK"
exit 0
