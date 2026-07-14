# workflows/secops.sh — Security operations workflows

# Human-readable tool output goes to stderr (>&2) so it never pollutes the
# NDJSON protocol stream in --ui json mode; the workflow's own result is the
# emit_ok frame. `|| true` keeps a non-zero tool exit (e.g. a missing optional
# binary) from propagating as the workflow's failure — the emit_ok still fires.
wf_sec_secrets()    { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_sec_scan_secrets "$p" >&2 || true; emit_ok "secrets scan done"; }
wf_sec_iac()        { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_sec_scan_iac "$p" >&2 || true; emit_ok "IaC scan done"; }
wf_sec_semgrep()    { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_sec_semgrep "$p" >&2 || true; emit_ok "semgrep scan done"; }
wf_sec_complexity() { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_quality_complexity "$p" >&2 || true; emit_ok "complexity done"; }
wf_sec_deadcode()   { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_quality_deadcode "$p" >&2 || true; emit_ok "deadcode done"; }
wf_sec_shellcheck() { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_quality_shellcheck "$p" >&2 || true; emit_ok "shellcheck done"; }
wf_sec_dockerfile() { local p="${INPUT_path:-$YCA_PROJECT_DIR}"; tool_quality_dockerfile "$p" >&2 || true; emit_ok "dockerfile lint done"; }

wf_sec_pipeline() {
    local p="${INPUT_path:-$YCA_PROJECT_DIR}"
    logmsg "$(c_info 'Running security pipeline...')"
    logmsg "1. Secrets scan:"
    tool_sec_scan_secrets "$p" 2>&1 | head -20 >&2 || true
    logmsg "2. IaC scan:"
    tool_sec_scan_iac "$p" 2>&1 | head -20 >&2 || true
    logmsg "3. Semgrep:"
    tool_sec_semgrep "$p" 2>&1 | head -20 >&2 || true
    emit_ok "security pipeline complete"
}

wf_register "sec.secrets"    wf_sec_secrets    1 safe "" "Scan for leaked secrets"
wf_register "sec.iac"        wf_sec_iac        1 safe "" "IaC security scan"
wf_register "sec.semgrep"    wf_sec_semgrep    1 safe "" "Run semgrep"
wf_register "sec.complexity" wf_sec_complexity 1 safe "" "Code complexity analysis"
wf_register "sec.deadcode"   wf_sec_deadcode   1 safe "" "Find dead code"
wf_register "sec.shellcheck" wf_sec_shellcheck 1 safe "" "Lint shell scripts"
wf_register "sec.dockerfile" wf_sec_dockerfile 1 safe "" "Lint Dockerfiles"
wf_register "sec.pipeline"   wf_sec_pipeline   1 safe "" "Run full security pipeline"
