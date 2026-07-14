#!/usr/bin/env bash
# Test: the server operates WITH --project as its working directory, so a host's
# project-relative tool calls resolve against that project (not wherever the
# process was spawned). Regression for the "read/bash dead on arrival for an
# agent driving a real repo" bug found by driving the MCP surface with a local
# model: it tried read {"path":"Cargo.toml"} and bash {"command":"ls"} and got
# "path not allowed" / "cwd not allowed" because $PWD != the --project dir.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
fail() { echo "FAIL: $*"; exit 1; }

# The launch cwd MUST differ from the project dir, or the bug can't manifest.
# Put the project in a subdir and drive from $TMP (its parent).
mkdir -p "$TMP/proj/src"
printf 'hello from the project\n' > "$TMP/proj/hello.txt"
printf 'fn main() {}\n' > "$TMP/proj/src/main.rs"
cd "$TMP"
export MCP_FLAGS="--project $TMP/proj"

# read a project-relative path
OUT=$(mcp_call "$HARNESS" read '{"path":"hello.txt"}' y) || fail "read of a project-relative path errored: $OUT"
grep -q "hello from the project" <<<"$OUT" || fail "read did not return the project file content: $OUT"

# read a nested project-relative path
OUT=$(mcp_call "$HARNESS" read '{"path":"src/main.rs"}' y) || fail "read of a nested relative path errored: $OUT"
grep -q "fn main" <<<"$OUT" || fail "nested read wrong content: $OUT"

# bash runs IN the project dir (pwd == project, ls sees the project files).
# Compare via realpath — macOS /var is a symlink to /private/var, so a raw string
# compare of `pwd` output vs the mktemp path spuriously differs.
OUT=$(mcp_call "$HARNESS" bash '{"command":"pwd"}' y) || fail "bash errored: $OUT"
GOT=$(printf '%s' "$OUT" | tr -d '[:space:]'); WANT="$TMP/proj"
[[ "$(realpath "$GOT" 2>/dev/null || printf '%s' "$GOT")" == "$(realpath "$WANT" 2>/dev/null || printf '%s' "$WANT")" ]] \
    || fail "bash pwd is not the project dir (got: $GOT, want: $WANT)"
OUT=$(mcp_call "$HARNESS" bash '{"command":"ls"}' y) || fail "bash ls errored: $OUT"
grep -q "hello.txt" <<<"$OUT" || fail "bash ls did not list the project files: $OUT"

# writing a project-relative path lands inside the project
OUT=$(mcp_call "$HARNESS" write '{"path":"note.txt","content":"ok"}' y) || fail "write errored: $OUT"
[[ -f "$TMP/proj/note.txt" ]] || fail "relative write did not land in the project dir"

echo "project_cwd OK"
exit 0
