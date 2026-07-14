# workflows/tools.sh — Tool toggle workflows (enable/disable/status)

wf_tools_enable() {
    local category="${1:-${INPUT_category:-}}"
    val_required "$category" "category" || return 1
    local cat_lower
    cat_lower=$(str_lower "$category")
    if [[ -z "${YCA_CAT_DEFAULT[$cat_lower]:-}" ]]; then
        emit_fail "unknown category: $cat_lower (see 'cmd:tools status' for available categories)"
        return 1
    fi
    if [[ "${YCA_CAT_ENABLED[$cat_lower]:-0}" == "1" ]]; then
        emit_ok "$cat_lower already enabled"
        return 0
    fi
    if ! confirm_action "Enable tool category: $cat_lower" "This exposes $cat_lower tools to the LLM"; then
        # In machine mode the refusal is automatic (no auto_confirm), so tell the
        # client how to consent — a bare "denied" gives it nothing to act on.
        if [[ "$YCA_UI_MODE" == "json" && "$YCA_AUTO_CONFIRM" != "true" ]]; then
            emit_fail "denied: enabling a tool category needs confirmation. Resend as {\"type\":\"run\",\"workflow\":\"tools.enable\",\"inputs\":{\"category\":\"$cat_lower\"},\"auto_confirm\":true}"
        else
            emit_fail "denied"
        fi
        return 1
    fi
    YCA_CAT_ENABLED[$cat_lower]=1
    tools_invalidate_cache  # invalidate per-agent cache
    emit_ok "$cat_lower enabled (this session; edit yantra.config.json tools.enabled to persist)"
}

wf_tools_disable() {
    local category="${1:-${INPUT_category:-}}"
    val_required "$category" "category" || return 1
    local cat_lower
    cat_lower=$(str_lower "$category")
    [[ "$cat_lower" == "core" ]] && { emit_fail "cannot disable core tools"; return 1; }
    YCA_CAT_ENABLED[$cat_lower]=0
    tools_invalidate_cache
    emit_ok "$cat_lower disabled (this session)"
}

wf_tools_status() {
    local items="["
    local first=1 c
    for c in "${!YCA_CAT_DEFAULT[@]}"; do
        local val="${YCA_CAT_ENABLED[$c]:-0}"
        local label="${YCA_CAT_LABEL[$c]:-$c}"
        (( first )) || items+=","
        first=0
        items+=$(jq -n --arg c "$c" --arg l "$label" --argjson e "$val" '{category:$c,label:$l,enabled:$e}')
    done
    items+="]"
    emit result "$(jq -n --argjson i "$items" '{ok:true,summary:"tool categories",data:{categories:$i}}')"
}

wf_tools_list() {
    # List all tools (optionally filtered by category)
    local filter="${INPUT_category:-}"
    local items="["
    local first=1 name info fn danger agents category complexity
    for name in "${!YCA_TOOL_REGISTRY[@]}"; do
        info="${YCA_TOOL_REGISTRY[$name]}"
        IFS='|' read -r fn danger agents category complexity <<< "$info"
        [[ -n "$filter" && "$category" != "$filter" ]] && continue
        (( first )) || items+=","
        first=0
        items+=$(jq -n --arg n "tl:$name" --arg c "$category" --arg d "$danger" --arg cx "${complexity:-low}" \
            '{name:$n,category:$c,danger:$d,complexity:$cx}')
    done
    items+="]"
    emit result "$(jq -n --argjson i "$items" '{ok:true,summary:"tools",data:{tools:$i}}')"
}

wf_register "tools.enable"  wf_tools_enable  1 safe "" "Enable a tool category"
wf_register "tools.disable" wf_tools_disable 1 safe "" "Disable a tool category"
wf_register "tools.status"  wf_tools_status  1 safe "" "Show tool category status"
wf_register "tools.list"    wf_tools_list    1 safe "" "List all tools"
