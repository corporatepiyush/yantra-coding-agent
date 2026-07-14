# workflows/harness.sh — Harness self-management workflows

wf_harness_cost() {
    # REAL token accounting from captured .usage (the old version counted
    # tool.call/workflow.start ROWS and mislabeled them as tokens — it could not
    # prove the product's central token-savings claim).
    local pt ct calls per_tier
    pt=$(db_exec "SELECT COALESCE(SUM(json_extract(data_json,'\$.prompt_tokens')),0) FROM events WHERE kind='llm.usage';" 2>/dev/null); [[ "$pt" =~ ^[0-9]+$ ]] || pt=0
    ct=$(db_exec "SELECT COALESCE(SUM(json_extract(data_json,'\$.completion_tokens')),0) FROM events WHERE kind='llm.usage';" 2>/dev/null); [[ "$ct" =~ ^[0-9]+$ ]] || ct=0
    calls=$(db_count "events" "kind='llm.usage'" 2>/dev/null); [[ "$calls" =~ ^[0-9]+$ ]] || calls=0
    per_tier=$(db_query_json "SELECT json_extract(data_json,'\$.tier') AS tier, COUNT(*) AS calls, COALESCE(SUM(json_extract(data_json,'\$.prompt_tokens')),0) AS prompt_tokens, COALESCE(SUM(json_extract(data_json,'\$.completion_tokens')),0) AS completion_tokens FROM events WHERE kind='llm.usage' GROUP BY tier;" 2>/dev/null)
    [[ -z "$per_tier" ]] && per_tier='[]'
    emit result "$(jq -n --argjson pt "$pt" --argjson ct "$ct" --argjson calls "$calls" --argjson tiers "$per_tier" \
        '{ok:true,summary:("LLM usage — \($calls) call(s), \($pt) prompt + \($ct) completion tokens"),data:{llm_calls:$calls,prompt_tokens:$pt,completion_tokens:$ct,per_tier:$tiers}}' 2>/dev/null \
        || jq -n '{ok:true,summary:"no LLM usage recorded yet",data:{llm_calls:0,prompt_tokens:0,completion_tokens:0}}')"
}

wf_harness_history() {
    db_exec "SELECT id, harness_version, commit_sha, applied_ts FROM versions ORDER BY id DESC LIMIT 20;" 2>/dev/null | \
        awk -F'|' '{printf "%-4s %-15s %-40s %s\n", $1, $2, $3, $4}' >&2
    emit_ok "history shown on stderr"
}

wf_harness_config() {
    local key="${INPUT_key:-}"
    if [[ -n "$key" ]]; then
        # Session-only override — yantra.config.json stays the source of truth and
        # is never written by the harness. Edit the file to make a change permanent.
        config_set "$key" "${INPUT_value:-}"
        emit_ok "set $key for this session (not saved; edit $YCA_CONFIG_PROJECT_PATH to persist)"
    else
        local provider_counts
        provider_counts=$(printf '%s' "$YCA_PROVIDERS_JSON" | jq -c '{think:(.think|length),build:(.build|length),tool:(.tool|length)}' 2>/dev/null || printf '{}')
        emit result "$(jq -n \
            --argjson cfg "$YCA_CONFIG_JSON" \
            --arg gp "$YCA_CONFIG_GLOBAL_PATH" --arg pp "$YCA_CONFIG_PROJECT_PATH" \
            --argjson have "$([[ "$YCA_HAVE_LLM" == 1 ]] && printf true || printf false)" \
            --argjson prov "$provider_counts" \
            '{ok:true,summary:"effective config",data:{effective:$cfg,global_file:$gp,project_file:$pp,llm_available:$have,provider_counts:$prov}}')"
    fi
}

wf_harness_update() {
    update_check
    emit_ok "update check done"
}

wf_harness_backup() {
    local bkdir="$YCA_PROJECT_DIR/.harness/backups"
    local bk="$bkdir/$(now_stamp).tar.gz"
    path_ensure_dir "$bkdir"
    # Snapshot via VACUUM INTO, never tar of the live file: the DB runs in WAL
    # mode, so committed-but-uncheckpointed transactions live in .harness.db-wal
    # — archiving the main file alone silently drops the newest writes. VACUUM
    # INTO produces a consistent, compacted snapshot without blocking writers.
    # The snapshot keeps the name .harness.db inside the archive, so restoring
    # (untar into the project root) is unchanged.
    local tmpd
    tmpd=$(path_temp_dir yca-backup) || { emit_fail "backup: cannot create temp dir"; return 1; }
    if ! db_exec "VACUUM INTO $(sql_quote "$tmpd/.harness.db");" >/dev/null 2>&1; then
        rm -rf "$tmpd"
        emit_fail "backup: consistent snapshot failed (VACUUM INTO) — no archive written"
        return 1
    fi
    if ! tar -czf "$bk" -C "$tmpd" .harness.db 2>/dev/null; then
        rm -rf "$tmpd"; rm -f "$bk"
        emit_fail "backup: archive failed — no archive written"
        return 1
    fi
    rm -rf "$tmpd"
    # Rotate: keep the newest 10 — timestamped names sort lexically, so
    # without this the backup dir grows one archive per invocation forever.
    local old
    while IFS= read -r old; do
        [[ -f "$old" ]] && rm -f "$old"
    done < <(printf '%s\n' "$bkdir"/*.tar.gz 2>/dev/null | sort -r | tail -n +11)
    emit_ok "backup: $bk (consistent snapshot; older backups rotated, keeping 10)"
}

wf_harness_doctor() {
    doctor_report
}

wf_register "harness.cost"    wf_harness_cost    1 safe "" "Token/cost accounting"
wf_register "harness.history" wf_harness_history 1 safe "" "Version history"
wf_register "harness.config"  wf_harness_config  1 safe "" "Show/edit config"
wf_register "harness.update"  wf_harness_update  1 writes "curl" "Check for updates"
wf_register "harness.backup"  wf_harness_backup  1 safe "" "Backup the DB"
wf_register "harness.doctor"  wf_harness_doctor  1 safe "" "Check dependencies"
