#!/usr/bin/env bash
# Test: playwright category — e2e testing tools. The test environment has no
# Playwright project, so we assert registration, danger classes, enable-gating,
# input validation, and GRACEFUL degradation (a clean structured/empty result or
# a clear error — never a crash or hang).
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
fail() { echo "FAIL: $*"; exit 1; }
export MCP_FLAGS="--enable playwright --project $TMP"

# ── 1. Registration + danger classes ─────────────────────────────────────────
REG=$(registry_dump "$PROJ_ROOT")
for spec in 'playwright_test|safe' 'playwright_flaky|safe' 'playwright_list|safe' \
            'playwright_install|writes' 'playwright_llm_diagnose|safe' 'playwright_llm_write|safe'; do
    t="${spec%%|*}"; d="${spec#*|}"
    grep -q "^$t|$d|playwright|" <<<"$REG" || fail "$t not registered as $d/playwright"
done
# the two LLM tools must carry a non-low complexity (mid/high)
grep -q "^playwright_llm_diagnose|safe|playwright|mid$"  <<<"$REG" || fail "llm_diagnose complexity != mid"
grep -q "^playwright_llm_write|safe|playwright|mid$"     <<<"$REG" || fail "llm_write complexity != high"

# ── 2. Enable-gating ─────────────────────────────────────────────────────────
DEF=$({ printf '%s\n' '{"jsonrpc":"2.0","id":"l0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":"l1","method":"tools/list","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}'
} | HARNESS_UPDATE_ENABLED=false timeout 30 bash "$HARNESS" --project "$TMP" 2>/dev/null \
  | jq -r 'select(.id=="l1").result.tools[]?.name' | grep -c '^playwright_' || true)
[[ "$DEF" == "0" ]] || fail "playwright tools visible without enabling ($DEF)"

# ── 3. Consent gate: install is 'writes' -> auto-denies without -y ────────────
out=$(mcp_call "$HARNESS" playwright_install '{"browser":"chromium"}') && fail "install ran without consent"
grep -qiE 'consent|confirm|auto-den' <<<"$out" || fail "install denial message unexpected: $out"

# ── 4. Input validation ──────────────────────────────────────────────────────
out=$(mcp_call "$HARNESS" playwright_llm_write '{"description":""}') && fail "llm_write accepted empty description"
grep -qi 'description required' <<<"$out" || fail "llm_write validation unexpected: $out"
out=$(mcp_call "$HARNESS" playwright_install '{"browser":"netscape"}' y) && fail "install accepted a bad browser"
grep -qi 'browser must be' <<<"$out" || fail "install bad-browser message unexpected: $out"

# ── 5. Graceful degradation with no Playwright present (no crash/hang) ────────
out=$(mcp_call "$HARNESS" playwright_list '{}' || true)
[[ -n "$out" ]] || fail "playwright_list produced nothing (should degrade gracefully)"
out=$(mcp_call "$HARNESS" playwright_test '{}' || true)
[[ -n "$out" ]] || fail "playwright_test produced nothing (should degrade gracefully)"

echo "playwright OK"
exit 0
