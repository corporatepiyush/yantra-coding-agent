# workflows/fmt.sh — Format workflows

wf_fmt_all() {
    local cmd
    cmd=$(toolchain_profile_json | jq -r '.format // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no formatter detected"; return 1; }
    emit_progress "format" ""
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit_ok "formatted"
}

wf_fmt_changed() {
    doctor_check_needs "git" || return 1
    local cmd
    cmd=$(toolchain_profile_json | jq -r '.format // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no formatter detected"; return 1; }
    local files
    files=$(cd "$YCA_PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null)
    [[ -z "$files" ]] && { emit_ok "no changed files"; return 0; }
    emit_progress "format" ""
    printf '%s\n' "$files" | ( cd "$YCA_PROJECT_DIR" && xargs -P "$(math_core_count)" sh -c "$cmd \"\$@\"" _ ) 2>&1 | head -20 >&2 || true
    emit_ok "formatted changed files"
}

wf_register "fmt.all"      wf_fmt_all      1 writes "" "Format all files"
wf_register "fmt.changed"  wf_fmt_changed  1 writes "git" "Format only changed files"
