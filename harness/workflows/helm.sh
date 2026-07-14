# workflows/helm.sh — Helm workflows (delegate to tools/helm.sh).

wf_helm_list() {
    if declare -F tool_helm_list &>/dev/null; then tool_helm_list >&2
    elif command -v helm &>/dev/null; then helm list --all-namespaces 2>&1 >&2
    else emit_fail "helm not installed (brew install helm)"; return 1; fi
    emit_ok "releases listed"
}

wf_register "helm.list"         wf_helm_list         1 safe "" "List Helm releases"
