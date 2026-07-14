#!/usr/bin/env bash
# T5: the evals harness is an honest instrument. Success comes only from each
# fixture's programmatic check (sabotage control proves it), token counts only
# from usage fields (validate-row rejects everything else), dead engines
# record error — never fail — and fixtures are checksum-locked per run.
set -Euo pipefail
HARNESS="$1"; TMP="$2"

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
EVALS="$PROJ_ROOT/tests/evals/harness.sh"
cd "$TMP"

fail() { echo "FAIL: $*"; exit 1; }

# ── 1. Scripted run: real replay, real checks, honest rows ───────────────────
R1="$TMP/r1.jsonl"
bash "$EVALS" run --results "$R1" --sabotage --harness "$HARNESS" 2>/dev/null \
    || fail "scripted run exited non-zero"
[[ "$(wc -l < "$R1" | tr -d ' ')" == "7" ]] || fail "expected 7 rows (3 tasks x 2 conditions + sabotage), got $(wc -l < "$R1")"

# every row validates against the harness's own row contract
while IFS= read -r row; do
    bash "$EVALS" validate-row "$row" >/dev/null 2>&1 \
        || fail "run produced a row its own validator rejects: $row"
done < "$R1"

# all tasks x conditions present; statuses only from the closed set
jq -es '[.[] | select(.model == "recorded-session") | "\(.task)/\(.condition)"] | sort == [
    "add_similar/with_yantra","add_similar/without_yantra",
    "fix_broken_test/with_yantra","fix_broken_test/without_yantra",
    "optimize_query/with_yantra","optimize_query/without_yantra"]' "$R1" >/dev/null \
    || fail "matrix incomplete: $(jq -c '{task,condition}' "$R1")"
jq -es 'all(.[]; .status | IN("success","fail","error"))' "$R1" >/dev/null \
    || fail "row with a status outside success|fail|error"

# the recorded solutions succeed; scripted rows carry NO token numbers
jq -es 'all(.[] | select(.model == "recorded-session"); .status == "success")' "$R1" >/dev/null \
    || fail "a recorded solution session did not succeed: $(jq -c 'select(.status != "success")' "$R1")"
jq -es 'all(.[]; .mode == "scripted" and .prompt_tokens == null and .completion_tokens == null)' "$R1" >/dev/null \
    || fail "a scripted row fabricated token counts"

# ── 2. Sabotage control: a no-op session records fail, never success ─────────
[[ "$(jq -r 'select(.model == "sabotage-session") | .status' "$R1")" == "fail" ]] \
    || fail "sabotage session did not record fail — success is being assumed, not measured"

# ── 3. Fixture determinism: second run, same checksum, same outcomes ─────────
R2="$TMP/r2.jsonl"
bash "$EVALS" run --results "$R2" --sabotage --harness "$HARNESS" 2>/dev/null \
    || fail "second run exited non-zero"
ck1=$(jq -r '.fixture_checksum' "$R1" | sort -u); ck2=$(jq -r '.fixture_checksum' "$R2" | sort -u)
[[ "$(printf '%s\n' "$ck1" | wc -l | tr -d ' ')" == "1" ]] || fail "one run used more than one fixture checksum"
[[ "$ck1" == "$ck2" ]] || fail "fixture checksum drifted between runs: $ck1 vs $ck2"
[[ "$(jq -c '{task,condition,model,status}' "$R1")" == "$(jq -c '{task,condition,model,status}' "$R2")" ]] \
    || fail "outcomes not deterministic across identical runs"

# ── 4. Row contract: fabricated/incomplete rows are rejected ─────────────────
good='{"timestamp":1,"task":"t","condition":"with_yantra","mode":"live","model":"m","engine":"ollama","engine_version":"1","host":"h","host_version":"1","status":"success","prompt_tokens":10,"completion_tokens":5,"fixture_checksum":"c"}'
bash "$EVALS" validate-row "$good" >/dev/null 2>&1 || fail "validator rejects a well-formed live row"
bash "$EVALS" validate-row "$(jq -c '.prompt_tokens = 0' <<< "$good")" >/dev/null 2>&1 \
    && fail "live success row with zero usage tokens was accepted"
bash "$EVALS" validate-row "$(jq -c 'del(.host)' <<< "$good")" >/dev/null 2>&1 \
    && fail "row without a host column was accepted"
bash "$EVALS" validate-row "$(jq -c 'del(.host_version)' <<< "$good")" >/dev/null 2>&1 \
    && fail "row without host_version was accepted"
bash "$EVALS" validate-row "$(jq -c '.status = "yes"' <<< "$good")" >/dev/null 2>&1 \
    && fail "row with status outside success|fail|error was accepted"
bash "$EVALS" validate-row "$(jq -c '.mode = "scripted"' <<< "$good")" >/dev/null 2>&1 \
    && fail "scripted row carrying token counts was accepted (fabrication)"

# ── 5. Dead engine → error rows only, tokens null (never poisons stats) ──────
R3="$TMP/r3.jsonl"
YCA_EVAL_MODELS="ghost" YCA_EVAL_OLLAMA_URL="http://127.0.0.1:1" \
    bash "$EVALS" run --results "$R3" --live --harness "$HARNESS" 2>/dev/null \
    || fail "dead-engine live run exited non-zero"
jq -es '[.[] | select(.mode == "live")] | length == 6 and all(.[]; .status == "error" and .prompt_tokens == null)' "$R3" >/dev/null \
    || fail "dead engine did not record clean error rows: $(jq -c 'select(.mode == "live")' "$R3" | head -3)"

echo "test_evals_harness OK"
exit 0
