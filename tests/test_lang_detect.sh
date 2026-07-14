#!/usr/bin/env bash
# Test: language detection for all supported languages
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

# Test each language marker
test_lang() {
    local lang="$1" file="$2" content="$3"
    printf '%s' "$content" > "$file"
    local OUT
    OUT=$(mcp_wf "$HARNESS" project.overview '{}' y) || true
    if ! echo "$OUT" | grep -q "$lang"; then
        echo "$lang not detected (file: $file)"
        exit 1
    fi
    rm -f "$file"
}

test_lang node package.json '{"name":"t"}'
test_lang python pyproject.toml '[project]'
test_lang rust Cargo.toml '[package]'
test_lang go go.mod 'module t'
test_lang c-cpp Makefile 'all:'
test_lang java pom.xml '<project></project>'
test_lang ruby Gemfile "source 'https://rubygems.org'"
test_lang php composer.json '{}'

echo "lang_detect OK"
exit 0
