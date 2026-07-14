#!/usr/bin/env bash
# Test: lib utilities — strings, arrays, hashmaps, paths, version, numbers
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1

# Source the harness lib by running a workflow that exercises utils
# We test via a custom script that sources the lib
cat > "$TMP/test_lib.sh" <<'SCRIPT'
set -Euo pipefail
YCA_DIR="$1"
export YCA_DIR
YCA_UI_MODE="plain"
YCA_API_TOKEN=""
YCA_LOG_LEVEL="info"
for f in "$YCA_DIR/harness/lib/"*.sh; do source "$f"; done
_yca_bash_init

# String tests
[[ "$(str_lower "HELLO")" == "hello" ]] || { echo "str_lower failed"; exit 1; }
[[ "$(str_upper "hello")" == "HELLO" ]] || { echo "str_upper failed"; exit 1; }
[[ "$(str_trim "  hi  ")" == "hi" ]] || { echo "str_trim failed"; exit 1; }
str_contains "hello world" "world" || { echo "str_contains failed"; exit 1; }
str_starts_with "hello" "he" || { echo "str_starts_with failed"; exit 1; }
str_ends_with "hello" "lo" || { echo "str_ends_with failed"; exit 1; }
[[ "$(str_replace "world" "bash" "hello world")" == "hello bash" ]] || { echo "str_replace failed"; exit 1; }
[[ "$(str_replace_all "a" "b" "banana")" == "bbnbnb" ]] || { echo "str_replace_all failed"; exit 1; }
[[ "$(str_len "hello")" == "5" ]] || { echo "str_len failed"; exit 1; }
[[ "$(str_truncate "hello world" 8)" == "hello..." ]] || { echo "str_truncate failed"; exit 1; }

# Array tests
declare -a arr=(a b c d)
arr_contains arr "c" || { echo "arr_contains failed"; exit 1; }
! arr_contains arr "z" || { echo "arr_contains should fail for z"; exit 1; }
[[ "$(arr_size arr)" == "4" ]] || { echo "arr_size failed"; exit 1; }
[[ "$(arr_join arr ,)" == "a,b,c,d" ]] || { echo "arr_join failed"; exit 1; }

# Hashmap tests
declare -A m
map_set m key1 val1
[[ "$(map_get m key1)" == "val1" ]] || { echo "map_get failed"; exit 1; }
map_has m key1 || { echo "map_has failed"; exit 1; }
! map_has m key2 || { echo "map_has should fail for key2"; exit 1; }
[[ "$(map_size m)" == "1" ]] || { echo "map_size failed"; exit 1; }

# Number tests
[[ "$(math_add 3 4)" == "7" ]] || { echo "math_add failed"; exit 1; }
[[ "$(math_max 3 7)" == "7" ]] || { echo "math_max failed"; exit 1; }
[[ "$(math_abs -5)" == "5" ]] || { echo "math_abs failed"; exit 1; }
math_is_int "42" || { echo "math_is_int failed"; exit 1; }
! math_is_int "abc" || { echo "math_is_int should fail for abc"; exit 1; }

# Path tests
[[ "$(path_ext "file.TXT")" == "txt" ]] || { echo "path_ext failed"; exit 1; }
[[ "$(path_basename "/a/b/c.txt")" == "c.txt" ]] || { echo "path_basename failed"; exit 1; }
[[ "$(path_dirname "/a/b/c.txt")" == "/a/b" ]] || { echo "path_dirname failed"; exit 1; }
path_is_absolute "/foo" || { echo "path_is_absolute failed"; exit 1; }
! path_is_absolute "foo" || { echo "path_is_absolute should fail for relative"; exit 1; }
[[ "$(path_normalize "/a/b/../c")" == "/a/c" ]] || { echo "path_normalize failed"; exit 1; }

# Version tests
version_ge "2.0.0" "1.0.0" || { echo "version_ge 2>=1 failed"; exit 1; }
! version_ge "1.0.0" "2.0.0" || { echo "version_ge 1>=2 should fail"; exit 1; }
version_eq "1.2.3" "1.2.3" || { echo "version_eq failed"; exit 1; }
[[ "$(version_major "v3.1.4")" == "3" ]] || { echo "version_major failed"; exit 1; }

echo "lib OK"
SCRIPT

bash "$TMP/test_lib.sh" "$(dirname "$HARNESS")" 2>&1 || exit 1
echo "lib_utils OK"
exit 0
