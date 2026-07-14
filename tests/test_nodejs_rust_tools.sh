#!/usr/bin/env bash
# Test: Rust-based JS toolchain (oxlint/biome/swc) — registration, missing-tool
# gating (no npx auto-download), and Rust-first linter detection in the profile.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo '{"name":"t","version":"1.0.0"}' > package.json
git add -A && git commit -qm init >/dev/null 2>&1

export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"

# A) tools are registered under the nodejs category
REG=$(registry_dump "$PROJ_ROOT")
for t in oxlint oxlint_fix biome_check biome_fix swc_build; do
    grep -q "^nodejs_$t|" <<<"$REG" || { echo "nodejs $t not registered"; exit 1; }
done

# B) missing tool → install hint, NOT an npx registry download (over MCP)
export MCP_FLAGS="--enable nodejs"
OUT=$(mcp_call "$HARNESS" nodejs_oxlint '{}') || true
echo "$OUT" | grep -q "tool missing" || { echo "oxlint should report missing: $OUT"; exit 1; }
echo "$OUT" | grep -q "npm i -D oxlint" || { echo "oxlint missing install hint: $OUT"; exit 1; }
OUT=$(mcp_call "$HARNESS" nodejs_biome_check '{}') || true
echo "$OUT" | grep -q "@biomejs/biome" || { echo "biome missing install hint: $OUT"; exit 1; }
OUT=$(mcp_call "$HARNESS" nodejs_swc_build '{}' y) || true
echo "$OUT" | grep -q "@swc/cli" || { echo "swc missing install hint: $OUT"; exit 1; }
unset MCP_FLAGS

# C) Rust-first detection: biome.json + a project-local bin → lint.check runs it
mkdir -p node_modules/.bin
printf '#!/bin/sh\necho biome-ran "$@"\nexit 0\n' > node_modules/.bin/biome
chmod +x node_modules/.bin/biome
echo '{}' > biome.json
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"l1","method":"tools/call","params":{"name":"wf__lint_check","arguments":{}}}' '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | HARNESS_UPDATE_ENABLED=false timeout 120 bash "$HARNESS" -y 2>&1)
echo "$OUT" | grep -q "biome-ran check" || { echo "lint.check did not use detected biome"; echo "$OUT" | tail -5; exit 1; }
echo "$OUT" | grep '^{' | jq -c 'select(.id=="l1") | .result.isError' 2>/dev/null | grep -q false || { echo "lint.check via biome not ok"; exit 1; }

# D) oxlint detected via .oxlintrc.json when no biome
rm biome.json
printf '#!/bin/sh\necho oxlint-ran "$@"\nexit 0\n' > node_modules/.bin/oxlint
chmod +x node_modules/.bin/oxlint
echo '{}' > .oxlintrc.json
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"l2","method":"tools/call","params":{"name":"wf__lint_check","arguments":{}}}' '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | HARNESS_UPDATE_ENABLED=false timeout 120 bash "$HARNESS" -y 2>&1)
echo "$OUT" | grep -q "oxlint-ran" || { echo "lint.check did not use detected oxlint"; echo "$OUT" | tail -5; exit 1; }

# E) an explicit package.json lint script always wins over detection
echo '{"name":"t","version":"1.0.0","scripts":{"lint":"echo custom-lint-ran"}}' > package.json
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"l3","method":"tools/call","params":{"name":"wf__lint_check","arguments":{}}}' '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | HARNESS_UPDATE_ENABLED=false timeout 120 bash "$HARNESS" -y 2>&1)
echo "$OUT" | grep -q "custom-lint-ran" || { echo "explicit lint script did not win"; echo "$OUT" | tail -5; exit 1; }

echo "nodejs_rust_tools OK"
exit 0
