# core/workflows.sh — Workflow registry, input hydration, dispatcher

declare -A YCA_WF_REGISTRY

wf_register() {
    # $1=id $2=fn $3=tier $4=danger $5=needs $6=desc $7=complexity(high|mid|low)
    # complexity defaults to low (static workflow, no LLM). LLM-backed pass mid/high.
    # Canonical values skip the $(complexity_normalize) subshell — registration
    # runs ~100× at every boot, so the fork-free path keeps startup fast.
    local _cx="${7:-low}"
    case "$_cx" in
        high|mid|low) ;;
        *) _cx=$(complexity_normalize "$_cx") ;;
    esac
    YCA_WF_REGISTRY[$1]="$2|$3|$4|${5:-}|${6:-}|$_cx"
}

# wf_complexity ID -> effective complexity (config override wins over registered).
wf_complexity() {
    local id="$1"
    if [[ -n "${YCA_COMPLEXITY_OVERRIDE[$id]:-}" ]]; then
        complexity_normalize "${YCA_COMPLEXITY_OVERRIDE[$id]}"; return 0
    fi
    local info="${YCA_WF_REGISTRY[$id]:-}"
    [[ -z "$info" ]] && { printf 'low'; return 0; }
    printf '%s' "${info##*|}"
}

# Hydrate INPUT_* env vars from YCA_INPUT_JSON.
# Keys must be valid identifiers ([A-Za-z_][A-Za-z0-9_]*): anything else is
# skipped, so a hostile key can never turn `export` into an error or smuggle an
# unexpected variable name. Key/value pairs are separated by the \u001f unit
# separator (not '='/newline), so a value containing '=' or newlines survives
# intact instead of corrupting the following pairs.
hydrate_inputs() {
    [[ -z "$YCA_INPUT_JSON" ]] && return 0
    local -a kv=()
    mapfile -d $'\x1f' -t kv < <(printf '%s' "$YCA_INPUT_JSON" \
        | jq -j 'to_entries[] | "\(.key)\u001f\(.value|tostring)\u001f"' 2>/dev/null)
    local i k
    for ((i=0; i+1<${#kv[@]}; i+=2)); do
        k="${kv[i]}"
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        export "INPUT_${k}=${kv[i+1]}"
    done
}

# wf_suggest QUERY -> up to 6 workflow ids related to QUERY, space-separated.
# Matches on a shared prefix (before the dot) first, then any substring, so a
# fat-fingered "gti quicksave" or a bare "secret" still points somewhere useful.
wf_suggest() {
    local q="$1" head="${1%% *}"
    head="${head%%.*}"
    # Closest first: ids CONTAINING what they typed (so a typo'd "git.quicksav"
    # surfaces "git.quicksave"), then everything sharing the same prefix.
    { printf '%s\n' "${!YCA_WF_REGISTRY[@]}" | grep -iF "$q" 2>/dev/null
      printf '%s\n' "${!YCA_WF_REGISTRY[@]}" | grep -iE "^${head}\." 2>/dev/null | sort
    } | awk 'NF && !seen[$0]++' | head -6 | tr '\n' ' '
}

# wf_call ID [INPUT_JSON] — run another workflow as a STEP of the current one.
# The child's protocol frames (progress/result) are suppressed so the parent owns
# the final result; the child's exit code is returned. This is the composition
# seam for building composite workflows (pipelines) out of single-purpose ones.
wf_call() {
    local id="$1" inputs="${2:-}"
    local info="${YCA_WF_REGISTRY[$id]:-}"
    [[ -z "$info" ]] && { log_warn "wf_call: unknown workflow $id"; return 1; }
    local fn="${info%%|*}"
    declare -F "$fn" &>/dev/null || { log_warn "wf_call: not implemented $fn"; return 1; }
    local saved_input="$YCA_INPUT_JSON" saved_complexity="$YCA_CALL_COMPLEXITY" saved_fd="$YCA_OUT_FD"
    [[ -n "$inputs" ]] && YCA_INPUT_JSON="$inputs"
    hydrate_inputs
    YCA_CALL_COMPLEXITY=$(wf_complexity "$id")
    # Swallow the child's emit frames by pointing the protocol fd at /dev/null.
    local sink; exec {sink}>/dev/null; YCA_OUT_FD=$sink
    "$fn" >&2
    local rc=$?
    YCA_OUT_FD="$saved_fd"; exec {sink}>&-
    YCA_CALL_COMPLEXITY="$saved_complexity"; YCA_INPUT_JSON="$saved_input"
    return $rc
}

# Run a workflow by ID
run_workflow() {
    local wf_id="$1"
    [[ -z "$wf_id" ]] && { emit_error "422" "workflow id required (type 'cmd:list' to see them)"; return 1; }
    local info="${YCA_WF_REGISTRY[$wf_id]:-}"
    if [[ -z "$info" ]]; then
        # Friendly, actionable 404: tell them it's unknown AND what's close.
        local sugg; sugg=$(wf_suggest "$wf_id")
        local hint="unknown action: '$wf_id'. Type 'cmd:list' to see all actions."
        [[ -n "$sugg" ]] && hint="unknown action: '$wf_id'. Did you mean: ${sugg%% }? (prefix with wf:, or 'cmd:list' for all)"
        emit_error "404" "$hint"
        return 1
    fi
    local fn="${info%%|*}"
    if ! declare -F "$fn" &>/dev/null; then
        emit_error "501" "workflow not implemented: $fn"
        return 1
    fi
    # Machine-mode consent gate for destructive workflows. run_workflow had NO
    # danger gate (unlike tool_dispatch), so a `writes` workflow — git.quicksave
    # (add -A + commit + push), git.release (tag + push), deps.install (eval an
    # installer), disk.clean — ran in machine mode with no auto-deny and no
    # preview. Mirror the tool gate: deny a consequential workflow unless the
    # caller opted in via auto_confirm. Worst case prevented: an unattended agent
    # publishing code or deleting files from a single un-consented `run` frame.
    local wf_danger; IFS='|' read -r _ _ wf_danger _ <<< "$info"
    if danger_needs_confirm "$wf_danger" && [[ "$YCA_UI_MODE" == "json" && "$YCA_AUTO_CONFIRM" != "true" ]]; then
        # Deny as a result:ok:false — the SAME frame the workflow's own
        # confirm_action would have emitted — so this is uniform, earlier
        # enforcement, not a protocol change. A machine caller gets one clean,
        # actionable result instead of silently-executed writes.
        emit_fail "workflow '$wf_id' performs writes and needs consent; machine mode auto-denies it. Re-send with auto_confirm:true (a run/dispatch frame) to authorize, or run a read-only workflow."
        return 1
    fi
    hydrate_inputs
    emit_progress "workflow" "running $wf_id" 0
    log_workflow_start "$wf_id"
    # Set the routing complexity for any LLM the workflow calls.
    local _saved_complexity="$YCA_CALL_COMPLEXITY"
    YCA_CALL_COMPLEXITY=$(wf_complexity "$wf_id")
    # Quarantine the workflow's own stdout to stderr: workflows must communicate
    # results via emit() (which targets the preserved protocol fd), so any bare
    # command/tool output here is human-facing and must not pollute the stream.
    "$fn" >&2
    local rc=$?
    YCA_CALL_COMPLEXITY="$_saved_complexity"
    log_workflow_end "$wf_id" "$rc"
    return $rc
}
