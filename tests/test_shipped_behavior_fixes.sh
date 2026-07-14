#!/usr/bin/env bash
# Test T2: Shipped-behavior fixes
# Verifies: (1) column dependency replaced with awk, (2) grep exclusions work for common directories
set -Euo pipefail
HARNESS="$1"; TMP="$2"

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"
rm -f .harness.db

# Test 1: Verify column dependency is replaced (workflow/harness.sh:19)
if grep -q "| *column" "$PROJ_ROOT/harness/workflows/harness.sh"; then
    echo "FAIL: workflows/harness.sh still uses column (should be replaced with awk)"
    exit 1
fi

if ! grep -q "awk.*printf.*%-" "$PROJ_ROOT/harness/workflows/harness.sh"; then
    echo "FAIL: workflows/harness.sh doesn't use awk for formatting"
    exit 1
fi

# Test 2: Verify io_grep_recursive excludes node_modules, target, dist, build, __pycache__, .venv by default
mkdir -p "$TMP/test_repo/node_modules"
mkdir -p "$TMP/test_repo/target"
mkdir -p "$TMP/test_repo/src"

echo "ignored_in_node_modules" > "$TMP/test_repo/node_modules/package.js"
echo "ignored_in_target" > "$TMP/test_repo/target/binary.o"
echo "legitimate_search_term" > "$TMP/test_repo/src/main.sh"

# Test 2a: Default behavior should EXCLUDE node_modules and target (using variable substitution correctly)
RESULT="$( (cd "$PROJ_ROOT" && source harness/lib/io.sh && io_grep_recursive 'legitimate' "$TMP/test_repo") )"

if echo "$RESULT" | grep -q "node_modules"; then
    echo "FAIL: io_grep_recursive includes node_modules/ with default behavior"
    exit 1
fi

if echo "$RESULT" | grep -q "target"; then
    echo "FAIL: io_grep_recursive includes target/ with default behavior"
    exit 1
fi

if ! echo "$RESULT" | grep -q "src/main.sh"; then
    echo "FAIL: io_grep_recursive doesn't find legitimate file in src/"
    echo "Result was: $RESULT"
    exit 1
fi

# Test 2b: Verify include_ignored=true includes excluded dirs (should find the target dir file)
RESULT_IGNORED="$( (cd "$PROJ_ROOT" && source harness/lib/io.sh && io_grep_recursive 'ignored_in_target' "$TMP/test_repo" 'include_ignored=true') )"

# With include_ignored, should find files in excluded target directory
if ! echo "$RESULT_IGNORED" | grep -q "target/binary.o"; then
    echo "FAIL: io_grep_recursive with include_ignored doesn't find target/binary.o"
    echo "Result was: $RESULT_IGNORED"
    exit 1
fi

# Test 3: Verify all non-.git excluded directories are in the function
for exclude_dir in node_modules target dist build __pycache__ .venv; do
    if ! grep -q "\-\-exclude-dir=$exclude_dir" "$PROJ_ROOT/harness/lib/io.sh"; then
        echo "FAIL: io_grep_recursive doesn't exclude $exclude_dir"
        exit 1
    fi
done

# .git exclusion is verified implicitly (grep handles it)
if ! grep -q "\-\-exclude-dir=.git" "$PROJ_ROOT/harness/lib/io.sh"; then
    echo "FAIL: io_grep_recursive doesn't explicitly exclude .git"
    exit 1
fi

# Test 4: Verify backward compatibility - old code with 2 args still works
RESULT_COMPAT="$( (cd "$PROJ_ROOT" && source harness/lib/io.sh && io_grep_recursive 'legitimate' "$TMP/test_repo") )"

if ! echo "$RESULT_COMPAT" | grep -q "src/main.sh"; then
    echo "FAIL: backward compatibility broken (2-arg calls fail)"
    exit 1
fi

# Test 5: Verify ripgrep path uses --no-ignore flag (if rg is installed)
if command -v rg &>/dev/null; then
    # Just verify function executes without error when ripgrep is available
    RESULT_RG="$( (cd "$PROJ_ROOT" && source harness/lib/io.sh && io_grep_recursive 'legitimate' "$TMP/test_repo") )"
    if ! echo "$RESULT_RG" | grep -q "src/main.sh"; then
        echo "FAIL: ripgrep path doesn't work"
        exit 1
    fi
fi

# Test 6: FORCE the grep fallback (assertion #2 — the fallback is the buggy path,
# so testing only with rg present proves nothing). Build a PATH that has grep but
# NOT rg, so `command -v rg` fails and the exclusion-carrying fallback branch runs.
NORG="$TMP/norg"; mkdir -p "$NORG"
for b in grep egrep fgrep find sort sed awk cat dirname basename; do
    src=$(command -v "$b" 2>/dev/null) && ln -sf "$src" "$NORG/$b"
done
# Prove rg really is hidden on this PATH (otherwise the test is meaningless).
if PATH="$NORG" command -v rg >/dev/null 2>&1; then
    echo "FAIL: could not hide rg from PATH — fallback path not exercised"; exit 1
fi
mkdir -p "$TMP/test_repo/node_modules" "$TMP/test_repo/src"
echo "fallback_only_in_nm" > "$TMP/test_repo/node_modules/x.js"
echo "fallback_legit" > "$TMP/test_repo/src/f.sh"
BASHBIN=$(command -v bash)
FB=$(PATH="$NORG" "$BASHBIN" -c "source '$PROJ_ROOT/harness/lib/io.sh'; io_grep_recursive 'fallback_legit' '$TMP/test_repo'")
echo "$FB" | grep -q "src/f.sh"       || { echo "FAIL: fallback grep didn't find src/f.sh"; echo "$FB"; exit 1; }
echo "$FB" | grep -q "node_modules"   && { echo "FAIL: fallback grep leaked node_modules/"; echo "$FB"; exit 1; }
# a term that lives ONLY in an excluded dir must return nothing on the fallback path
FB2=$(PATH="$NORG" "$BASHBIN" -c "source '$PROJ_ROOT/harness/lib/io.sh'; io_grep_recursive 'fallback_only_in_nm' '$TMP/test_repo'")
[[ -z "$FB2" ]] || { echo "FAIL: fallback grep matched inside an excluded dir: $FB2"; exit 1; }

# Test 7: Symlink escape (assertion #4). A symlink INSIDE the project pointing
# OUTSIDE it must be refused by the path guard — the guard resolves via realpath,
# so a prefix-match bypass is not possible. Exercised through the real read tool.
SL="$TMP/slproj"; mkdir -p "$SL"; echo "SECRET_OUTSIDE" > "$TMP/outside.txt"
ln -sf "$TMP/outside.txt" "$SL/link.txt"
GUARD=$( (
    export YCA_DIR="$PROJ_ROOT" YCA_PROJECT_DIR="$SL"
    source "$PROJ_ROOT/harness/main.sh" 2>/dev/null </dev/null
    YCA_PROJECT_DIR="$SL"; YCA_SAFETY_PATHS="$SL"; YCA_UI_MODE=plain; YCA_AUTO_CONFIRM=true
    YCA_CAT_ENABLED[core]=1; db_init 2>/dev/null; cd "$SL"
    tool_dispatch read '{"path":"link.txt"}'
) 2>/dev/null )
[[ "$GUARD" != *"SECRET_OUTSIDE"* ]] || { echo "FAIL: symlink escape leaked outside file: $GUARD"; exit 1; }
[[ "$GUARD" == *"not allowed"* ]]   || { echo "FAIL: symlink read not refused with a guard message: $GUARD"; exit 1; }

# Cleanup
rm -rf "$TMP/test_repo" "$TMP/norg" "$TMP/slproj" "$TMP/outside.txt"

echo "test_shipped_behavior_fixes OK"
exit 0
