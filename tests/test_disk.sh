#!/usr/bin/env bash
# Test: disk.scan/disk.clean reclaim workflow AND its safeguards.
#
# Runs entirely on an IN-MEMORY filesystem when one is available (Linux tmpfs at
# /dev/shm); otherwise a dedicated /tmp dir. It never touches the real $HOME, the
# real $TMPDIR, or any system path — the sandbox's own HOME and TMPDIR are set
# explicitly so every guard decision is fully controlled.
#
# Part A drives the real CLI (caches + stale temp + bak + browser cache + browser
# history removed; cookies/logins/bookmarks/localStorage, cache roots, personal
# folders, and build dirs kept). Part B unit-tests the _disk_rm primitive.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR_REAL="$(cd "$(dirname "$HARNESS")" && pwd)"

# Pick a base dir: prefer an in-memory fs, fall back to /tmp. Never the real home.
if [[ -d /dev/shm && -w /dev/shm ]]; then BASE=$(mktemp -d /dev/shm/yca-disk.XXXXXX)
else                                       BASE=$(mktemp -d /tmp/yca-disk.XXXXXX); fi
trap 'rm -rf "$BASE"' EXIT

# ── Part A: functional, via the real CLI ────────────────────────────────────
S="$BASE/fx"
P="$S/home/Library/Application Support/Google/Chrome/Default"
mkdir -p "$P/Cache" "$P/Code Cache" "$P/Local Storage/leveldb" \
         "$S/home/.cache/c" "$S/home/proj/node_modules" "$S/home/Documents" "$S/tmp/tmp.old"
dd if=/dev/zero of="$P/Cache/b"      bs=1024 count=1100 2>/dev/null
dd if=/dev/zero of="$P/Code Cache/b" bs=1024 count=1100 2>/dev/null
echo H > "$P/History"; echo V > "$P/Visited Links"                         # history → removed
echo C > "$P/Cookies"; echo L > "$P/Login Data"; echo B > "$P/Bookmarks"   # user data → kept
echo LS > "$P/Local Storage/leveldb/d"
dd if=/dev/zero of="$S/home/.cache/c/b"            bs=1024 count=1100 2>/dev/null
dd if=/dev/zero of="$S/tmp/tmp.old/log"            bs=1024 count=1100 2>/dev/null; touch -t 202601010000 "$S/tmp/tmp.old"
dd if=/dev/zero of="$S/home/proj/node_modules/lib" bs=1024 count=1100 2>/dev/null
echo x > "$S/home/proj/old.bak.1"
echo THESIS > "$S/home/Documents/thesis.txt"
( cd "$S/home/proj"
  export HOME="$S/home" TMPDIR="$S/tmp" HOMEBREW_CACHE="$S/nobrew" \
         HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$S/none.json"
  printf '%s\n' "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"wf__disk_clean\",\"arguments\":{\"root\":\"$S/home\",\"age_days\":0}}}" '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | timeout 240 bash "$HARNESS" -y >/dev/null 2>&1
)
for f in "$P/Cache" "$P/Code Cache" "$P/History" "$P/Visited Links" \
         "$S/home/.cache/c" "$S/tmp/tmp.old" "$S/home/proj/old.bak.1"; do
    [[ -e "$f" ]] && { echo "NOT removed: $f"; exit 1; }
done
for f in "$P/Cookies" "$P/Login Data" "$P/Bookmarks" "$P/Local Storage/leveldb/d" \
         "$S/home/.cache" "$S/home/Documents/thesis.txt" "$S/home/proj/node_modules/lib"; do
    [[ -e "$f" ]] || { echo "WRONGLY deleted: $f"; exit 1; }
done

# ── Part B: _disk_rm safeguards (unit) ──────────────────────────────────────
cat > "$BASE/guard.sh" <<'SCRIPT'
set -Euo pipefail
REAL="$1"; G="$2"
export YCA_DIR="$REAL"; YCA_UI_MODE=plain; YCA_PROJECT_DIR="$G"; export YCA_PROJECT_DIR
source "$REAL/harness/main.sh"
fail(){ echo "FAIL: $1"; exit 1; }
# Controlled roots: HOME and TMPDIR both under $G, so "$G/outside" is under NEITHER.
export HOME="$G/home"; export TMPDIR="$G/tmp"; _DISK_BREW_CACHE=""
mkdir -p "$HOME/Documents" "$HOME/.cache/deep" "$HOME/sub" "$HOME/toplevel" "$TMPDIR" "$G/outside"
echo keep > "$HOME/Documents/f"; echo x > "$HOME/.cache/deep/f"
echo z > "$HOME/toplevel/f"; echo out > "$G/outside/f"; ln -s /etc "$HOME/sub/link"

_disk_rm "$HOME/Documents";    [[ -e "$HOME/Documents/f" ]]  || fail "deleted protected Documents"
_disk_rm "$HOME/.cache";       [[ -e "$HOME/.cache/deep/f" ]] || fail "deleted protected .cache root"
_disk_rm "$HOME/toplevel";     [[ -e "$HOME/toplevel/f" ]]   || fail "deleted a too-shallow top-level dir"
_disk_rm "$HOME/sub/link";     [[ -e /etc/hosts ]]           || fail "followed a symlink to /etc"
[[ -L "$HOME/sub/link" ]] || fail "removed the symlink node itself"
_disk_rm "$G/outside/f";       [[ -e "$G/outside/f" ]]       || fail "deleted a path outside HOME and TMPDIR"
_disk_rm ""; _disk_rm "/"; _disk_rm "relative/path"          # must refuse without error
_disk_rm "$HOME/.cache/deep/f"; [[ -e "$HOME/.cache/deep/f" ]] && fail "did not delete a legit deep cache file"

_disk_is_history_name "History"         || fail "History not allowlisted"
_disk_is_history_name "Cookies"         && fail "Cookies wrongly allowlisted as history"
_disk_is_protected_name "Cookies"       || fail "Cookies not on protected denylist"
_disk_is_protected_name "Local Storage" || fail "Local Storage not on protected denylist"
_disk_is_protected_name "Login Data"    || fail "Login Data not on protected denylist"
echo "guard OK"
SCRIPT
OUT=$(bash "$BASE/guard.sh" "$YCA_DIR_REAL" "$BASE/g" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "guard OK" || { echo "$OUT"; exit 1; }

echo "disk OK"
exit 0
