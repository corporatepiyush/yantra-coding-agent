# workflows/doctor.sh — Dependency doctor workflows

# doctor.install — install missing optional tools (Homebrew-installable ones) on
# the user's behalf, auto-installing Homebrew itself if needed. Interactive; in
# json mode it reports what would be installed rather than acting unattended.
wf_doctor_install() {
    if [[ "$YCA_UI_MODE" != "human" ]]; then
        doctor_probe_all || true
        local missing=() name
        for name in "${!YCA_DEP_STATUS[@]}"; do
            [[ "${YCA_DEP_STATUS[$name]%%|*}" == "MISSING" ]] && missing+=("$name")
        done
        local formulas=() b f
        for b in "${missing[@]}"; do f=$(doctor_brew_formula "$b"); [[ -n "$f" ]] && formulas+=("$f"); done
        emit result "$(jq -n --argjson miss "$(json_arr "${missing[@]}")" --arg inst "${formulas[*]:+brew install ${formulas[*]}}" \
            '{ok:true,summary:("\($miss|length) missing tool(s)"),data:{missing:$miss,install:$inst,note:"run interactively to auto-install, or run the shown command"}}')"
        return 0
    fi
    doctor_install_missing >&2
    emit_ok "dependency install finished"
}

wf_doctor_versions() { doctor_versions_report; }

wf_register "doctor.install"  wf_doctor_install  1 writes "" "Install missing tools (via Homebrew)"
wf_register "doctor.versions" wf_doctor_versions 1 safe  "" "Check tool versions vs. 2026-07 minimums"
