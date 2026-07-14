#!/usr/bin/env bash
# Test: git-based auto-updater (update_check / update_git_pull).
# The updater is deliberately just `git pull` on a checkout (or a `git clone`
# hint when the dir isn't one). This exercises a real bare-remote → clone →
# upstream-advances → fast-forward cycle, plus the non-git and disabled paths.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
YCA_DIR_REAL="$(dirname "$HARNESS")"

bash -n "$HARNESS" || { echo "syntax check failed"; exit 1; }

cat > "$TMP/body.sh" <<'SCRIPT'
set -Euo pipefail
REAL="$1"; TMP="$2"
export YCA_DIR="$REAL"
YCA_UI_MODE="plain"; YCA_PROJECT_DIR="$TMP"; export YCA_PROJECT_DIR
source "$REAL/harness/main.sh"
fail(){ echo "FAIL: $1"; exit 1; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# A bare "remote", an upstream working clone that publishes v1, then an install
# clone. Upstream then advances (v2); the updater must fast-forward the install.
REMOTE="$TMP/remote.git"; git init -q --bare -b main "$REMOTE"
UP="$TMP/up"; git clone -q "$REMOTE" "$UP"
( cd "$UP"; echo v1 > f.txt; git add -A; git commit -qm v1; git push -q origin main )
INSTALL="$TMP/install"; git clone -q "$REMOTE" "$INSTALL"
( cd "$UP"; echo "UPDATED_MARKER_v2" > marker.txt; git add -A; git commit -qm v2; git push -q origin main )

# ── update_git_pull fast-forwards the install checkout ──
YCA_DIR="$INSTALL"; YCA_UPDATE_BRANCH="main"; YCA_UPDATE_ENABLED="true"
YCA_SAFETY_CONFIRM="false"; YCA_UI_MODE="plain"
update_git_pull || fail "update_git_pull returned nonzero"
[[ -f "$INSTALL/marker.txt" ]] || fail "git pull did not fast-forward (marker missing)"
grep -q UPDATED_MARKER_v2 "$INSTALL/marker.txt" || fail "pulled content is wrong"

# ── a non-git dir: update_check reports the clone hint, never errors ──
PLAIN="$TMP/plain"; mkdir -p "$PLAIN"; YCA_DIR="$PLAIN"; YCA_UPDATE_ENABLED="true"
OUT=$(update_check 2>&1) || fail "update_check errored on a non-git dir"
echo "$OUT" | grep -qi "not a git checkout" || fail "no clone hint for a non-git dir"

# ── disabled: a clean no-op ──
YCA_UPDATE_ENABLED="false"
OUT=$(update_check 2>&1); [[ -z "$OUT" ]] || fail "disabled updater produced output"

echo "update body OK"
exit 0
SCRIPT

OUT=$(bash "$TMP/body.sh" "$YCA_DIR_REAL" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "update body OK" || { echo "$OUT"; exit 1; }

echo "update OK"
exit 0
