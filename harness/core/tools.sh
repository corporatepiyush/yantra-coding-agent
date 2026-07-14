# core/tools.sh — Tool registry, JSON builder, dispatcher

declare -A YCA_TOOL_REGISTRY
declare -A YCA_TOOL_SCHEMAS
# YCA_CACHED_TOOLS_JSON_BY_AGENT is declared in constants.sh (set -u safe, sourced first).

tool_register() {
    # $1=name $2=fn $3=schema $4=danger $5=agents $6=category $7=complexity(high|mid|low)
    # complexity defaults to low (static tool, no LLM). LLM-backed tools pass mid/high.
    # Canonical values skip the $(complexity_normalize) subshell — registration
    # runs ~500× at every boot, so the fork-free path keeps startup fast.
    local _cx="${7:-low}"
    case "$_cx" in
        high|mid|low) ;;
        *) _cx=$(complexity_normalize "$_cx") ;;
    esac
    YCA_TOOL_REGISTRY[$1]="$2|$4|${5:-all}|${6:-core}|$_cx"
    YCA_TOOL_SCHEMAS[$1]="$3"
}

# tool_complexity NAME -> effective complexity (config override wins over registered).
tool_complexity() {
    local name="$1"
    if [[ -n "${YCA_COMPLEXITY_OVERRIDE[$name]:-}" ]]; then
        complexity_normalize "${YCA_COMPLEXITY_OVERRIDE[$name]}"; return 0
    fi
    local info="${YCA_TOOL_REGISTRY[$name]:-}"
    [[ -z "$info" ]] && { printf 'low'; return 0; }
    printf '%s' "${info##*|}"
}

# Reset the per-agent tools cache. Call after any toggle/category change.
tools_invalidate_cache() {
    YCA_CACHED_TOOLS_JSON_BY_AGENT=()
}

# Map toolchain_detect() output tokens to tool categories.
# toolchain_detect prints space-separated: node typescript python rust go c-cpp ruby php java scala kotlin
_tools_lang_categories() {
    local tools tc
    tools=$(toolchain_detect 2>/dev/null || printf '')
    for tc in $tools; do
        case "$tc" in
            node|typescript) printf 'nodejs ' ;;
            python)          printf 'python ' ;;
            rust)            printf 'rust ' ;;
            go)              printf 'golang ' ;;
            c-cpp)           printf 'ccpp ' ;;
            ruby)            printf 'ruby ' ;;
            php)             printf 'php ' ;;
            java)            printf 'java ' ;;
            scala)           printf 'scala ' ;;
            kotlin)          printf 'kotlin ' ;;
        esac
    done
}

# Auto-enable runtime categories for detected languages (idempotent, not persisted).
# Lets build_tools_json and tool_dispatch agree, and makes tools.status truthful.
# Must be called from the main shell (not a subshell) — e.g. once at startup.
tools_autodetect_enable() {
    local lang
    for lang in $(_tools_lang_categories); do
        [[ "${YCA_CAT_ENABLED[$lang]:-0}" != "1" ]] && YCA_CAT_ENABLED[$lang]=1
    done
}

# Build tools JSON filtered by enabled categories + agent allowlist (per-agent cached).
# - core always included.
# - detected-language categories auto-included (sends only the relevant lang's tools).
# - parameterless tools omit `parameters` (saves ~25 tokens each).
# NOTE: call tools_autodetect_enable() once at startup so dispatch agrees.
build_tools_json() {
    local agent="${1:-all}"
    [[ -n "${YCA_CACHED_TOOLS_JSON_BY_AGENT[$agent]:-}" ]] && { printf '%s' "${YCA_CACHED_TOOLS_JSON_BY_AGENT[$agent]}"; return 0; }
    local name info fn danger agents category complexity schema
    local -a pairs=()
    # Core tools first, remainder sorted. Bash assoc-array order is arbitrary,
    # and small models have strong position bias — they pick from the HEAD of
    # the tool list (fuzz: llama3.2 at 32 tools chose rust_cargo_tree with
    # invented args when rust led, but read({path}) correctly when core led).
    # A stable order also keeps the wire bytes identical across sessions,
    # which keeps the provider's prefix cache warm.
    local -a _core_names=() _other_names=()
    while IFS= read -r name; do
        IFS='|' read -r fn danger agents category complexity <<< "${YCA_TOOL_REGISTRY[$name]}"
        if [[ "$category" == "core" ]]; then _core_names+=("$name"); else _other_names+=("$name"); fi
    done < <(printf '%s\n' "${!YCA_TOOL_REGISTRY[@]}" | sort)
    for name in ${_core_names[@]+"${_core_names[@]}"} ${_other_names[@]+"${_other_names[@]}"}; do
        info="${YCA_TOOL_REGISTRY[$name]}"
        IFS='|' read -r fn danger agents category complexity <<< "$info"
        # Filter by category enabled (core + detected langs + explicitly enabled infra)
        if [[ -n "$category" ]] && [[ "${YCA_CAT_ENABLED[$category]:-0}" != "1" ]]; then
            continue
        fi
        # Filter by agent allowlist
        if [[ "$agents" != "all" ]]; then
            local a allowed=0
            IFS=',' read -ra arr <<< "$agents"
            for a in "${arr[@]}"; do [[ "$a" == "$agent" ]] && { allowed=1; break; }; done
            [[ "$allowed" == "0" ]] && continue
        fi
        schema="${YCA_TOOL_SCHEMAS[$name]}"
        # Omit `parameters` for parameterless tools (saves ~5k tokens/call across the registry).
        # Empty schema canonical form: {"type":"object","properties":{}} — passed
        # as "" so the single jq below emits the {name}-only form.
        [[ "$schema" == '{"type":"object","properties":{}}' ]] && schema=""
        pairs+=("$name" "$schema")
    done
    # ONE jq builds the whole array from (name, schema) positional pairs — this
    # used to fork a jq per tool (~100+ per cold build). A malformed schema
    # degrades to {name} instead of poisoning the array.
    # Per the OpenAI spec the schema must sit under function.PARAMETERS —
    # flattening it into the function object means a compliant server reads no
    # parameters at all and the model has to guess argument names. A top-level
    # "description" in the schema is hoisted to function.description.
    local json='[]'
    if [[ ${#pairs[@]} -gt 0 ]]; then
        json=$(jq -cn '[$ARGS.positional as $a | range(0; $a|length; 2) as $i |
            {type:"function", function:(
                (if $a[$i+1] == "" then null else (($a[$i+1] | fromjson?) // null) end) as $s
                | if $s == null then {name:$a[$i]}
                  else {name:$a[$i]}
                       + (if $s.description then {description:$s.description} else {} end)
                       + {parameters:($s | del(.description))}
                  end)}]' \
            --args "${pairs[@]}" 2>/dev/null) || json='[]'
    fi
    YCA_CACHED_TOOLS_JSON_BY_AGENT[$agent]="$json"
    printf '%s' "$json"
}

# _tool_exec NAME FN ARGS_JSON — the shared execution core: sets the routing
# complexity, maps args to the generic positional slots + raw JSON, runs the tool
# fn, and always returns its combined output + exit code. Used by both the gated
# dispatcher (LLM path) and the gate-bypassing composer (workflow path).
_tool_exec() {
    local name="$1" fn="$2" args_json="$3"
    local _saved_complexity="$YCA_CALL_COMPLEXITY"

    # T7: coerce obvious type mistakes (string-encoded number/bool/array) per the
    # schema, THEN validate the coerced args. Coercion means a small model that
    # sends "8080" for an integer port succeeds instead of getting an error. The
    # coerced JSON is what the tool receives (positional slots + $5 below).
    args_json=$(coerce_arguments "$args_json" "$name")
    local _verr
    if ! _verr=$(validate_args_against_schema "$name" "$args_json" 2>&1); then
        printf '%s' "$_verr"
        YCA_CALL_COMPLEXITY="$_saved_complexity"
        return 1
    fi

    YCA_CALL_COMPLEXITY=$(tool_complexity "$name")
    # ONE jq extracts all four positional slots (was 4 forks per dispatch —
    # this is the hottest path in the harness). Fields are joined with the
    # \u001f unit separator so multi-line values (e.g. .content) survive intact.
    local -a _slots=()
    mapfile -d $'\x1f' -t _slots < <(printf '%s' "$args_json" | jq -j '
        [ (.path // .command // .url // .pattern // .host // .query // .sql // .domain // .target // .container // .pod // .resource // .file // .src // ""),
          (.content // .new_string // .replacement // .new // .name // .service // .lines // .port // .dst // .days // .table // .description // ""),
          (.old_string // .replace_all // .remote_host // .remote_port // .local // .line // .old // .lang // .kind // .dir // .end // .value // ""),
          (.timeout // .fn // .start // .notes // .version // .category // .entries // "") ]
        | map(tostring) | join("\u001f")' 2>/dev/null || true)
    local arg1="${_slots[0]-}" arg2="${_slots[1]-}" arg3="${_slots[2]-}" arg4="${_slots[3]-}"
    # The generic positional extraction carries ~4 fixed field names and collides
    # when a tool needs two fields from the same priority group (e.g. {file, sql}).
    # Tools read exact fields via tool_arg (backed by YCA_TOOL_ARGS_JSON / $5).
    # stdin is redirected from /dev/null: a tool (or a subprocess it spawns —
    # `git shortlog` and `git log` with no range, `wc`, `cat`, `sort` read stdin
    # when it is not a TTY) must NEVER be able to drain the caller's stdin. On
    # the MCP surface the caller's stdin IS the JSON-RPC frame stream, and a
    # single stdin-reading tool would silently swallow every subsequent request
    # and end the session (found by black-box sweep: quality_churn ate the
    # stream via `git shortlog -sn`). Redirect here so ALL 665 tools are safe.
    local out rc
    out=$(YCA_TOOL_ARGS_JSON="$args_json" "$fn" "$arg1" "${arg2:-}" "${arg3:-}" "${arg4:-}" "$args_json" 2>&1 </dev/null)
    rc=$?
    YCA_CALL_COMPLEXITY="$_saved_complexity"
    printf '%s' "$out"
    return $rc
}

# danger_needs_confirm TOKEN -> 0 if this danger level must get consent before it
# runs. writes|destructive|dangerous ALL require it; only `safe` is ungated.
# Worst case this prevents: the machine-mode gate used to match ONLY "writes", so
# a tool its author flagged with the MORE-severe `destructive`/`dangerous`
# (s3_delete, perf_benchmark, docker_prune, …) fell straight through the consent gate
# — the most dangerous tools had the weakest guard. Guarded by test_danger_gate.sh.
danger_needs_confirm() {
    case "$1" in
        writes|destructive|dangerous) return 0 ;;
        *) return 1 ;;
    esac
}

# tool_dispatch NAME ARGS — the LLM-facing entry: enforces the category gate, logs
# the call, then executes. Always returns the tool's output (success OR failure).
tool_dispatch() {
    local name="$1" args_json="$2"
    [[ -z "$name" ]] && { printf 'tool name required'; return 1; }
    local info="${YCA_TOOL_REGISTRY[$name]:-}"
    if [[ -z "$info" ]]; then
        logmsg "$(c_warn "$SYM_WARN unknown tool: $name")"
        printf 'unknown tool: %s' "$name"
        return 1
    fi
    local fn danger agents category complexity
    IFS='|' read -r fn danger agents category complexity <<< "$info"
    if [[ -n "$category" ]] && [[ "${YCA_CAT_ENABLED[$category]:-0}" != "1" ]]; then
        printf 'tool category %s disabled' "$category"
        return 1
    fi
    # Machine-mode consent gate for every consequential tool (writes/destructive/
    # dangerous), not just the core ones that confirm internally. Without this, an
    # unconsented session that denies `bash` can be bypassed via an ungated tool
    # (observed live: the model fixed files through rust_cargo_fmt after bash was
    # denied). The token set matters: matching only "writes" let the MORE-severe
    # destructive/dangerous tools (s3_delete, perf_benchmark, …) fall through — the
    # gate now keys on danger_needs_confirm. Interactive mode is unchanged — the
    # user is present to see what runs.
    # BOTH machine surfaces are gated: json (NDJSON) AND mcp. On MCP, consent is
    # meant to be an elicitation (D5); until that ships, the safe default is
    # deny-with-explanation — otherwise a non-core writes tool (brew_*, s3_delete)
    # runs unconfirmed over MCP, reopening the very bypass this gate closes.
    if danger_needs_confirm "$danger" \
        && [[ "$YCA_UI_MODE" == "json" || "$YCA_UI_MODE" == "mcp" ]] \
        && [[ "$YCA_AUTO_CONFIRM" != "true" ]]; then
        confirm_denied_msg
        return 1
    fi
    log_tool_call "$name" "$args_json"
    # T12: decorate the host-facing result with the active plan's current step.
    # Only host-facing dispatches are decorated; workflow-internal tool_invoke
    # composition is not. Decoration is a no-op (byte-identical) when no plan is
    # active, and is never persisted. _tool_exec already strips trailing newlines
    # via its own capture, so this added capture removes nothing further.
    local _out _rc _dec
    _out=$(_tool_exec "$name" "$fn" "${args_json:-$YCA_EMPTY_JSON}"); _rc=$?
    # T12 decorate the host-facing result with the active plan's current step,
    # then T10 apply the result budget: a large result spills to a file and the
    # model gets a preview + path notice (MCP builds a resource link instead —
    # result_budget is a no-op under --ui mcp).
    _dec=$(plan_decorate "$_out")
    result_budget "$_dec"
    return $_rc
}

# tool_invoke NAME [ARGS_JSON] — composition entry: call ANY registered tool by
# name (with JSON args) from a workflow or another tool, BYPASSING the category
# gate (the internal caller, not the user's toggles, decides). Returns the tool's
# text output + exit code. This is the single-responsibility seam that makes
# every tool embeddable/reusable. See also the `batch` core tool for LLM-driven
# composition.
tool_invoke() {
    local name="$1" args_json="${2:-$YCA_EMPTY_JSON}"
    [[ -z "$name" ]] && { printf 'tool name required'; return 1; }
    local info="${YCA_TOOL_REGISTRY[$name]:-}"
    [[ -z "$info" ]] && { printf 'unknown tool: %s' "$name"; return 1; }
    _tool_exec "$name" "${info%%|*}" "$args_json"
}

# tool_arg FIELD [DEFAULT] — extract a named field from the current tool call's
# raw args JSON (set by tool_dispatch). Lets tools read precise fields regardless
# of the generic positional mapping. Usage inside a tool fn:
#   local sql; sql=$(tool_arg sql "SELECT 1")
tool_arg() {
    local field="$1" default="${2:-}" val
    val=$(printf '%s' "${YCA_TOOL_ARGS_JSON:-$YCA_EMPTY_JSON}" | jq -r --arg f "$field" '.[$f] // empty' 2>/dev/null || true)
    printf '%s' "${val:-$default}"
}
