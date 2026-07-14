# workflows/devops.sh — Cross-cutting DevOps workflows (cron, manifest validate).
# Container/k8s/helm workflows live in their own namespace files
# (container.sh / k8s.sh / helm.sh).

wf_devops_cron_check() {
    logmsg "=== Systemd Timers ==="
    systemctl list-timers --all 2>/dev/null | head -20 || logmsg "(systemd not available)"
    logmsg "=== Crontab ==="
    crontab -l 2>/dev/null || logmsg "(no crontab)"
    emit_ok "schedule checked"
}

wf_devops_ci_validate() {
    local path="${INPUT_path:-$YCA_PROJECT_DIR}"
    if command -v kubeconform &>/dev/null; then kubeconform -summary "$path" 2>&1 >&2
    elif command -v kubeval &>/dev/null; then kubeval "$path" 2>&1 >&2
    else emit_fail "install kubeconform or kubeval"; return 1; fi
    emit_ok "validated"
}

wf_register "devops.cron-check" wf_devops_cron_check 1 safe "" "Check cron & systemd timers"
wf_register "devops.ci-validate" wf_devops_ci_validate 1 safe "" "Validate K8s manifests"
