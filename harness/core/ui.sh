# core/ui.sh — UI renderers (human, plain, json) and input helpers

render_human() {
    local frame="$1" etype
    etype=$(printf '%s' "$frame" | jq -r '.type')
    case "$etype" in
        ready)
            banner "Coding Agent  v$YCA_VERSION" ;;
        catalog)
            local what
            what=$(printf '%s' "$frame" | jq -r '.what')
            logmsg "$(c_dim "┌── $what ──")"
            printf '%s\n' "$frame" | jq -r '.items[]? | "│ \(.id) — \(.title)"'
            logmsg "$(c_dim "└──")" ;;
        progress)
            local stage message pct
            stage=$(printf '%s' "$frame" | jq -r '.stage')
            message=$(printf '%s' "$frame" | jq -r '.message // ""')
            pct=$(printf '%s' "$frame" | jq -r '.pct // empty')
            [[ -n "$pct" ]] && logmsg "  [${pct}%] $(color_symbol progress) ${stage}: ${message}" \
                           || logmsg "  $(color_symbol progress) ${stage}: ${message}" ;;
        prompt)
            local label field
            label=$(printf '%s' "$frame" | jq -r '.label')
            field=$(printf '%s' "$frame" | jq -r '.field')
            logmsg "── $label ($field) ──" ;;
        confirm_request)
            local action
            action=$(printf '%s' "$frame" | jq -r '.action')
            logmsg "$(c_warn "$SYM_WARN CONFIRM: $action")"
            printf '%s\n' "$frame" | jq -r '.commands[]?' ;;
        result)
            local ok summary
            ok=$(printf '%s' "$frame" | jq -r '.ok')
            summary=$(printf '%s' "$frame" | jq -r '.summary')
            [[ "$ok" == "true" ]] && logmsg "$(c_ok "$SYM_OK") $summary" || logmsg "$(c_fail "$SYM_FAIL") $summary" ;;
        error)
            local code message
            code=$(printf '%s' "$frame" | jq -r '.code // "?"')
            message=$(printf '%s' "$frame" | jq -r '.message // ""')
            logmsg "$(c_fail "$SYM_FAIL [$code] $message")" ;;
        *) logmsg "$frame" ;;
    esac
}

render_plain() {
    local frame="$1" etype
    etype=$(printf '%s' "$frame" | jq -r '.type')
    case "$etype" in
        ready) ;;
        progress) logmsg "[$(printf '%s' "$frame" | jq -r '.stage')] $(printf '%s' "$frame" | jq -r '.message // ""')" ;;
        result) logmsg "[$(printf '%s' "$frame" | jq -r '.ok')] $(printf '%s' "$frame" | jq -r '.summary')" ;;
        error) logmsg "[ERROR $(printf '%s' "$frame" | jq -r '.code // "?"')] $(printf '%s' "$frame" | jq -r '.message // ""')" ;;
        *) logmsg "$frame" ;;
    esac
}

# Prompt user (human mode). Returns answer on stdout.
prompt_user() {
    local field="$1" default="$2" label="$3"
    printf '  %s' "$label" >&2
    [[ -n "$default" ]] && printf ' [%s]' "$default" >&2
    printf ': ' >&2
    local answer
    IFS= read -r answer || { printf '\n' >&2; return 130; }
    [[ -z "$answer" ]] && answer="$default"
    # Strip control/ANSI bytes so a pasted escape sequence can't spoof output or
    # smuggle bytes into whatever consumes this input.
    sanitize_line "$answer"
}

# confirm_denied_msg — what a tool returns when confirm_action refused. In
# machine mode the refusal is automatic, and this text is usually fed back to
# the LLM as tool output — a bare "cancelled" gives the model nothing to adapt
# to, so it blindly retries the same call until max iterations.
confirm_denied_msg() {
    if [[ ( "$YCA_UI_MODE" == "json" || "$YCA_UI_MODE" == "mcp" ) && "$YCA_AUTO_CONFIRM" != "true" ]]; then
        printf 'cancelled: this action needs confirmation, which machine mode auto-denies unless the request carries auto_confirm:true. Do NOT retry the same call — continue with read-only tools, or report that confirmation is required.'
    else
        printf 'cancelled by user'
    fi
}

# Confirm action. On the machine surfaces (NDJSON and MCP) never prompt on
# stdin — that would corrupt the protocol stream. Consent there is auto_confirm
# (NDJSON) or an elicitation resolved BEFORE dispatch (MCP, _mcp_confirm); by
# this point the answer is already in YCA_AUTO_CONFIRM.
confirm_action() {
    local action="$1"; shift
    if [[ "$YCA_UI_MODE" == "json" || "$YCA_UI_MODE" == "mcp" ]]; then
        [[ "$YCA_AUTO_CONFIRM" == "true" ]] && return 0
        return 1
    fi
    [[ "$YCA_SAFETY_CONFIRM" != "true" ]] && return 0
    logmsg ""
    logmsg "$(c_warn "$SYM_WARN CONFIRM: $action")"
    local cmd
    for cmd in "$@"; do logmsg "  $cmd"; done
    local answer
    answer=$(prompt_user "confirm" "y" "Proceed? [Y/n]") || return 1
    [[ "${answer,,}" =~ ^(y|yes)$ ]]
}
