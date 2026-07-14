# workflows/k8s.sh — Kubernetes workflows (delegate to tools/kubernetes.sh via
# tool_invoke, so they work regardless of the kubernetes category toggle).

wf_k8s_describe()  { tool_invoke k8s_describe "$(jq -n --arg r "${INPUT_resource:?}" --arg n "${INPUT_name:?}" '{resource:$r,name:$n}')" >&2; emit_ok "described"; }
wf_k8s_logs()      { tool_invoke k8s_logs "$(jq -n --arg p "${INPUT_pod:?}" '{pod:$p}')" >&2; emit_ok "logs shown"; }

# k8s.overview — one-call cluster-health triage: pods that are NOT running,
# crash-loop suspects (by restart count), node pressure conditions, and the
# recent warning events. Replaces the old k8s.pods / k8s.events single-verb
# workflows (a raw `kubectl get pods` is what the always-on bash tool is for) —
# this answers "is my cluster healthy?" instead. Composes the kept diagnostic
# tools, each of which encodes the field-selector / jsonpath knowledge.
wf_k8s_overview() {
    command -v kubectl &>/dev/null || { emit_fail "kubectl not installed — see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    logmsg "$(c_info "── not-running / pending pods ──")"
    tool_invoke k8s_pending_pods >&2
    logmsg "$(c_info "── restart counts (crash-loop suspects) ──")"
    tool_invoke k8s_pod_restarts >&2
    logmsg "$(c_info "── node pressure ──")"
    tool_invoke k8s_node_pressure >&2
    logmsg "$(c_info "── recent events ──")"
    tool_invoke k8s_events >&2
    emit_ok "cluster overview complete"
}

wf_register "k8s.describe"      wf_k8s_describe      1 safe "kubernetes" "Describe K8s resource"
wf_register "k8s.logs"          wf_k8s_logs          1 safe "kubernetes" "Get K8s pod logs"
wf_register "k8s.overview"      wf_k8s_overview      1 safe "kubernetes" "Cluster triage: pending pods + restarts + node pressure + events"
