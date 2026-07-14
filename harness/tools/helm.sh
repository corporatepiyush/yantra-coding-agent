# tools/helm.sh — Helm tools: inspect releases, diff/lint charts, render
# templates, and LLM-backed chart review. Read-only except explicit installs.

_helm_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_helm_have()    { command -v helm &>/dev/null; }

tool_helm_status() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local rel="$1"; [[ -n "$rel" ]] || { printf 'release name required'; return 1; }
    redact_secrets "$(helm status "$rel" 2>&1)"
}

tool_helm_values() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local rel="$1"; [[ -n "$rel" ]] || { printf 'release name required'; return 1; }
    # Release values commonly embed DB passwords / API keys — redact likely secret
    # values so `helm get values` can't spill credentials into the transcript/LLM
    # (the *_llm_* tools already redact; this closes the gap for a raw values dump).
    redact_secrets "$(helm get values "$rel" 2>&1)"
}

# lint — lint a local chart directory (default: project or ./chart).
tool_helm_lint() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local chart="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$chart" 2>/dev/null || { printf 'path not allowed'; return 1; }
    [[ -f "$chart/Chart.yaml" ]] || chart="$YCA_PROJECT_DIR/chart"
    helm lint "$chart" 2>&1
}

# template — render a chart's templates locally (no cluster needed).
tool_helm_template() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local chart="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$chart" 2>/dev/null || { printf 'path not allowed'; return 1; }
    helm template "$chart" 2>&1 | head -300
}

# llm_review — review a chart's values + templates for best practices.
tool_helm_llm_review() {
    local chart="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$chart" 2>/dev/null || { printf 'path not allowed'; return 1; }
    [[ -f "$chart/Chart.yaml" ]] || chart="$YCA_PROJECT_DIR/chart"
    [[ -f "$chart/Chart.yaml" ]] || { printf 'no Chart.yaml found; pass .path'; return 1; }
    local content
    content=$(printf '=== Chart.yaml ===\n%s\n\n=== values.yaml ===\n%s\n\n=== templates (rendered, truncated) ===\n%s' \
        "$(head -40 "$chart/Chart.yaml" 2>/dev/null)" \
        "$(head -80 "$chart/values.yaml" 2>/dev/null)" \
        "$(command -v helm &>/dev/null && helm template "$chart" 2>/dev/null | head -150 || printf '[helm not installed]')")
    local system_prompt='You are a Kubernetes/Helm reviewer. Review the chart below for: resource requests/limits, liveness/readiness probes, pinned image tags (not :latest), securityContext (non-root, readOnlyRootFilesystem), no hardcoded secrets, configurable replicas, PodDisruptionBudget, and sane defaults in values.yaml. Report each as [PASS/WARN/FAIL] with the file and a fix.'
    llm_analyze "$system_prompt" "$content"
}

tool_helm_doctor() {
    local out="" t
    out+="helm: $(command -v helm &>/dev/null && helm version --short 2>&1 || printf 'MISSING (brew install helm)')\n"
    for t in kubectl helmfile kustomize; do
        out+="$t: $(command -v "$t" &>/dev/null && printf 'ok' || printf 'not installed')\n"
    done
    printf '%b' "$out"
}

# ── Write / act verbs (gated; release/chart validated → no helm option injection) ─
tool_helm_upgrade() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local rel chart
    rel=$(shell_arg_safe "$(tool_arg target "$(tool_arg release "${1:-}")")") || { printf 'invalid release name'; return 1; }
    chart=$(shell_arg_safe "$(tool_arg chart)") || { printf 'invalid chart'; return 1; }
    [[ -n "$rel" && -n "$chart" ]] || { printf 'release (.target) and chart (.chart) required'; return 1; }
    confirm_action "helm upgrade --install $rel ($chart) --atomic" "helm upgrade --install --atomic --timeout 5m $rel $chart" || { confirm_denied_msg; return 1; }
    helm upgrade --install --atomic --timeout 5m "$rel" "$chart" 2>&1
}
tool_helm_rollback() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local rel rev
    rel=$(shell_arg_safe "$(tool_arg target "${1:-}")") || { printf 'invalid release name'; return 1; }
    [[ -n "$rel" ]] || { printf 'release (.target) required'; return 1; }
    rev=$(tool_arg revision); [[ -z "$rev" || "$rev" =~ ^[0-9]+$ ]] || { printf 'revision must be a number'; return 1; }
    confirm_action "helm rollback $rel ${rev:+to revision $rev}" "helm rollback $rel $rev" || { confirm_denied_msg; return 1; }
    helm rollback "$rel" ${rev:+"$rev"} 2>&1
}
tool_helm_uninstall() {
    _helm_have || { _helm_missing helm "brew install helm"; return 1; }
    local rel; rel=$(shell_arg_safe "$(tool_arg target "${1:-}")") || { printf 'invalid release name'; return 1; }
    [[ -n "$rel" ]] || { printf 'release (.target) required'; return 1; }
    confirm_action "helm UNINSTALL $rel (removes the release from the cluster)" "helm uninstall $rel" || { confirm_denied_msg; return 1; }
    helm uninstall "$rel" 2>&1
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "helm_status"     tool_helm_status     '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all helm
tool_register "helm_values"     tool_helm_values     '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all helm
tool_register "helm_lint"       tool_helm_lint       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all helm
tool_register "helm_template"   tool_helm_template   '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all helm
tool_register "helm_llm_review" tool_helm_llm_review '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all helm mid
tool_register "helm_doctor"     tool_helm_doctor     '{"type":"object","properties":{}}' safe all helm
tool_register "helm_upgrade"    tool_helm_upgrade    '{"description":"helm upgrade --install --atomic — gated","type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"chart":{"type":"string","description":"the chart"}},"required":["target","chart"]}' destructive all helm
tool_register "helm_rollback"   tool_helm_rollback   '{"description":"Roll a release back to a previous revision — gated","type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"revision":{"type":"integer","description":"the revision or commit to use"}},"required":["target"]}' destructive all helm
tool_register "helm_uninstall"  tool_helm_uninstall  '{"description":"Uninstall a release — gated","type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' destructive all helm
