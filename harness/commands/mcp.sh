#!/usr/bin/env bash
# commands/mcp.sh — MCP server surface (T8 build half). JSON-RPC 2.0 over stdio.
#
# Spec revision is pinned in ONE place (YCA_MCP_PROTOCOL_VERSION + mcp_initialize)
# so the 2026-07-28 stateless migration is a small diff, not a rewrite.
#
# What this surface does beyond a dumb bridge:
#  - consent (D5): a writes-class tool/workflow triggers an elicitation request
#    when the host advertised the capability; hosts without it get the same
#    deny-with-explanation the NDJSON surface produces (fail-closed parity).
#  - workflows are callable as tools named wf__<id> (MCP names cannot contain
#    dots) through a reverse map built from the workflow registry.
#  - danger levels ride along as advisory tool annotations; server-side gating
#    stays authoritative (the annotation is a hint, never the gate).
#  - tool stderr becomes notifications/message frames, so results stay clean and
#    stdout stays a pure JSON-RPC line stream.
#  - T10: an oversized result spills to a file and returns as a resource link.
#  - T12: plan://current resolves to the live plan.
#
# Known T8 remainders (deliberate): sampling for the
# *_llm_* tools (hosts without it — i.e. all, today — fall back to the provider
# profile, which is the D5-documented fallback), prompts/* (skills have no
# listable registry yet), and roots re-scanning. The loop-removal half (T8-b/c)
# is evidence-gated on T5 per D12/M2 and must not ship before those numbers.

YCA_MCP_PROTOCOL_VERSION="2025-11-25"
YCA_MCP_SRV_ID=1000              # ids for server->client requests (elicitation)
declare -a YCA_MCP_PENDING=()    # client requests that arrived mid-elicitation
declare -A YCA_MCP_WFMAP=()      # wf__<mangled> -> workflow id (reverse map)

# ── Frame primitives ─────────────────────────────────────────────────────────
# The request id is carried as RAW JSON ("7", "\"abc\"", "0", "null") so string
# ids, numeric ids, and id 0 all round-trip exactly (strict clients reject a
# response whose id type differs from the request's).

_mcp_send() { printf '%s\n' "$1"; }

_mcp_reply() {   # ID_JSON RESULT_JSON
    _mcp_send "$(jq -cn --argjson id "$1" --argjson r "$2" \
        '{jsonrpc:"2.0",id:$id,result:$r}')"
}

_mcp_error() {   # ID_JSON CODE MESSAGE
    _mcp_send "$(jq -cn --argjson id "$1" --argjson c "$2" --arg m "$3" \
        '{jsonrpc:"2.0",id:$id,error:{code:$c,message:$m}}')"
}

# _mcp_text_result ID_JSON TEXT IS_ERROR — the standard tools/call reply.
# A successful oversized result spills to a file and returns as a resource link
# + short inline preview (T10); a failed spill degrades to inline text.
_mcp_text_result() {
    local id_json="$1" text="$2" is_error="$3"
    if [[ "$is_error" == "false" ]] && result_over_cap "$text"; then
        local sid preview bytes="${#text}"
        preview=$(_utf8_trim "$text" "$YCA_RESULT_PREVIEW")
        if sid=$(spill_write "$text"); then
            _mcp_reply "$id_json" "$(jq -cn --arg pv "$preview" --arg n "$bytes" --arg sp "spill://$sid" \
                '{content:[
                    {type:"text",text:($pv+"\n… ["+$n+"-byte result — read the resource link for the full output]")},
                    {type:"resource_link",uri:$sp,name:"full tool result",mimeType:"text/plain"}
                 ],isError:false}')"
            return 0
        fi
    fi
    _mcp_reply "$id_json" "$(jq -cn --arg t "$text" --argjson e "$is_error" \
        '{content:[{type:"text",text:$t}],isError:$e}')"
}

# _mcp_emit_stderr FILE — route captured tool/workflow stderr to logging
# notifications (bounded: a runaway tool must not flood the host).
_mcp_emit_stderr() {
    local file="$1" line n=0
    [[ -s "$file" ]] || return 0
    while IFS= read -r line && (( n < 20 )); do
        [[ -n "$line" ]] || continue
        _mcp_send "$(jq -cn --arg m "${line:0:2000}" \
            '{jsonrpc:"2.0",method:"notifications/message",params:{level:"warning",logger:"yantra",data:{message:$m}}}')"
        n=$((n+1))
    done < "$file"
}

# ── Handshake (the ONE place that knows the spec revision) ──────────────────
# A capability counts as advertised when its key is present and not false —
# spec-shaped clients send objects ({"sampling":{}}), older ones booleans.
mcp_initialize() {
    local line="$1" id_json="$2" cap
    for cap in sampling elicitation roots; do
        if printf '%s' "$line" | jq -e --arg c "$cap" \
            '.params.capabilities | (has($c) and .[$c] != false)' >/dev/null 2>&1; then
            case "$cap" in
                sampling)    YCA_MCP_SAMPLING=true ;;
                elicitation) YCA_MCP_ELICITATION=true ;;
                roots)       YCA_MCP_ROOTS=true ;;
            esac
        fi
    done
    _mcp_reply "$id_json" "$(jq -cn --arg proto "$YCA_MCP_PROTOCOL_VERSION" --arg v "${YCA_VERSION:-unknown}" \
        '{protocolVersion:$proto,
          serverInfo:{name:"yantra",version:$v},
          capabilities:{tools:{listChanged:true},resources:{},prompts:{},logging:{}}}')"
}

# ── Prompts ──────────────────────────────────────────────────────────────────
# "grounding" — the agent loop's per-turn anti-drift reminder, preserved as a
# prompt when the loop was removed (M5): hosts should append it to the TAIL of
# context, where recency outweighs a decayed top-of-context system prompt.
mcp_prompts_list() {
    _mcp_reply "$1" '{"prompts":[{"name":"grounding","description":"Anti-drift grounding rules for tool-using sessions; append to the tail of context each turn","arguments":[{"name":"goal","description":"the current objective, restated each turn","required":false}]}]}'
}

mcp_prompts_get() {
    local id_json="$1" line="$2" name goal text
    name=$(printf '%s' "$line" | jq -r '.params.name // empty')
    if [[ "$name" != "grounding" ]]; then
        _mcp_error "$id_json" -32602 "Unknown prompt: $name"
        return 0
    fi
    goal=$(printf '%s' "$line" | jq -r '.params.arguments.goal // empty')
    text=$(agent_turn_reminder "$goal")
    _mcp_reply "$id_json" "$(jq -cn --arg t "$text" \
        '{description:"grounding rules", messages:[{role:"user",content:{type:"text",text:$t}}]}')"
}

# ── tools/list — MCP-shaped defs + advisory annotations ─────────────────────
# Same visibility and stable order as build_tools_json (core first, then sorted;
# byte-stable across connections so the host's list cache stays valid). Danger
# maps to annotations: safe→readOnlyHint; destructive/dangerous→destructiveHint;
# writes→both false (it changes things, reversibly). Advisory only — the gate
# in tool_dispatch/_mcp_confirm stays authoritative.
mcp_tools_list() {
    local id_json="$1"
    local name info fn danger agents category complexity
    local -a triples=() core_names=() other_names=()
    while IFS= read -r name; do
        IFS='|' read -r fn danger agents category complexity <<< "${YCA_TOOL_REGISTRY[$name]}"
        [[ -n "$category" && "${YCA_CAT_ENABLED[$category]:-0}" != "1" ]] && continue
        if [[ "$category" == "core" ]]; then core_names+=("$name"); else other_names+=("$name"); fi
    done < <(printf '%s\n' "${!YCA_TOOL_REGISTRY[@]}" | sort)
    for name in ${core_names[@]+"${core_names[@]}"} ${other_names[@]+"${other_names[@]}"}; do
        IFS='|' read -r fn danger agents category complexity <<< "${YCA_TOOL_REGISTRY[$name]}"
        triples+=("$name" "${YCA_TOOL_SCHEMAS[$name]:-}" "$danger")
    done
    local tools='[]'
    if [[ ${#triples[@]} -gt 0 ]]; then
        tools=$(jq -cn '[$ARGS.positional as $a | range(0; $a|length; 3) as $i |
            (($a[$i+1] | fromjson?) // {type:"object",properties:{}}) as $s |
            {name:$a[$i],
             description:($s.description // $a[$i]),
             inputSchema:($s | del(.description)),
             annotations:(if $a[$i+2] == "safe" then {readOnlyHint:true}
                          elif $a[$i+2] == "writes" then {destructiveHint:false}
                          else {destructiveHint:true} end)}]' \
            --args "${triples[@]}" 2>/dev/null) || tools='[]'
    fi
    _mcp_reply "$id_json" "$(jq -cn --argjson t "$tools" '{tools:$t}')"
}

# ── Consent (D5) ─────────────────────────────────────────────────────────────
# _mcp_confirm ACTION — 0 = the call is approved, 1 = denied.
# auto_confirm (config/flag) approves outright. A host that advertised
# elicitation gets asked and its answer decides — decline, cancel, garbage,
# timeout, and EOF all deny (fail-closed, exactly one ask, never a loop).
# A host without elicitation is denied here; the caller surfaces the same
# instructive message the NDJSON gate uses (consent parity).
_mcp_confirm() {
    local action="$1"
    [[ "$YCA_AUTO_CONFIRM" == "true" ]] && return 0
    [[ "${YCA_MCP_ELICITATION:-false}" == "true" ]] || return 1
    local req_id=$((++YCA_MCP_SRV_ID)) resp
    _mcp_send "$(jq -cn --argjson id "$req_id" --arg m "$action" \
        '{jsonrpc:"2.0",id:$id,method:"elicitation/create",params:{
            message:("Yantra needs consent: " + $m),
            requestedSchema:{type:"object",properties:{confirm:{type:"boolean",description:"true to allow this action"}},required:["confirm"]}}}')"
    resp=$(_mcp_await_response "$req_id") || return 1
    printf '%s' "$resp" | jq -e \
        '.result.action == "accept" and (.result.content.confirm != false)' >/dev/null 2>&1
}

# _mcp_await_response WANT_ID — read stdin until the response with id WANT_ID
# arrives; print it. Client requests that arrive meanwhile are queued (answered
# by id after this call — serial Bash must still answer everything it read);
# notifications are ignored. EOF or timeout → rc 1.
_mcp_await_response() {
    local want_id="$1" line id_json method rc
    local deadline=$(( SECONDS + ${YCA_MCP_ELICIT_TIMEOUT:-120} ))
    while (( SECONDS < deadline )); do
        IFS= read -r -t 5 line; rc=$?
        (( rc > 128 )) && continue      # poll timeout — keep waiting
        (( rc != 0 )) && return 1       # EOF: client is gone
        [[ -z "$line" ]] && continue
        printf '%s' "$line" | jq -e . >/dev/null 2>&1 || continue
        method=$(printf '%s' "$line" | jq -r '.method // empty')
        id_json=$(printf '%s' "$line" | jq -c '.id // null')
        if [[ -z "$method" ]]; then
            [[ "$id_json" == "$want_id" ]] && { printf '%s' "$line"; return 0; }
            continue                    # stray response to nothing we asked
        fi
        case "$method" in notifications/*) continue ;; esac
        YCA_MCP_PENDING+=("$line")
    done
    return 1
}

# ── Workflows as wf__<id> tools ──────────────────────────────────────────────
# MCP tool names cannot contain dots; the reverse map un-mangles. Built lazily,
# first-registered wins on a (theoretical) collision and the loser is logged.
_mcp_wf_resolve() {
    local mangled="$1" id
    if [[ ${#YCA_MCP_WFMAP[@]} -eq 0 ]]; then
        for id in "${!YCA_WF_REGISTRY[@]}"; do
            local m="wf__${id//./_}"
            if [[ -n "${YCA_MCP_WFMAP[$m]:-}" ]]; then
                log_warn "wf name collision: $m maps to ${YCA_MCP_WFMAP[$m]} and $id" 2>/dev/null || true
                continue
            fi
            YCA_MCP_WFMAP[$m]="$id"
        done
    fi
    printf '%s' "${YCA_MCP_WFMAP[$mangled]:-}"
}

# _mcp_run_workflow WF_ID ARGS_JSON — run through the REAL run_workflow (same
# consent gate, logging, and complexity routing) with its protocol frames
# captured; the last result frame becomes YCA_MCP_WF_OUT.
# Runs IN-PROCESS (result via global, never $()): a workflow that mutates
# session state — tools.enable flipping YCA_CAT_ENABLED — must keep its effect
# for the rest of the MCP session; a capture subshell would discard it.
YCA_MCP_WF_OUT=""
_mcp_run_workflow() {
    local wf_id="$1" args="$2" rc tmp fd
    YCA_MCP_WF_OUT='{"ok":false,"error":"workflow did not run"}'
    tmp=$(mktemp "${TMPDIR:-/tmp}/yca_mcp_wf.XXXXXX") || { YCA_MCP_WF_OUT='{"ok":false,"error":"mktemp failed"}'; return 1; }
    local saved_fd="$YCA_OUT_FD" saved_mode="$YCA_UI_MODE" saved_input="${YCA_INPUT_JSON:-}"
    exec {fd}>"$tmp"
    YCA_OUT_FD=$fd YCA_UI_MODE=json YCA_INPUT_JSON="$args"
    # stdin from /dev/null: run_workflow executes IN-PROCESS (to preserve state
    # mutations), so a workflow body running a stdin-reading command (kubectl
    # describe, git shortlog, etc.) would otherwise drain the loop's stdin —
    # the JSON-RPC frame stream — and silently kill the session. Redirecting the
    # function call sets fd 0 for its duration WITHOUT a subshell, so state still
    # persists. (Found by black-box sweep: k8s.describe ate the stream.)
    run_workflow "$wf_id" </dev/null; rc=$?
    YCA_OUT_FD="$saved_fd" YCA_UI_MODE="$saved_mode" YCA_INPUT_JSON="$saved_input"
    exec {fd}>&-
    # keep only the payload — the frame envelope (v/seq/ts/type) is transport
    # bookkeeping for the internal frame stream, noise to an MCP host.
    YCA_MCP_WF_OUT=$(jq -c 'select(.type=="result" or .type=="error") | del(.v,.seq,.ts,.type)' "$tmp" 2>/dev/null | tail -1)
    rm -f "$tmp"
    [[ -n "$YCA_MCP_WF_OUT" ]] || YCA_MCP_WF_OUT=$(jq -cn --argjson ok "$([[ $rc -eq 0 ]] && echo true || echo false)" '{ok:$ok}')
    # a category-mutating workflow invalidates the wire list like enable_category
    tools_invalidate_cache 2>/dev/null || true
    return $rc
}

# ── tools/call ───────────────────────────────────────────────────────────────
mcp_tools_call() {
    local id_json="$1" tool_name="$2" arguments="$3"
    local errtmp; errtmp=$(mktemp "${TMPDIR:-/tmp}/yca_mcp_err.XXXXXX") || errtmp=/dev/null

    # T11: enable_category mutates session state (YCA_CAT_ENABLED). A dispatched
    # tool fn runs in a subshell, so the change would be lost — handle it here
    # in the MCP process, then emit tools/list_changed so the host refetches.
    if [[ "$tool_name" == "enable_category" ]]; then
        rm -f "$errtmp"
        mcp_enable_category "$id_json" "$arguments"
        return 0
    fi

    local out rc is_error=false wf_id danger info
    if [[ "$tool_name" == wf__* ]]; then
        wf_id=$(_mcp_wf_resolve "$tool_name")
        if [[ -z "$wf_id" ]]; then
            rm -f "$errtmp"
            _mcp_text_result "$id_json" "unknown tool: $tool_name" true
            return 0
        fi
        IFS='|' read -r _ _ danger _ <<< "${YCA_WF_REGISTRY[$wf_id]}"
        if danger_needs_confirm "$danger" && _mcp_confirm "workflow '$wf_id' ($danger)"; then
            local _saved_auto="$YCA_AUTO_CONFIRM"; YCA_AUTO_CONFIRM=true
            _mcp_run_workflow "$wf_id" "$arguments" 2>"$errtmp"; rc=$?
            YCA_AUTO_CONFIRM="$_saved_auto"
        else
            # not approved (or safe → no consent needed): run_workflow's own
            # gate decides, producing the canonical instructive deny on deny.
            _mcp_run_workflow "$wf_id" "$arguments" 2>"$errtmp"; rc=$?
        fi
        out="$YCA_MCP_WF_OUT"
    else
        info="${YCA_TOOL_REGISTRY[$tool_name]:-}"
        danger=""; [[ -n "$info" ]] && IFS='|' read -r _ danger _ _ _ <<< "$info"
        if [[ -n "$danger" ]] && danger_needs_confirm "$danger" && _mcp_confirm "tool '$tool_name' ($danger)"; then
            out=$(YCA_AUTO_CONFIRM=true tool_dispatch "$tool_name" "$arguments" 2>"$errtmp"); rc=$?
        else
            # safe tool, unknown tool, or consent denied: tool_dispatch handles
            # each (unknown-tool message, or the canonical deny message).
            out=$(tool_dispatch "$tool_name" "$arguments" 2>"$errtmp"); rc=$?
        fi
    fi
    [[ $rc -eq 0 ]] || is_error=true

    _mcp_emit_stderr "$errtmp"
    rm -f "$errtmp"
    _mcp_text_result "$id_json" "$out" "$is_error"
}

# enable_category over MCP: consent via elicitation when the host supports it
# (D5), else deny-with-explanation. The enable is applied in-process, then
# tools/list_changed tells the host to refetch. A denied call enables nothing
# and emits NO notification.
mcp_enable_category() {
    local id_json="$1" arguments="$2"
    local cat; cat=$(printf '%s' "$arguments" | jq -r '.category // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    if ! _mcp_confirm "enable tool category '$cat' (exposes its tools for this session)"; then
        _mcp_text_result "$id_json" "denied: enabling a tool category needs confirmation (approve the elicitation, or run with consent)" true
        return 0
    fi
    if [[ -z "$cat" || -z "${YCA_CAT_DEFAULT[$cat]:-}" ]]; then
        _mcp_text_result "$id_json" "unknown category: $cat" true
        return 0
    fi
    YCA_CAT_ENABLED[$cat]=1
    tools_invalidate_cache 2>/dev/null || true
    _mcp_text_result "$id_json" "$cat enabled" false
    _mcp_send '{"jsonrpc":"2.0","method":"notifications/tools/list_changed"}'
}

# ── Resources ────────────────────────────────────────────────────────────────
# plan://current (T12), spill://<id> (T10), doc://cli/<page> (the CLI reference).
mcp_resources_list() {
    local id_json="$1" page
    local docs='[]'
    if [[ -d "$YCA_DIR/docs/cli" ]]; then
        docs=$(for page in "$YCA_DIR/docs/cli"/*.md; do
            [[ -f "$page" ]] || continue
            printf '%s\n' "$(basename "$page" .md)"
        done | jq -Rnc '[inputs | select(length > 0)
            | {uri:("doc://cli/"+.), name:("CLI reference: "+.), mimeType:"text/markdown"}]' 2>/dev/null) || docs='[]'
        [[ -n "$docs" ]] || docs='[]'
    fi
    _mcp_reply "$id_json" "$(jq -cn --argjson d "$docs" \
        '{resources:([{uri:"plan://current",name:"active plan",mimeType:"application/json"}] + $d)}')"
}

mcp_resources_read() {
    local id_json="$1" uri="$2" body
    if [[ "$uri" == "plan://current" ]]; then
        body=$(tool_invoke plan_status '{}' 2>/dev/null)
        _mcp_reply "$id_json" "$(jq -cn --arg t "$body" \
            '{contents:[{uri:"plan://current",mimeType:"application/json",text:$t}]}')"
    elif [[ "$uri" == spill://* ]]; then
        # T10: a GC'd/deleted spill returns a clean not-found, never a crash.
        if body=$(spill_read "${uri#spill://}"); then
            _mcp_reply "$id_json" "$(jq -cn --arg u "$uri" --arg t "$body" \
                '{contents:[{uri:$u,mimeType:"text/plain",text:$t}]}')"
        else
            _mcp_error "$id_json" -32002 "Resource not found (expired or deleted): $uri"
        fi
    elif [[ "$uri" == doc://cli/* ]]; then
        local page="${uri#doc://cli/}"
        # basename() the request: a crafted "page" must not traverse the tree.
        page=$(basename "$page" .md)
        local path="$YCA_DIR/docs/cli/$page.md"
        if [[ -f "$path" ]]; then
            body=$(<"$path") 2>/dev/null || body=""
            _mcp_reply "$id_json" "$(jq -cn --arg u "$uri" --arg t "$body" \
                '{contents:[{uri:$u,mimeType:"text/markdown",text:$t}]}')"
        else
            _mcp_error "$id_json" -32002 "Resource not found: $uri"
        fi
    else
        _mcp_error "$id_json" -32002 "Resource not found: $uri"
    fi
}

# ── Request router + main loop ───────────────────────────────────────────────
mcp_handle_line() {
    local line="$1"
    [[ -z "$line" ]] && return 0
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        _mcp_send '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}'
        return 0
    fi
    local id_json method
    id_json=$(printf '%s' "$line" | jq -c '.id // null')
    method=$(printf '%s' "$line" | jq -r '.method // empty')

    if [[ -z "$method" ]]; then
        # A bare response (no method): nothing we asked for — drop it. A bare
        # object with an id but no method is not a valid request.
        [[ "$id_json" != "null" ]] && _mcp_error "$id_json" -32600 "Invalid request: missing method"
        return 0
    fi

    case "$method" in
        initialize)
            mcp_initialize "$line" "$id_json" ;;
        ping)
            _mcp_reply "$id_json" '{}' ;;
        tools/list)
            mcp_tools_list "$id_json" ;;
        tools/call)
            local tool_name arguments
            tool_name=$(printf '%s' "$line" | jq -r '.params.name // empty')
            arguments=$(printf '%s' "$line" | jq -c '.params.arguments // {}')
            mcp_tools_call "$id_json" "$tool_name" "$arguments" ;;
        prompts/list)
            mcp_prompts_list "$id_json" ;;
        prompts/get)
            mcp_prompts_get "$id_json" "$line" ;;
        resources/list)
            mcp_resources_list "$id_json" ;;
        resources/read)
            local uri; uri=$(printf '%s' "$line" | jq -r '.params.uri // empty')
            mcp_resources_read "$id_json" "$uri" ;;
        notifications/exit)
            exit 0 ;;
        notifications/*)
            # Notifications never get a response. notifications/cancelled is
            # acknowledged best-effort only (calls are serial; by the time we
            # read the cancel, the call has finished) — documented until B13.
            return 0 ;;
        *)
            if [[ "$id_json" == "null" ]]; then
                return 0   # unknown notification-shaped frame: stay silent
            fi
            _mcp_error "$id_json" -32601 "Method not found: $method" ;;
    esac
}

mcp_loop() {
    local line
    while :; do
        # Requests buffered while an elicitation was in flight are answered
        # first, in arrival order, before new stdin is read.
        if [[ ${#YCA_MCP_PENDING[@]} -gt 0 ]]; then
            line="${YCA_MCP_PENDING[0]}"
            YCA_MCP_PENDING=("${YCA_MCP_PENDING[@]:1}")
        else
            IFS= read -r line || { [[ -n "$line" ]] || break; }
        fi
        mcp_handle_line "$line"
    done
}

# NOTE: mcp_loop is invoked by main.sh only when `--ui mcp` is selected. It must
# NOT be called at source time — main.sh sources every commands/*.sh at startup,
# so a file-scope call here would steal stdin from the NDJSON/CLI surfaces.
