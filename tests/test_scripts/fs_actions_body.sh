#!/usr/bin/env bash
# tests/test_scripts/fs_actions_body.sh — the files act-half: move/copy/organize/
# rename/dedupe/apply(glob)/sync. All local + offline. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json; YCA_AUTO_CONFIRM=true
YCA_CAT_ENABLED[fs]=1
fail(){ echo "FAIL: $1"; exit 1; }
W="$2/work"; mkdir -p "$W"

# fs_move — moves within the fence, refuses a dst outside it.
echo a > "$W/a.txt"
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$W/a.txt\",\"dst\":\"$W/b.txt\"}" tool_fs_move 2>&1 || true)
[[ -f "$W/b.txt" && ! -f "$W/a.txt" ]] || fail "fs_move did not move the file ($out)"
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$W/b.txt\",\"dst\":\"/tmp/escape_xyz_$$\"}" tool_fs_move 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "fs_move allowed a dst outside the fence ($out)"

# fs_copy
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$W/b.txt\",\"dst\":\"$W/c.txt\"}" tool_fs_copy 2>&1 || true)
[[ -f "$W/c.txt" && -f "$W/b.txt" ]] || fail "fs_copy did not copy ($out)"

# fs_organize by ext
rm -rf "${W:?}/"*; echo 1 > "$W/one.txt"; echo 2 > "$W/two.md"; echo 3 > "$W/three.txt"
out=$(YCA_TOOL_ARGS_JSON="{\"dir\":\"$W\",\"by\":\"ext\"}" tool_fs_organize 2>&1 || true)
[[ -f "$W/txt/one.txt" && -f "$W/md/two.md" ]] || fail "fs_organize did not bucket by ext ($out)"

# fs_rename
rm -rf "$W"; mkdir -p "$W"; echo x > "$W/IMG_1.jpg"; echo x > "$W/IMG_2.jpg"
out=$(YCA_TOOL_ARGS_JSON="{\"dir\":\"$W\",\"match\":\"IMG_\",\"replace\":\"photo_\"}" tool_fs_rename 2>&1 || true)
[[ -f "$W/photo_1.jpg" && ! -f "$W/IMG_1.jpg" ]] || fail "fs_rename did not rename ($out)"

# fs_dedupe — apply removes exactly the duplicate, keeps the distinct file.
rm -rf "$W"; mkdir -p "$W"; printf same > "$W/orig.txt"; printf same > "$W/dup.txt"; printf diff > "$W/other.txt"
out=$(YCA_TOOL_ARGS_JSON="{\"path\":\"$W\",\"apply\":true}" tool_fs_dedupe 2>&1 || true)
c=$(find "$W" -type f | grep -c '.' || true); [[ "$c" == "2" ]] || fail "fs_dedupe should leave 2 files, left $c ($out)"
[[ -f "$W/other.txt" ]] || fail "fs_dedupe removed a non-duplicate"
# preview default must NOT delete
printf same > "$W/dup2.txt"
out=$(YCA_TOOL_ARGS_JSON="{\"path\":\"$W\"}" tool_fs_dedupe 2>&1 || true)
echo "$out" | grep -qi 'preview only' || fail "fs_dedupe deleted without apply:true ($out)"
[[ -f "$W/dup2.txt" ]] || fail "fs_dedupe preview deleted a file"

# fs_apply — batch a safe read tool over a glob; nesting refused.
rm -rf "$W"; mkdir -p "$W"; echo a > "$W/1.dat"; echo b > "$W/2.dat"
out=$(YCA_TOOL_ARGS_JSON="{\"glob\":\"$W/*.dat\",\"tool\":\"fs_checksum\",\"field\":\"file\"}" tool_fs_apply 2>&1 || true)
{ echo "$out" | grep -q '1.dat' && echo "$out" | grep -q '2.dat'; } || fail "fs_apply did not apply to each file ($out)"
echo "$out" | grep -qi 'applied fs_checksum to 2' || fail "fs_apply wrong count ($out)"
out=$(YCA_TOOL_ARGS_JSON="{\"glob\":\"$W/*.dat\",\"tool\":\"fs_apply\"}" tool_fs_apply 2>&1 || true)
echo "$out" | grep -qiE 'refused|cannot' || fail "fs_apply allowed nesting ($out)"

# fs_sync — dry run by default; apply:true actually copies.
rm -rf "$W"; mkdir -p "$W/src" "$W/dst"; echo hi > "$W/src/f.txt"
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$W/src\",\"dst\":\"$W/dst\"}" tool_fs_sync 2>&1 || true)
echo "$out" | grep -qiE 'DRY RUN|rsync missing' || fail "fs_sync did not default to dry run ($out)"
[[ ! -f "$W/dst/f.txt" ]] || fail "fs_sync copied on a dry run"
if command -v rsync >/dev/null 2>&1; then
    out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$W/src\",\"dst\":\"$W/dst\",\"apply\":true}" tool_fs_sync 2>&1 || true)
    [[ -f "$W/dst/f.txt" ]] || fail "fs_sync apply:true did not copy ($out)"
fi

echo "fs_actions_body OK"
