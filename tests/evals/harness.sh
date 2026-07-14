#!/usr/bin/env bash
# T5: the evals seed — the measuring instrument for every [unmeasured] claim.
#
# Two run modes, both honest by construction:
#
#  scripted (default, CI): each task's RECORDED solution session is replayed
#    through the T4 MCP client against the real server in a scratch copy of the
#    fixture repo; success comes ONLY from the task's check.sh exit code.
#    Scripted rows carry tokens:null — there is no model, so recording token
#    counts would be fabrication (validate-row enforces this).
#
#  live (--live): a THIN tool loop drives a real engine (Ollama-compatible
#    /v1/chat/completions) with Yantra's tools fetched over MCP. Token counts
#    come ONLY from the response usage fields; a live row without usage>0 is
#    rejected, an unreachable engine records status:"error" (never "fail" —
#    dead providers must not poison success statistics). The thin driver is a
#    seed instrument: REPORTED numbers still require a real MCP host qualified
#    by checklist IV-B.1 — record that host in the host column when used.
#
# Row schema (validate-row): timestamp(number), task, condition, mode,
# model, engine, engine_version, host, host_version, status(success|fail|error),
# prompt_tokens/completion_tokens (null in scripted; numbers >0/>=0 in live
# non-error rows), fixture_checksum.
#
# Usage:
#   harness.sh checksum
#   harness.sh validate-row '<json>'
#   harness.sh run --results FILE [--live] [--sabotage] [--harness PATH]
set -Euo pipefail

EVALS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$EVALS_DIR/../.." && pwd)"
FIXTURES="$EVALS_DIR/fixtures"
CLIENT="$PROJ_ROOT/tests/mcp_client/client.sh"
YANTRA="${YCA_EVAL_HARNESS:-$PROJ_ROOT/yantra-mcp-server.sh}"
TASKS=(fix_broken_test optimize_query add_similar)
DRIVER_NAME="yantra-thin-driver" DRIVER_VERSION="1.0"

fixture_checksum() {
    (cd "$FIXTURES" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 | cut -d' ' -f1)
}

# validate_row JSON -> 0 valid / 1 invalid (reason on stderr). The contract that
# makes fabricated numbers structurally impossible.
validate_row() {
    local row="$1" err
    err=$(printf '%s' "$row" | jq -r '
        def need($f): if (.[$f] // "") == "" or (.[$f] | type) != "string" then "missing/blank field: \($f)" else empty end;
        [ need("task"), need("condition"), need("mode"), need("model"),
          need("engine"), need("engine_version"), need("host"),
          need("host_version"), need("status"), need("fixture_checksum"),
          (if (.timestamp | type) != "number" then "timestamp must be a number" else empty end),
          (if (.status | IN("success","fail","error")) then empty else "status must be success|fail|error, got \(.status)" end),
          (if .mode == "scripted" and (.prompt_tokens != null or .completion_tokens != null)
             then "scripted rows must carry tokens:null (no model ran — token counts would be fabricated)" else empty end),
          (if .mode == "live" and .status != "error"
             and (((.prompt_tokens // 0) | if type == "number" then . else 0 end) <= 0)
             then "live row without usage-reported prompt_tokens > 0 is rejected" else empty end),
          (if .mode == "live" and .status != "error"
             and (((.completion_tokens // -1) | if type == "number" then . else -1 end) < 0)
             then "live row needs completion_tokens >= 0 from usage" else empty end)
        ] | .[0] // empty' 2>&1) || { echo "invalid JSON row" >&2; return 1; }
    [[ -z "$err" ]] || { echo "$err" >&2; return 1; }
    return 0
}

# record_row RESULTS_FILE JSON — validate, then append. An invalid row aborts
# the run: silently dropping data is as dishonest as inventing it.
record_row() {
    local file="$1" row="$2"
    validate_row "$row" || { echo "FATAL: refusing to record invalid row: $row" >&2; exit 1; }
    printf '%s' "$row" | jq -c . >> "$file"
}

row_json() {  # task condition mode model engine engine_ver host host_ver status ptok ctok checksum
    jq -cn --arg task "$1" --arg cond "$2" --arg mode "$3" --arg model "$4" \
        --arg eng "$5" --arg engv "$6" --arg host "$7" --arg hostv "$8" \
        --arg st "$9" --argjson pt "${10}" --argjson ct "${11}" --arg ck "${12}" \
        '{timestamp: (now | floor), task:$task, condition:$cond, mode:$mode,
          model:$model, engine:$eng, engine_version:$engv, host:$host,
          host_version:$hostv, status:$st, prompt_tokens:$pt,
          completion_tokens:$ct, fixture_checksum:$ck}'
}

# task_status TASK SCRATCH -> success|fail, decided ONLY by the fixture's
# programmatic check (never by a model, never by default).
task_status() {
    local task="$1" scratch="$2"
    if (cd "$scratch" && bash "$FIXTURES/$task/check.sh" >/dev/null 2>&1); then
        printf 'success'
    else
        printf 'fail'
    fi
}

fresh_scratch() {  # TASK -> path
    local d; d=$(mktemp -d "${TMPDIR:-/tmp}/yca_eval.XXXXXX")
    cp -R "$FIXTURES/$1/repo/." "$d/"
    printf '%s' "$d"
}

# ── Scripted condition runners ───────────────────────────────────────────────
run_scripted_with_yantra() {   # TASK [SCRIPT_NAME] -> success|fail
    local task="$1" script="${2:-with_yantra.mcp}" scratch status
    scratch=$(fresh_scratch "$task")
    (cd "$scratch" && bash "$CLIENT" \
        --server "HARNESS_UPDATE_ENABLED=false bash '$YANTRA' --ui mcp" \
        --log "$scratch/.frames.log" --script "$FIXTURES/$task/scripts/$script" \
        --caps elicitation --elicit accept >/dev/null 2>&1) || true
    status=$(task_status "$task" "$scratch")
    rm -rf "$scratch"
    printf '%s' "$status"
}

run_scripted_without_yantra() {   # TASK -> success|fail
    local task="$1" scratch status
    scratch=$(fresh_scratch "$task")
    (cd "$scratch" && bash "$FIXTURES/$task/scripts/without_yantra.sh" >/dev/null 2>&1) || true
    status=$(task_status "$task" "$scratch")
    rm -rf "$scratch"
    printf '%s' "$status"
}

# ── Live mode (thin driver; see header caveat) ───────────────────────────────
OLLAMA_URL="${YCA_EVAL_OLLAMA_URL:-http://localhost:11434}"

engine_version() { curl -s --max-time 3 "$OLLAMA_URL/api/version" | jq -r '.version // "unknown"' 2>/dev/null || printf 'unknown'; }
model_reachable() { curl -s --max-time 3 "$OLLAMA_URL/api/tags" | jq -e --arg m "$1" '.models[]? | select(.name == $m)' >/dev/null 2>&1; }

# mcp_once FRAME... -> the server's responses (one session per call; consent is
# pre-granted for eval runs — the eval measures the model, not the gate).
mcp_once() {
    { printf '%s\n' '{"jsonrpc":"2.0","id":"i","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"thin-driver","version":"1.0"}}}'
      printf '%s\n' "$@"
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}'
    } | HARNESS_UPDATE_ENABLED=false YCA_AUTO_CONFIRM=true timeout 120 bash "$YANTRA" --ui mcp 2>/dev/null
}

# openai_tools -> Yantra's MCP tool list converted to OpenAI tool format.
openai_tools() {
    mcp_once '{"jsonrpc":"2.0","id":"t","method":"tools/list","params":{}}' \
        | jq -c 'select(.id == "t") | [.result.tools[]
            | {type:"function", function:{name:.name, description:.description, parameters:.inputSchema}}]'
}

# live_chat MODEL MESSAGES TOOLS_OR_NULL -> raw response JSON (rc 1 on HTTP fail)
live_chat() {
    local model="$1" messages="$2" tools="$3" body
    body=$(jq -cn --arg m "$model" --argjson msgs "$messages" --argjson t "$tools" \
        '{model:$m, messages:$msgs, stream:false} + (if $t != null then {tools:$t} else {} end)')
    curl -s --max-time 180 -H 'Content-Type: application/json' \
        --data-binary "$body" "$OLLAMA_URL/v1/chat/completions"
}

# run_live TASK CONDITION MODEL -> "STATUS PTOK CTOK" (tokens from usage only)
run_live() {
    local task="$1" cond="$2" model="$3"
    local scratch prompt messages resp msg ptok=0 ctok=0 turn tools=null status
    scratch=$(fresh_scratch "$task")
    prompt=$(cat "$FIXTURES/$task/prompt.txt")
    if [[ "$cond" == "with_yantra" ]]; then
        tools=$(cd "$scratch" && openai_tools)
        [[ -n "$tools" && "$tools" != "null" ]] || { rm -rf "$scratch"; echo "error 0 0"; return 0; }
        messages=$(jq -cn --arg p "$prompt" '[{role:"system",content:"You are a coding agent. Use the provided tools to complete the task. File paths are relative to the project root."},{role:"user",content:$p}]')
    else
        messages=$(jq -cn --arg p "$prompt" '[{role:"user",content:($p + "\n\nReply with ONE fenced ```bash code block containing shell commands that fix this; the commands run from the project root.")}]')
    fi
    for turn in 1 2 3 4 5 6; do
        resp=$(live_chat "$model" "$messages" "$tools") || { rm -rf "$scratch"; echo "error 0 0"; return 0; }
        printf '%s' "$resp" | jq -e '.choices[0]' >/dev/null 2>&1 || { rm -rf "$scratch"; echo "error 0 0"; return 0; }
        ptok=$(( ptok + $(printf '%s' "$resp" | jq -r '.usage.prompt_tokens // 0') ))
        ctok=$(( ctok + $(printf '%s' "$resp" | jq -r '.usage.completion_tokens // 0') ))
        msg=$(printf '%s' "$resp" | jq -c '.choices[0].message')
        if [[ "$cond" == "without_yantra" ]]; then
            # single shot: extract the fenced block and run it in the scratch dir
            printf '%s' "$msg" | jq -r '.content // ""' \
                | awk '/^```/{f=!f; next} f' \
                | (cd "$scratch" && timeout 60 bash >/dev/null 2>&1) || true
            break
        fi
        if printf '%s' "$msg" | jq -e '.tool_calls[0]' >/dev/null 2>&1; then
            messages=$(jq -cn --argjson m "$messages" --argjson a "$msg" '$m + [$a]')
            local n i name args call_id out result_text
            n=$(printf '%s' "$msg" | jq '.tool_calls | length')
            for (( i=0; i<n; i++ )); do
                name=$(printf '%s' "$msg" | jq -r ".tool_calls[$i].function.name")
                args=$(printf '%s' "$msg" | jq -r ".tool_calls[$i].function.arguments")
                call_id=$(printf '%s' "$msg" | jq -r ".tool_calls[$i].id // \"call_$i\"")
                printf '%s' "$args" | jq -e . >/dev/null 2>&1 || args='{}'
                out=$(cd "$scratch" && mcp_once "$(jq -cn --arg n "$name" --argjson a "$args" \
                    '{jsonrpc:"2.0",id:"c",method:"tools/call",params:{name:$n,arguments:$a}}')")
                result_text=$(printf '%s' "$out" | jq -r 'select(.id == "c") | .result.content[0].text // "no output"' | head -c 8000)
                messages=$(jq -cn --argjson m "$messages" --arg id "$call_id" --arg t "${result_text:-no output}" \
                    '$m + [{role:"tool", tool_call_id:$id, content:$t}]')
            done
        else
            break   # no tool calls -> the model thinks it is done
        fi
    done
    status=$(task_status "$task" "$scratch")
    rm -rf "$scratch"
    echo "$status $ptok $ctok"
}

# ── Commands ─────────────────────────────────────────────────────────────────
cmd="${1:-}"; shift || true
case "$cmd" in
    checksum)
        fixture_checksum; exit 0 ;;
    validate-row)
        validate_row "${1:?need a JSON row}" && echo valid ;;
    run)
        RESULTS="" LIVE=false SABOTAGE=false
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --results) RESULTS="$2"; shift 2 ;;
                --live)    LIVE=true; shift ;;
                --sabotage) SABOTAGE=true; shift ;;
                --harness) YANTRA="$2"; shift 2 ;;
                *) echo "unknown option: $1" >&2; exit 1 ;;
            esac
        done
        [[ -n "$RESULTS" ]] || { echo "need --results FILE" >&2; exit 1; }
        : > "$RESULTS"
        ck_before=$(fixture_checksum)

        for task in "${TASKS[@]}"; do
            st=$(run_scripted_with_yantra "$task")
            record_row "$RESULTS" "$(row_json "$task" with_yantra scripted recorded-session none none mcp_test_client 2.0 "$st" null null "$ck_before")"
            st=$(run_scripted_without_yantra "$task")
            record_row "$RESULTS" "$(row_json "$task" without_yantra scripted recorded-session none none mcp_test_client 2.0 "$st" null null "$ck_before")"
        done

        if $SABOTAGE; then
            # negative control: a session that makes no edit MUST record "fail" —
            # proof that success is measured, never assumed.
            st=$(run_scripted_with_yantra fix_broken_test sabotage.mcp)
            record_row "$RESULTS" "$(row_json fix_broken_test with_yantra scripted sabotage-session none none mcp_test_client 2.0 "$st" null null "$ck_before")"
        fi

        if $LIVE; then
            engv=$(engine_version)
            IFS=',' read -ra models <<< "${YCA_EVAL_MODELS:-}"
            [[ ${#models[@]} -gt 0 && -n "${models[0]}" ]] || { echo "live mode: set YCA_EVAL_MODELS=model1,model2" >&2; exit 1; }
            for model in "${models[@]}"; do
                for task in "${TASKS[@]}"; do
                    for cond in with_yantra without_yantra; do
                        if ! model_reachable "$model"; then
                            record_row "$RESULTS" "$(row_json "$task" "$cond" live "$model" ollama "$engv" "$DRIVER_NAME" "$DRIVER_VERSION" error null null "$ck_before")"
                            continue
                        fi
                        read -r st pt ct <<< "$(run_live "$task" "$cond" "$model")"
                        if [[ "$st" == "error" || "$pt" -le 0 ]]; then
                            # engine dead mid-run, or no usage reported — either
                            # way this is unusable evidence: error, never fail
                            record_row "$RESULTS" "$(row_json "$task" "$cond" live "$model" ollama "$engv" "$DRIVER_NAME" "$DRIVER_VERSION" error null null "$ck_before")"
                        else
                            record_row "$RESULTS" "$(row_json "$task" "$cond" live "$model" ollama "$engv" "$DRIVER_NAME" "$DRIVER_VERSION" "$st" "$pt" "$ct" "$ck_before")"
                        fi
                    done
                done
            done
        fi

        ck_after=$(fixture_checksum)
        [[ "$ck_before" == "$ck_after" ]] \
            || { echo "FATAL: fixtures mutated during the run ($ck_before -> $ck_after); A/B comparison is void" >&2; exit 1; }
        echo "results: $RESULTS ($(wc -l < "$RESULTS" | tr -d ' ') rows)" >&2 ;;
    *)
        echo "usage: harness.sh checksum | validate-row JSON | run --results FILE [--live] [--sabotage]" >&2
        exit 1 ;;
esac
