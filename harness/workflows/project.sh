# workflows/project.sh — Project management workflows

wf_project_overview() {
    local kind
    kind=$(toolchain_detect)
    logmsg "Project: $YCA_PROJECT_DIR"
    logmsg "Toolchain: $kind"
    if command -v tokei &>/dev/null; then tokei "$YCA_PROJECT_DIR" 2>/dev/null | head -20
    elif command -v scc &>/dev/null; then scc "$YCA_PROJECT_DIR" 2>/dev/null | head -20
    else
        local fcount
        fcount=$(files_count "$YCA_PROJECT_DIR")
        logmsg "Files: $fcount"
    fi
    emit result "$(jq -n --arg k "$kind" '{ok:true,summary:"overview",data:{toolchain:$k}}')"
}

wf_project_changelog() {
    local changelog="$YCA_PROJECT_DIR/CHANGELOG.md" tmpfile
    tmpfile=$(path_temp_file yca-cl)
    {
        printf '# CHANGELOG\n\n## %s\n\n' "$(now_stamp '%Y-%m-%d %H:%M')"
        db_exec "SELECT '- ' || summary || ' (' || file_path || ')' FROM changes ORDER BY ts DESC LIMIT 20;" 2>/dev/null
        printf '\n'
        [[ -f "$changelog" ]] && cat "$changelog"
    } > "$tmpfile"
    confirm_action "Update CHANGELOG.md" "write to $changelog" || { rm -f "$tmpfile"; return 0; }
    cp "$tmpfile" "$changelog"
    rm -f "$tmpfile"
    emit_ok "changelog updated"
}

wf_project_init() {
    local kind="${INPUT_kind:-bash}" name="${INPUT_name:-$(basename "$YCA_PROJECT_DIR")}"
    case "$kind" in
        git)
            ( cd "$YCA_PROJECT_DIR" && git init )
            printf '# %s\n\nCreated by Yantra Coding Agent.\n' "$name" > "$YCA_PROJECT_DIR/README.md"
            ;;
        *)
            emit_fail "use scaffold.new for project scaffolding"
            return 1
            ;;
    esac
    emit_ok "project initialized"
}

# project.onboard — the "I just inherited this repo, what do I do?" command.
# One shot: what is it, what's healthy, what to enable, what to run next.
wf_project_onboard() {
    local kind detected
    kind=$(toolchain_detect)
    detected="${kind:-none detected}"
    logmsg "$(c_info '═══ Project onboarding ═══')"
    logmsg "Project:   $YCA_PROJECT_DIR"
    logmsg "Toolchain: $detected"
    logmsg ""

    # 1. Structure / size
    logmsg "$(c_info '1) Structure')"
    if command -v tokei &>/dev/null; then tokei "$YCA_PROJECT_DIR" 2>/dev/null | tail -15 >&2
    elif command -v scc &>/dev/null; then scc "$YCA_PROJECT_DIR" 2>/dev/null | tail -15 >&2
    else logmsg "  Files: $(files_count "$YCA_PROJECT_DIR" 2>/dev/null || printf '?')"; fi

    # 2. Toolchain profile (build/test/lint/format commands)
    logmsg ""
    logmsg "$(c_info '2) How to build/test/lint (detected)')"
    toolchain_profile_json | jq -r 'to_entries[] | select(.value!=null and .value!="") | "  \(.key): \(.value)"' 2>/dev/null >&2 || true

    # 3. TODO/FIXME roadmap
    logmsg ""
    logmsg "$(c_info '3) Inherited roadmap (TODO/FIXME markers)')"
    if command -v rg &>/dev/null; then
        rg -c --no-messages 'TODO|FIXME|HACK|XXX' "$YCA_PROJECT_DIR" 2>/dev/null | wc -l | tr -d ' ' | xargs -I{} logmsg "  {} files contain TODO/FIXME markers (list them: cmd:tools enable fs, then tl:fs todos)"
    else
        logmsg "  (install ripgrep, then: cmd:tools enable fs; tl:fs todos)"
    fi

    # 4. Recommended tool categories (scanner)
    logmsg ""
    logmsg "$(c_info '4) Recommended tool categories')"
    scan_project "$YCA_PROJECT_DIR"

    # 5. Suggested next steps
    logmsg ""
    logmsg "$(c_info '5) Suggested next steps')"
    logmsg "  • harness.doctor      — see which tools are installed/missing"
    logmsg "  • deps.install        — install dependencies"
    logmsg "  • pipeline.ci         — format + lint + build + test (safe dry run of CI)"
    logmsg "  • sec.pipeline        — scan for secrets / IaC / code issues"

    emit result "$(jq -n --arg k "$detected" '{ok:true,summary:"onboarding complete",data:{toolchain:$k}}')"
}

# project.hotspots — churn analysis: the files that change most are where bugs
# live and refactors pay. Inputs: days (window, default 90).
wf_project_hotspots() {
    doctor_check_needs "git" || return 1
    local days="${INPUT_days:-90}"
    val_is_int "$days" "INPUT_days" || return 1
    emit_progress "hotspots" "churn over the last ${days} days" 20
    local churn
    churn=$(cd "$YCA_PROJECT_DIR" && git log --since="${days} days ago" --name-only --pretty=format: 2>/dev/null | grep -vE '^$' | sort | uniq -c | sort -rn | head -12 || true)
    [[ -z "$churn" ]] && { emit_ok "no commits in the last ${days} days"; return 0; }
    logmsg "$(c_info "═══ Hot files (commits touching them, last ${days}d) ═══")"
    printf '%s\n' "$churn" >&2
    logmsg ""
    logmsg "  Senior read: bugs cluster where churn clusters."
    logmsg "  • about to touch a hot file? check its TEST coverage first"
    logmsg "  • hot + large + no tests = the riskiest code in the repo; change in small steps"
    logmsg "  • a config/lock file up top is noise — look at the first real source file"
    local top
    top=$(head -1 <<< "$churn" | awk '{print $2}')
    emit result "$(jq -n --arg t "$top" --argjson d "$days" \
        '{ok:true,summary:("hotspot report done; hottest: "+$t),data:{hottest:$t,days:$d}}')"
}

wf_register "project.overview"  wf_project_overview  1 safe "" "Project structure summary"
wf_register "project.hotspots"  wf_project_hotspots  1 safe "git" "Churn hotspots: the files that change most (bug magnets)"
wf_register "project.onboard"   wf_project_onboard   1 safe "" "Full onboarding: structure+profile+TODOs+scan+next steps"
wf_register "project.changelog" wf_project_changelog 1 safe "" "Update CHANGELOG.md"
wf_register "project.init"      wf_project_init      1 writes "" "Initialize a project"
