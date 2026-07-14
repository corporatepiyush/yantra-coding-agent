# core/llm.sh — LLM loop (OpenAI-compatible), provider-routed by complexity.
#
# All LLM traffic goes through a provider resolved by complexity (see
# core/providers.sh). A call sticks to one URL for cache affinity and only
# rotates to the next provider when the current one is network-unreachable
# (curl transport error), never on an HTTP error code.

# _llm_require_provider COMPLEXITY -> prints "url\tmodel\ttoken" or returns 1.
# If no provider is configured/live, runs the unavailable flow (which may add a
# session URL) and retries once.
_llm_require_provider() {
    local complexity="$1" p
    p=$(provider_resolve "$complexity") && { printf '%s' "$p"; return 0; }
    llm_unavailable_flow || return 1
    p=$(provider_resolve "$complexity") && { printf '%s' "$p"; return 0; }
    return 1
}

# _llm_curl URL TOKEN BODY -> stores "http_code\n<body>" in the global _LLM_RESP
# and the curl transport exit code (0 = got an HTTP response of some kind) in the
# global _LLM_RC. It MUST set these via globals, not stdout: if it printed the
# body and were called in a command substitution ($(...)), its whole body would
# run in a subshell and the _LLM_RC assignment would evaporate — leaving _LLM_RC
# unset and crashing the caller under `set -u`.
_LLM_RESP=""
_LLM_RC=0
_llm_curl() {
    local url="$1" token="$2" body="$3"
    # The Authorization header goes through a header file (process substitution),
    # NEVER on the curl command line — argv is world-readable via `ps`, so an
    # inline Authorization header would leak the API key to every local process.
    # The body streams over stdin (--data-binary @-) for the same reason, and so
    # a long conversation can never overflow ARG_MAX.
    # --connect-timeout makes a DEAD provider fail in ~10s (and rotate) instead
    # of consuming the full --max-time budget; --proto pins http(s) so a
    # misconfigured provider URL can never make curl speak another scheme.
    _LLM_RESP=$(printf '%s' "$body" | curl -sS --max-time "$YCA_LLM_TIMEOUT" \
        --connect-timeout 10 --proto '=http,https' \
        -H @<(printf 'Authorization: Bearer %s\n' "$token") \
        -H "Content-Type: application/json" \
        --data-binary @- -w '\n%{http_code}' "$url/chat/completions" 2>/dev/null)
    _LLM_RC=$?
}

# _llm_is_unreachable RC -> 0 if the curl exit code means "not network reachable".
# 6=DNS, 7=connect refused, 28=timeout, plus other transport failures.
_llm_is_unreachable() {
    case "$1" in
        6|7|28|35|52|56) return 0 ;;
        0) return 1 ;;
        *) return 0 ;;
    esac
}

# _llm_log_usage MODEL TIER RESPONSE -> record REAL token usage as an event, so
# wf_harness_cost can report actual tokens per tier. The old cost workflow counted
# event ROWS and mislabeled them as tokens; the `.usage` block every OpenAI/ollama
# response returns was never read. Best-effort (never breaks the call).
_llm_log_usage() {
    local model="$1" tier="$2" resp="$3" pt ct
    pt=$(printf '%s' "$resp" | jq -r '.usage.prompt_tokens // 0' 2>/dev/null); [[ "$pt" =~ ^[0-9]+$ ]] || pt=0
    ct=$(printf '%s' "$resp" | jq -r '.usage.completion_tokens // 0' 2>/dev/null); [[ "$ct" =~ ^[0-9]+$ ]] || ct=0
    (( pt == 0 && ct == 0 )) && return 0
    local data; data=$(jq -cn --arg m "$model" --arg t "$tier" --argjson p "$pt" --argjson c "$ct" \
        '{model:$m,tier:$t,prompt_tokens:$p,completion_tokens:$c}' 2>/dev/null) || return 0
    db_exec "INSERT INTO events(level, kind, message, data_json) VALUES ('info','llm.usage', $(sql_quote "$model"), $(sql_quote "$data"));" 2>/dev/null || true
}

# _llm_request BODY COMPLEXITY -> prints the successful response body, or fails.
# Rotates providers on network-unreachability; retries same URL on timeout/429.
_llm_request() {
    local body="$1" complexity="$2"
    local provider url model token
    provider=$(_llm_require_provider "$complexity") || return 1
    local rotations=0
    while (( rotations < 6 )); do
        IFS=$'\t' read -r url model token <<< "$provider"
        # Inject the resolved model into the body (provider owns the model choice).
        local sbody; sbody=$(printf '%s' "$body" | jq -c --arg m "$model" '.model=$m' 2>/dev/null || printf '%s' "$body")
        local attempt=0
        while (( attempt < YCA_LLM_MAX_RETRIES )); do
            ((attempt++))
            local resp http rbody
            _llm_curl "$url" "$token" "$sbody"; resp="$_LLM_RESP"
            if _llm_is_unreachable "$_LLM_RC"; then
                # Timeout gets one same-URL retry before we give up on it.
                if [[ "$_LLM_RC" == "28" && $attempt -lt "$YCA_LLM_MAX_RETRIES" ]]; then
                    log_warn "LLM timeout ($url, attempt $attempt) — retrying"
                    sleep $((attempt*2)); continue
                fi
                log_warn "provider unreachable ($url, curl $_LLM_RC) — rotating"
                provider_mark_dead "$url"
                break
            fi
            http=$(printf '%s' "$resp" | tail -1)
            rbody=$(printf '%s' "$resp" | sed '$d')
            if [[ "$http" =~ ^2 ]]; then _llm_log_usage "$model" "$complexity" "$rbody"; printf '%s' "$rbody"; return 0; fi
            if [[ "$http" == "429" ]]; then
                log_warn "rate limited ($url, attempt $attempt)"; sleep $((attempt*3)); continue
            fi
            log_error "LLM HTTP $http from $url"
            return 1
        done
        # This provider exhausted/dead — rotate to the next live one.
        ((rotations++))
        provider=$(provider_resolve "$complexity") || { log_error "no live LLM provider remaining"; return 1; }
    done
    return 1
}

# llm_call MESSAGES [TOOLS] [COMPLEXITY] -> chat/completions with tools.
llm_call() {
    local messages="$1" tools="${2:-}" complexity="${3:-$YCA_CALL_COMPLEXITY}"
    local body
    if [[ -n "$tools" && "$tools" != "[]" ]]; then
        body=$(jq -n --argjson msgs "$messages" --argjson tools "$tools" \
            '{model:"", messages:$msgs, tools:$tools, tool_choice:"auto"}')
    else
        body=$(jq -n --argjson msgs "$messages" '{model:"", messages:$msgs}')
    fi
    # Opt-in: only sent when configured, so strict endpoints that reject the
    # field keep working by default.
    if [[ -n "$YCA_LLM_TEMPERATURE" ]]; then
        body=$(printf '%s' "$body" | jq -c --argjson t "$YCA_LLM_TEMPERATURE" '.temperature=$t' 2>/dev/null || printf '%s' "$body")
    fi
    _llm_request "$body" "$complexity"
}

# llm_analyze SYSTEM USER [MAX_TOKENS] [COMPLEXITY]
# Single-shot call (no tools) for LLM-backed tools. Returns assistant text.
# Defaults to the complexity of the dispatched call (mid for *_llm_* tools).
llm_analyze() {
    local system_prompt="$1" user_content="$2" max_tokens="${3:-4096}" complexity="${4:-$YCA_CALL_COMPLEXITY}" format="${5:-}"
    [[ -z "$system_prompt" ]] && { printf 'llm_analyze error: system_prompt required'; return 1; }
    [[ -z "$user_content" ]] && { printf 'llm_analyze error: user_content required'; return 1; }
    # mid is the natural floor for a dynamic (LLM-backed) tool.
    [[ "$(complexity_normalize "$complexity")" == "low" ]] && complexity="mid"
    local max_content=262144
    if [[ ${#user_content} -gt $max_content ]]; then
        user_content="${user_content:0:$max_content}
[...truncated: $(( ${#user_content} - max_content )) bytes omitted ...]"
    fi
    local messages body
    messages=$(jq -n --arg s "$system_prompt" --arg c "$user_content" \
        '[{role:"system",content:$s},{role:"user",content:$c}]')
    body=$(jq -n --argjson msgs "$messages" --argjson maxt "$max_tokens" \
        '{model:"", messages:$msgs, max_tokens:$maxt, temperature:0.3}')
    # Structured output: CONSTRAIN the model to JSON via response_format (OpenAI +
    # ollama /v1 both honor it), instead of only asking for JSON in the prompt.
    # format="json" -> any valid JSON; format=<schema-string> -> that JSON schema.
    if [[ "$format" == "json" ]]; then
        body=$(printf '%s' "$body" | jq -c '.response_format={type:"json_object"}' 2>/dev/null || printf '%s' "$body")
    elif [[ -n "$format" ]]; then
        body=$(printf '%s' "$body" | jq -c --argjson sch "$format" '.response_format={type:"json_schema",json_schema:{name:"out",strict:true,schema:$sch}}' 2>/dev/null || printf '%s' "$body")
    fi
    local out
    out=$(_llm_request "$body" "$complexity") || { printf '[LLM analysis unavailable]'; return 1; }
    # T10/F1: detect silent front-truncation (engine cut the prompt, dropping the
    # system prompt) by comparing what we sent to the provider's reported prompt
    # tokens. Warns with the num_ctx fix; never alters the result.
    llm_check_truncation "$(( ${#system_prompt} + ${#user_content} ))" "$out" || true
    printf '%s' "$out" | jq -r '.choices[0].message.content // "[LLM returned no content]"' 2>/dev/null || {
        printf '[LLM analysis unavailable: parse error]'; return 1
    }
}

# agent_turn_reminder [GOAL] — the anti-drift/anti-hallucination grounding
# rules. The loop that appended this each turn is gone (MCP-only amendment);
# the content is deliberately preserved as the MCP prompt "grounding"
# (prompts/get in commands/mcp.sh, playbook M5) — hosts append it to the tail
# of context where recency outweighs a decayed top-of-context system prompt.
agent_turn_reminder() {
    local goal="${1:-}"
    cat <<'EOF'
[reminder]
- Ground every claim in a file you've read or tool output you've seen this session. If you haven't verified it, say so or check — don't assert.
- Never invent paths, function names, flags, or APIs. If unsure something exists, confirm with a tool first.
- Trust the most recent tool output over anything you assumed earlier; the repo may have changed since.
- If tool output contradicts the request's premise (e.g. asked to fix something that is already fine), STOP and report the discrepancy as your answer — do not repeat calls hoping for a different result.
- "I don't know" and "I need to verify" are correct answers. Prefer them to a confident guess.
- If the request is ambiguous, state the interpretation you're acting on in one line before acting; ask only when the choice is load-bearing and you cannot verify it.
- Do only what was asked.
EOF
    [[ -n "$goal" ]] && printf -- '- Current objective: %s\n' "$goal"
    return 0
}

