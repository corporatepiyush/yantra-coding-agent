# core/emit.sh — Event emission (single point for all output)
# stdout is protocol-only in json mode; all human text goes to stderr.

emit() {
    # $1=event type, $2=payload JSON (optional)
    local type="$1" payload="${2:-$YCA_EMPTY_JSON}"
    local frame
    frame=$(printf '%s' "$payload" | jq -cn --arg t "$type" --argjson seq "$((++YCA_SEQ))" \
        '{v:1,seq:$seq,ts:(now*1000|floor),type:$t} + input' 2>/dev/null) || {
        log_error "emit failed: invalid payload"
        return 1
    }
    # Write to the preserved protocol fd (fd 9 once main() runs; fd 1 otherwise),
    # so a workflow body's stray stdout — redirected to stderr in run_workflow —
    # can never interleave with or corrupt the protocol stream.
    { case "$YCA_UI_MODE" in
        json) printf '%s\n' "$frame" ;;
        plain) render_plain "$frame" ;;
        *) render_human "$frame" ;;
    esac; } >&"$YCA_OUT_FD"
}

emit_ok()   { emit result "$(jq -n --arg s "$1" '{ok:true,summary:$s}')"; }
emit_fail() { emit result "$(jq -n --arg s "$1" '{ok:false,summary:$s}')"; }

emit_progress() {
    local stage="$1" message="$2" pct="${3:-}"
    if [[ -n "$pct" ]]; then
        emit progress "$(jq -n --arg s "$stage" --arg m "$message" --argjson p "$pct" '{stage:$s,message:$m,pct:$p}')"
    else
        emit progress "$(jq -n --arg s "$stage" --arg m "$message" '{stage:$s,message:$m}')"
    fi
}

emit_error() {
    local code="$1" message="$2"
    emit error "$(jq -n --arg c "$code" --arg m "$message" '{code:$c,message:$m}')"
}
