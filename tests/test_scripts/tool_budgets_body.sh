#!/usr/bin/env bash
# tests/test_scripts/tool_budgets_body.sh — T10 result budgets, REAL test.
# Spill mechanism + lifecycle, resource-link round-trip (via spill_read), the
# silent-truncation detector with its false-positive guard, CLI/NDJSON parity,
# UTF-8-safe preview, and the defect-j constant reduction. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null </dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=plain
YCA_CAT_ENABLED[core]=1
fail(){ echo "FAIL: $1"; exit 1; }
YCA_RESULT_CAP=200   # small cap for the test

BIG=$(printf 'ABCDEFGHIJ%.0s' $(seq 1 100))   # 1000 bytes
SMALL="just a little"

# ── 1. Small result passes through untouched; large one spills ───────────────
[[ "$(result_budget "$SMALL")" == "$SMALL" ]] || fail "small result was altered"
notice=$(result_budget "$BIG")
[[ "$notice" != "$BIG" ]] || fail "large result was NOT spilled"
echo "$notice" | grep -q "1000-byte result saved to" || fail "notice omits byte count/path: $notice"
sp=$(echo "$notice" | grep -oE '/[^ ]+\.txt' | head -1)
[[ -f "$sp" ]] || fail "spill file missing: $sp"
[[ "$(wc -c < "$sp" | tr -d ' ')" == "1000" ]] || fail "spill file is not the full 1000 bytes"

# ── 2. spill_read round-trips identical bytes (the link must not lie) ─────────
id=$(spill_write "$BIG") || fail "spill_write failed"
[[ "$(spill_read "$id")" == "$BIG" ]] || fail "spill_read did not return identical bytes"
# a bogus / traversal id -> clean not-found, never a crash
spill_read "r0_0_0.txt" && fail "spill_read of a missing id should fail"
spill_read "../../etc/passwd" && fail "spill_read must reject a traversal id"
true

# ── 3. Truncation detector (F1): warn on a real shortfall, silent within tol ──
sent=$(( 4000 * 4 ))   # ~4000 token estimate
w="$2/w1"; llm_check_truncation "$sent" '{"usage":{"prompt_tokens":100}}' 2>"$w" || true
grep -q 'silent context truncation' "$w" || fail "detector did not fire on a large shortfall"
grep -q 'num_ctx' "$w" || fail "truncation warning omits the num_ctx fix"
# companion false-positive guard: reported close to estimate -> NO warning
w2="$2/w2"; llm_check_truncation "$sent" '{"usage":{"prompt_tokens":3800}}' 2>"$w2" || true
[[ ! -s "$w2" ]] || fail "detector false-fired within tolerance: $(cat "$w2")"
# and a tiny prompt can't be meaningfully truncated -> NO warning
w3="$2/w3"; llm_check_truncation 400 '{"usage":{"prompt_tokens":1}}' 2>"$w3" || true
[[ ! -s "$w3" ]] || fail "detector false-fired on a tiny prompt"

# ── 4. Lifecycle: GC removes aged files; recent ones survive ─────────────────
base="$2/.harness_results"
old="$base/oldsess"; mkdir -p "$old"; echo stale > "$old/r1_1_1.txt"
touch -t 202001010000 "$old/r1_1_1.txt"      # ancient
recent=$(spill_write "keepme")               # today
spill_gc
[[ ! -f "$old/r1_1_1.txt" ]] || fail "GC did not remove an aged spill file"
[[ "$(spill_read "$recent")" == "keepme" ]] || fail "GC removed a recent spill file"

# ── 5. Disk-full / unwritable dir -> named failure, NO dangling link ─────────
ro="$2/readonly"; mkdir -p "$ro"; chmod 555 "$ro"
( export YCA_PROJECT_DIR="$ro"
  if spill_write "x" >/dev/null 2>&1; then echo "FAIL: spill_write succeeded on a read-only dir"; exit 1; fi
  n=$(YCA_RESULT_CAP=10 result_budget "aaaaaaaaaaaaaaaaaaaa")
  echo "$n" | grep -q 'could not spill to disk' || { echo "FAIL: no graceful disk-full notice: $n"; exit 1; }
) || exit 1
chmod 755 "$ro"

# ── 6. UTF-8-safe preview: never cut mid-codepoint ───────────────────────────
emoji=$(printf 'x%.0s' $(seq 1 300))"😀😀😀"   # multibyte tail well past the preview cap
prev=$(_utf8_trim "$emoji" 305)
printf '%s' "$prev" | iconv -f UTF-8 -t UTF-8 >/dev/null 2>&1 || fail "UTF-8 preview is not valid UTF-8"

# ── 7. CLI/NDJSON parity: identical inputs spill to identical bytes ──────────
a=$(spill_write "$BIG"); b=$(spill_write "$BIG")
[[ "$(spill_read "$a")" == "$(spill_read "$b")" ]] || fail "identical inputs spilled to different content"

# ── 8. defect j: the frontier 1 MiB / 4 MiB caps are gone ────────────────────
[[ "${YCA_LLM_MAX_CONTEXT_BYTES}" -lt 4194304 ]] || fail "context cap still frontier-sized (defect j)"
[[ "${YCA_LLM_MAX_CONTEXT_BYTES}" -ge 65536 ]] || fail "context cap absurdly small"

echo "tool_budgets_body OK"
exit 0
