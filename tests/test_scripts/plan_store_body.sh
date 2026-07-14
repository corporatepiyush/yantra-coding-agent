#!/usr/bin/env bash
# tests/test_scripts/plan_store_body.sh — T12 plan store, REAL behavioral test.
# Drives plan_create/plan_status/plan_step_done through tool_dispatch (the actual
# host-facing path, so T7 validation + T12 decoration are exercised) and asserts:
# CRUD, decoration-exactly-once-only-while-active, no-plan byte-identical output,
# non-accumulation in the DB, plan://current == plan_status, cross-project
# isolation, and the negative cases. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null </dev/null
YCA_UI_MODE=json; YCA_AUTO_CONFIRM=true; YCA_OUT_FD=1
YCA_CAT_ENABLED[core]=1
fail(){ echo "FAIL: $1"; exit 1; }

# Project A
A="$2/projA"; mkdir -p "$A"
export YCA_PROJECT_DIR="$A"; YCA_SAFETY_PATHS="$A"; YCA_DB_PATH="$A/.harness.db"
db_init 2>/dev/null
cd "$A"; printf 'file-body\n' > f.txt

first_line(){ printf '%s' "$1" | sed -n '1p'; }
plan_lines(){ printf '%s\n' "$1" | grep -c '^PLAN:' || true; }

# ── 1. CRUD ──────────────────────────────────────────────────────────────────
out=$(tool_dispatch plan_create '{"steps":[{"order":1,"text":"alpha"},{"order":2,"text":"beta"}]}')
js=$(first_line "$out")
[[ "$(printf '%s' "$js" | jq -r '.ok')" == "true" ]] || fail "plan_create not ok: $js"
pid=$(printf '%s' "$js" | jq -r '.plan_id')
[[ "$pid" =~ ^[0-9]+$ ]] || fail "plan_create returned no numeric plan_id: $js"

out=$(tool_dispatch plan_status '{}'); js=$(first_line "$out")
[[ "$(printf '%s' "$js" | jq -r '.total')" == "2" ]] || fail "status total != 2: $js"
[[ "$(printf '%s' "$js" | jq -r '.current_step.text')" == "alpha" ]] || fail "current_step not alpha: $js"
[[ "$(printf '%s' "$js" | jq -r '.current_step.n')" == "1" ]] || fail "current_step.n != 1: $js"

# ── 2. Decoration: exactly once, only while active ───────────────────────────
raw_active=$(tool_dispatch read '{"path":"f.txt"}')
[[ "$(plan_lines "$raw_active")" == "1" ]] || fail "expected exactly ONE PLAN: line while active, got: $raw_active"
[[ "$(first_line "$raw_active")" == "file-body" ]] || fail "decoration corrupted the result body: $raw_active"
printf '%s' "$raw_active" | grep -q '^PLAN: step 1 of 2 — alpha$' || fail "decoration text wrong: $raw_active"

# advance: mark step 1 done -> decoration now names step 2
out=$(tool_dispatch plan_step_done '{"step_order":1}'); js=$(first_line "$out")
[[ "$(printf '%s' "$js" | jq -r '.completed')" == "false" ]] || fail "premature completion: $js"
raw2=$(tool_dispatch read '{"path":"f.txt"}')
printf '%s' "$raw2" | grep -q '^PLAN: step 2 of 2 — beta$' || fail "decoration did not advance to step 2: $raw2"

# ── 3. Non-accumulation: nothing named PLAN: is ever persisted ────────────────
acc=$(sqlite3 "$YCA_DB_PATH" \
    "SELECT (SELECT count(*) FROM tasks WHERE input_json LIKE '%PLAN:%')
          + (SELECT count(*) FROM events WHERE COALESCE(data_json,'')||COALESCE(message,'') LIKE '%PLAN:%');")
[[ "$acc" == "0" ]] || fail "decoration leaked into persisted state (count=$acc)"

# ── 4. plan://current resource equals plan_status ────────────────────────────
res=$(mcp_resources_read 7 "plan://current")
res_text=$(printf '%s' "$res" | jq -r '.result.contents[0].text')
status_text=$(first_line "$(tool_dispatch plan_status '{}')")
[[ "$(printf '%s' "$res_text" | jq -S .)" == "$(printf '%s' "$status_text" | jq -S .)" ]] \
    || fail "plan://current != plan_status. resource=$res_text status=$status_text"

# ── 5. Complete the plan -> decoration stops, output byte-identical to raw ────
tool_dispatch plan_step_done '{"step_order":2}' >/dev/null
done_out=$(tool_dispatch read '{"path":"f.txt"}')
[[ "$(plan_lines "$done_out")" == "0" ]] || fail "still decorating after plan completed: $done_out"
[[ "$done_out" == "file-body" ]] || fail "no-plan output not byte-identical to raw tool output: [$done_out]"

# ── 6. Cross-project isolation: plan in B is invisible from A ─────────────────
B="$2/projB"; mkdir -p "$B"
YCA_PROJECT_DIR="$B"; YCA_SAFETY_PATHS="$B"; YCA_DB_PATH="$B/.harness.db"; db_init 2>/dev/null
cd "$B"
tool_dispatch plan_create '{"steps":[{"order":1,"text":"only-in-B"}]}' >/dev/null
bstat=$(first_line "$(tool_dispatch plan_status '{}')")
[[ "$(printf '%s' "$bstat" | jq -r '.steps[0].text')" == "only-in-B" ]] || fail "B cannot see its own plan: $bstat"
# switch back to A: A's plan is complete, and must NOT show B's step
YCA_PROJECT_DIR="$A"; YCA_SAFETY_PATHS="$A"; YCA_DB_PATH="$A/.harness.db"; cd "$A"
astat=$(first_line "$(tool_dispatch plan_status '{}')")
printf '%s' "$astat" | jq -e '.steps | map(.text) | index("only-in-B") == null' >/dev/null \
    || fail "cross-project leak: A sees B's step: $astat"

# ── 7. Negatives ─────────────────────────────────────────────────────────────
# empty steps -> error
err=$(first_line "$(tool_dispatch plan_create '{"steps":[]}')")
[[ "$(printf '%s' "$err" | jq -r '.ok')" == "false" ]] || fail "empty steps should fail: $err"
# unknown step order -> error, not silent success
YCA_DB_PATH="$B/.harness.db"; YCA_PROJECT_DIR="$B"; cd "$B"
err2=$(first_line "$(tool_dispatch plan_step_done '{"step_order":99}')")
[[ "$(printf '%s' "$err2" | jq -r '.ok')" == "false" ]] || fail "unknown step order should fail: $err2"

# ── 8. Bare-string steps form ────────────────────────────────────────────────
# {steps:["text",...]} is the documented shape and the one a small model most
# naturally emits. Regression: `.value.order` on a string threw "Cannot index
# string with string", so plan_create silently rejected the bare-string form.
# (Runs last — it leaves an active plan, which would pollute the decoration
# assertions above.)
bs=$(first_line "$(tool_dispatch plan_create '{"steps":["str-one","str-two","str-three"]}')")
[[ "$(printf '%s' "$bs" | jq -r '.ok')" == "true" ]] || fail "plan_create rejected bare-string steps: $bs"
[[ "$(printf '%s' "$bs" | jq -r '.data.steps[0].text')" == "str-one" ]] || fail "bare-string step text lost: $bs"
[[ "$(printf '%s' "$bs" | jq -r '.data.steps[1].order')" == "2" ]] || fail "bare-string step order not auto-assigned: $bs"

echo "plan_store_body OK"
exit 0
