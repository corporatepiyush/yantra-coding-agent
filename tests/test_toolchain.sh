#!/usr/bin/env bash
# Test: toolchain profile detection for multiple ecosystems (over MCP)
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

# Node
echo '{"name":"test","scripts":{"build":"tsc","test":"jest"}}' > package.json
OUT=$(mcp_wf "$HARNESS" project.overview '{}' y) || { echo "overview failed for node"; exit 1; }
echo "$OUT" | grep -q 'node' || { echo "node not detected"; exit 1; }
rm -f package.json

# Python
echo '[project]' > pyproject.toml
OUT=$(mcp_wf "$HARNESS" project.overview '{}' y) || { echo "overview failed for python"; exit 1; }
echo "$OUT" | grep -q 'python' || { echo "python not detected"; exit 1; }
rm -f pyproject.toml

# Rust
echo '[package]' > Cargo.toml
OUT=$(mcp_wf "$HARNESS" project.overview '{}' y) || { echo "overview failed for rust"; exit 1; }
echo "$OUT" | grep -q 'rust' || { echo "rust not detected"; exit 1; }
rm -f Cargo.toml

# Go
echo 'module test' > go.mod
OUT=$(mcp_wf "$HARNESS" project.overview '{}' y) || { echo "overview failed for go"; exit 1; }
echo "$OUT" | grep -q 'go' || { echo "go not detected"; exit 1; }
rm -f go.mod

echo "toolchain OK"
exit 0
