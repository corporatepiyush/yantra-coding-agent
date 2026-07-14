# tools/kubernetes.sh — Kubernetes tools (shell + LLM-backed)

# ── Helpers ──────────────────────────────────────────────────────────────────
_k8s_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# Returns "-n <ns>" or "" if empty/-A
_k8s_ns_flag() {
    local ns="$1"
    [[ -z "$ns" || "$ns" == "-A" || "$ns" == "--all-namespaces" ]] && return 0
    printf -- '-n %s' "$ns"
}

# _k8s_nsflag_safe NS -> "-n <ns>" for a valid ns, "" for empty/-A, or FAIL on a
# ns carrying metachars / a leading '-' (which kubectl would read as an option →
# flag injection). Used by the write verbs.
_k8s_nsflag_safe() {
    local ns="$1"
    [[ -z "$ns" || "$ns" == "-A" || "$ns" == "--all-namespaces" ]] && return 0
    shell_arg_safe "$ns" >/dev/null || return 1
    printf -- '-n %s' "$ns"
}
# _k8s_need — kubectl-present guard. _k8s_ctx — active context (shown in every
# destructive preview so a wrong-cluster apply is caught before it runs).
_k8s_need() { command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }; }
_k8s_ctx()  { kubectl config current-context 2>/dev/null || printf '(unknown context)'; }

_k8s_redact_secrets() {
    local input="$1"
    printf '%s' "$input" | sed -E \
        -e 's/([A-Za-z_]*KEY[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g' \
        -e 's/([A-Za-z_]*TOKEN[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g' \
        -e 's/([A-Za-z_]*PASSWORD[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g' \
        -e 's/([A-Za-z_]*SECRET[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g' \
        -e 's/([A-Za-z_]*CREDENTIAL[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g' \
        -e 's/([A-Za-z_]*API_KEY[ A-Za-z_]*=[[:space:]]*)[^"'"'"'[:space:]]+/\1[REDACTED]/g'
}

# ── Shell tools ──────────────────────────────────────────────────────────────
tool_k8s_logs() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local pod="$1" lines="${2:-100}" container="${3:-}"
    [[ -n "$pod" ]] || { printf 'pod name required'; return 1; }
    local prev=""
    [[ "$container" == prev:* ]] && { prev="--previous"; container="${container#prev:}"; }
    local cflag=""
    [[ -n "$container" ]] && cflag="-c $container"
    kubectl logs "$pod" $cflag --tail "$lines" $prev 2>&1
}

tool_k8s_events() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local target="${1:-}"
    local nsflag; nsflag=$(_k8s_ns_flag "$target")
    kubectl get events $nsflag --sort-by=.lastTimestamp 2>&1 | tail -30
}

tool_k8s_describe() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local resource="$1" ns="${2:-}"
    [[ -n "$resource" ]] || { printf 'resource required (e.g. deploy/nginx, pod/my-pod)'; return 1; }
    local nsflag; nsflag=$(_k8s_ns_flag "$ns")
    kubectl describe "$resource" $nsflag 2>&1
}

tool_k8s_apply_dry_run() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local file="$1"
    [[ -n "$file" ]] || { printf 'manifest file path required'; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    # Safe: dry-run=client validates without contacting the server
    kubectl apply --dry-run=client -f "$file" 2>&1
}

# ── Write / act verbs ────────────────────────────────────────────────────────
# All gated (destructive/writes → machine mode auto-denies without consent, human
# mode previews + prompts). Args are validated FIRST (before the kubectl-present
# check) so bad input is rejected regardless: shell_arg_safe on resource/name/
# pod/ns rejects a leading '-' (kubectl flag/option injection) and shell
# metachars; destructive ops require an EXPLICIT target and never accept --all.
tool_k8s_rollout_restart() {
    local resource ns nsflag
    resource=$(shell_arg_safe "$(tool_arg resource "${1:-}")") || { printf 'invalid resource (e.g. deployment/api)'; return 1; }
    [[ -n "$resource" ]] || { printf 'resource required (e.g. deployment/api)'; return 1; }
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "ROLLOUT RESTART $resource [ctx=$(_k8s_ctx) ns=${ns:-default}]" "kubectl rollout restart $resource $nsflag" || { confirm_denied_msg; return 1; }
    kubectl rollout restart "$resource" $nsflag 2>&1
}
tool_k8s_rollout_undo() {
    local resource ns nsflag rev revflag=""
    resource=$(shell_arg_safe "$(tool_arg resource "${1:-}")") || { printf 'invalid resource'; return 1; }
    [[ -n "$resource" ]] || { printf 'resource required (e.g. deployment/api)'; return 1; }
    rev=$(tool_arg revision); [[ -z "$rev" || "$rev" =~ ^[0-9]+$ ]] || { printf 'revision must be a number'; return 1; }
    [[ -n "$rev" ]] && revflag="--to-revision=$rev"
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "ROLLOUT UNDO $resource ${rev:+to revision $rev} [ctx=$(_k8s_ctx) ns=${ns:-default}]" "kubectl rollout undo $resource $revflag $nsflag" || { confirm_denied_msg; return 1; }
    kubectl rollout undo "$resource" $revflag $nsflag 2>&1
}
tool_k8s_scale() {
    local resource replicas ns nsflag
    resource=$(shell_arg_safe "$(tool_arg resource "${1:-}")") || { printf 'invalid resource'; return 1; }
    [[ -n "$resource" ]] || { printf 'resource required (e.g. deployment/api)'; return 1; }
    replicas=$(tool_arg replicas); [[ "$replicas" =~ ^[0-9]+$ ]] || { printf 'replicas must be a non-negative integer (.replicas)'; return 1; }
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "SCALE $resource to $replicas replicas [ctx=$(_k8s_ctx) ns=${ns:-default}]" "kubectl scale $resource --replicas=$replicas $nsflag" || { confirm_denied_msg; return 1; }
    kubectl scale "$resource" --replicas="$replicas" $nsflag 2>&1
}
tool_k8s_apply() {
    local file; file=$(tool_arg file "${1:-}")
    [[ -n "$file" ]] || { printf 'manifest file path required (.file)'; return 1; }
    path_check_allowed "$file" || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    _k8s_need || return 1
    local diff; diff=$(kubectl diff -f "$file" 2>&1 | head -60)
    confirm_action "APPLY $file to the cluster [ctx=$(_k8s_ctx)]"$'\n'"diff (truncated):"$'\n'"$diff" "kubectl apply -f $file" || { confirm_denied_msg; return 1; }
    kubectl apply -f "$file" 2>&1
}
tool_k8s_delete() {
    local resource name ns nsflag
    resource=$(shell_arg_safe "$(tool_arg resource "${1:-}")") || { printf 'invalid resource'; return 1; }
    name=$(shell_arg_safe "$(tool_arg name)") || { printf 'invalid name (a leading - or metachar is refused — no --all)'; return 1; }
    [[ -n "$resource" && -n "$name" ]] || { printf 'resource and name required — an explicit object (never --all)'; return 1; }
    case "$name" in '*'|all) printf 'refused: delete a single named object, not a wildcard/all'; return 1 ;; esac
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "DELETE $resource/$name [ctx=$(_k8s_ctx) ns=${ns:-default}]" "kubectl delete $resource $name $nsflag" || { confirm_denied_msg; return 1; }
    kubectl delete "$resource" "$name" $nsflag 2>&1
}
tool_k8s_exec() {
    local pod ns nsflag cmd
    pod=$(shell_arg_safe "$(tool_arg pod "${1:-}")") || { printf 'invalid pod name'; return 1; }
    [[ -n "$pod" ]] || { printf 'pod required (.pod)'; return 1; }
    cmd=$(tool_arg command); [[ -n "$cmd" ]] || { printf 'command required (.command)'; return 1; }
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "EXEC in pod $pod [ctx=$(_k8s_ctx) ns=${ns:-default}]" "$cmd" || { confirm_denied_msg; return 1; }
    # Fixed local argv (no eval); $cmd runs INSIDE the pod via sh -c, not on the host.
    kubectl exec "$pod" $nsflag -- sh -c "$cmd" 2>&1
}
tool_k8s_port_forward() {
    local resource ns nsflag lport rport
    resource=$(shell_arg_safe "$(tool_arg resource "${1:-}")") || { printf 'invalid resource'; return 1; }
    [[ -n "$resource" ]] || { printf 'resource required (e.g. svc/api or pod/x)'; return 1; }
    lport=$(int_guard "$(tool_arg local 0)" 0); rport=$(int_guard "$(tool_arg remote_port 0)" 0)
    (( lport > 0 && rport > 0 )) || { printf 'valid local and remote_port required'; return 1; }
    ns=$(tool_arg namespace); nsflag=$(_k8s_nsflag_safe "$ns") || { printf 'invalid namespace'; return 1; }
    _k8s_need || return 1
    confirm_action "PORT-FORWARD localhost:$lport -> $resource:$rport (backgrounded) [ctx=$(_k8s_ctx) ns=${ns:-default}]" "kubectl port-forward $resource $lport:$rport $nsflag" || { confirm_denied_msg; return 1; }
    kubectl port-forward "$resource" "$lport:$rport" $nsflag >/dev/null 2>&1 &
    printf 'port-forward started (pid %s): localhost:%s -> %s:%s' "$!" "$lport" "$rport" "$resource"
}

tool_k8s_pod_events() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local pod="$1" ns="${2:-}"
    [[ -n "$pod" ]] || { printf 'pod name required'; return 1; }
    local nsflag; nsflag=$(_k8s_ns_flag "$ns")
    kubectl get events $nsflag --field-selector involvedObject.name="$pod" --sort-by=.lastTimestamp 2>&1 | tail -30
}

tool_k8s_pod_resources() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local target="${1:-}" scope="-A"
    [[ -n "$target" && "$target" != "-A" ]] && scope="-n $target"
    # <none> in REQ/LIM columns = missing requests/limits (scheduling + OOM risk)
    kubectl get pods $scope -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,REQ_CPU:.spec.containers[*].resources.requests.cpu,LIM_CPU:.spec.containers[*].resources.limits.cpu,REQ_MEM:.spec.containers[*].resources.requests.memory,LIM_MEM:.spec.containers[*].resources.limits.memory' 2>&1 | head -50
}

tool_k8s_pending_pods() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    printf '=== not-running pods ===\n'
    kubectl get pods -A --field-selector 'status.phase!=Running,status.phase!=Succeeded' 2>&1 | head -30
    printf '\n=== recent scheduling/probe failures ===\n'
    kubectl get events -A --sort-by=.lastTimestamp 2>&1 | grep -E 'FailedScheduling|Unhealthy|BackOff|FailedMount|Evicted' | tail -15 || printf '(none)\n'
}

tool_k8s_pod_restarts() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    printf 'pods by restart count (crash-loop suspects last)\n'
    kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount' 2>&1 | tail -20
}

tool_k8s_node_pressure() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{": "}{range .status.conditions[*]}{.type}{"="}{.status}{"  "}{end}{"\n"}{end}' 2>&1
    printf '\n(healthy = Ready=True and every *Pressure=False)\n'
}

tool_k8s_list_images() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    printf 'images running in the cluster (count image)\n'
    kubectl get pods -A -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.image}{"\n"}{end}{end}' 2>/dev/null \
        | sort | uniq -c | sort -rn | head -30
}

# ── LLM-backed tools ─────────────────────────────────────────────────────────
tool_k8s_llm_diagnose_pod() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local pod="$1" ns="${2:-}"
    [[ -n "$pod" ]] || { printf 'pod name required'; return 1; }
    local nsflag; nsflag=$(_k8s_ns_flag "$ns")
    local describe logs events
    describe=$(kubectl describe pod "$pod" $nsflag 2>&1 || printf '[describe failed]')
    logs=$(kubectl logs "$pod" $nsflag --previous --tail=200 2>&1 || kubectl logs "$pod" $nsflag --tail=200 2>&1 || printf '[logs unavailable]')
    events=$(kubectl get events $nsflag --field-selector involvedObject.name="$pod" --sort-by=.lastTimestamp 2>&1 | tail -20 || printf '[no events]')
    local combined
    combined=$(printf '=== POD DESCRIBE ===\n%s\n\n=== PREVIOUS LOGS (last 200) ===\n%s\n\n=== EVENTS ===\n%s\n' "$describe" "$logs" "$events")
    combined=$(_k8s_redact_secrets "$combined")
    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Kubernetes troubleshooting expert. Analyze the pod describe, previous logs, and events below. The pod is in a bad state (CrashLoopBackOff, Error, Pending, etc). Identify the root cause. Report:
1) State (what's wrong)
2) Root cause (with evidence — cite specific log lines or event messages)
3) Immediate fix
4) Long-term prevention
Be concise. If unclear, say so.
PROMPT
)
    llm_analyze "$system_prompt" "$combined"
}

tool_k8s_llm_explain_resource() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local input="$1"
    [[ -n "$input" ]] || { printf 'yaml file path or a k8s concept question required'; return 1; }
    local content
    if [[ -f "$input" ]]; then
        content=$(<"$input")
    else
        content="$input"
    fi
    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Kubernetes explainer. If given a YAML manifest, explain what it creates, what each section does, and any important behaviors. If given a concept question, explain it in plain, practical language with a minimal example. Be concise. Cover what it is, why it matters, and how to use it.
PROMPT
)
    llm_analyze "$system_prompt" "$content"
}

tool_k8s_llm_manifest_review() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local file="$1"
    [[ -n "$file" ]] || { printf 'manifest yaml file path required'; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    local content
    content=$(<"$file")
    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Kubernetes manifest reviewer. Review the YAML below against best practices: resource requests/limits present?, liveness AND readiness probes?, securityContext (runAsNonRoot: true, readOnlyRootFilesystem: true, allowPrivilegeEscalation: false, capabilities.drop: [ALL])?, image tag not :latest?, graceful termination (terminationGracePeriodSeconds)?, PDB for replicas>1?, anti-affinity for HA? Report each as:
[PASS/WARN/FAIL] check: explanation. Cite the specific yaml field.
PROMPT
)
    llm_analyze "$system_prompt" "$content"
}

tool_k8s_llm_security_audit() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    # Fetch pod security contexts (limit to 50 to avoid huge payloads)
    local pods rbac netpols
    pods=$(kubectl get pods -A -o jsonpath='{range .items[:50]}{.metadata.namespace}/{.metadata.name}{"  user="}{.spec.securityContext.runAsUser}{"  nonRoot="}{.spec.securityContext.runAsNonRoot}{"  privileged="}{.spec.containers[*].securityContext.privileged}{"\n"}{end}' 2>&1 || printf '[pods fetch failed]')
    rbac=$(kubectl get clusterrolebindings -o jsonpath='{range .items}{"\n"}{.metadata.name}{" -> "}{.roleRef.name}{"  subjects="}{.subjects[*].name}{"\n"}{end}' 2>&1 | head -30 || printf '[rbac fetch failed]')
    netpols=$(kubectl get networkpolicies -A 2>&1 || printf '[no network policies found]')
    local combined
    combined=$(printf '=== POD SECURITY CONTEXTS (top 50) ===\n%s\n\n=== CLUSTER ROLE BINDINGS ===\n%s\n\n=== NETWORK POLICIES ===\n%s\n' "$pods" "$rbac" "$netpols")
    combined=$(_k8s_redact_secrets "$combined")
    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Kubernetes security auditor. Analyze the cluster data below. Check: pods running as root (securityContext.runAsNonRoot != true)?, privileged containers (privileged: true)?, no resource limits?, no network policies (namespace is wide open)?, overly permissive RBAC (cluster-admin bindings to non-system accounts)?, default serviceaccount used by pods?, no PDB for critical workloads? Report each as CRITICAL/HIGH/MEDIUM/LOW with evidence.
PROMPT
)
    llm_analyze "$system_prompt" "$combined"
}

tool_k8s_llm_troubleshoot() {
    command -v kubectl &>/dev/null || { _k8s_missing "kubectl" "see https://kubernetes.io/docs/tasks/tools/"; return 1; }
    local nodes top_nodes failing_pods events
    nodes=$(kubectl get nodes -o wide 2>&1 || printf '[nodes fetch failed]')
    top_nodes=$(kubectl top nodes 2>&1 || printf '[metrics-server not available]')
    failing_pods=$(kubectl get pods -A --field-selector status.phase!=Running 2>&1 | head -30 || printf '[no failing pods]')
    events=$(kubectl get events -A --sort-by=.lastTimestamp 2>&1 | tail -20 || printf '[no events]')
    local combined
    combined=$(printf '=== NODES ===\n%s\n\n=== NODE RESOURCE USAGE ===\n%s\n\n=== FAILING PODS ===\n%s\n\n=== RECENT EVENTS (last 20) ===\n%s\n' "$nodes" "$top_nodes" "$failing_pods" "$events")
    combined=$(_k8s_redact_secrets "$combined")
    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Kubernetes cluster troubleshooter. Analyze the node status, resource usage, failing pods, and recent events below. Identify:
1) Node pressure (MemoryPressure, DiskPressure, PIDPressure, NetworkUnavailable)
2) Failing pods and why
3) Recent critical events (FailedScheduling, BackOff, Unhealthy, FailedMount)
Report root cause + recommended action for each. Be concise.
PROMPT
)
    llm_analyze "$system_prompt" "$combined"
}

# ── Doctor ───────────────────────────────────────────────────────────────────
tool_k8s_doctor() {
    local out=""
    out+="kubectl: "
    if command -v kubectl &>/dev/null; then
        out+="$(kubectl version --client --short 2>&1 || kubectl version --client 2>&1 | head -1)\n"
    else
        out+="MISSING\n"
    fi
    local t
    for t in helm k9s stern kubectx kubens kail; do
        local v
        if command -v "$t" &>/dev/null; then
            v=$("$t" --version 2>&1 | head -1)
        else
            v="MISSING"
        fi
        out+="$t: $v\n"
    done
    # metrics-server check
    out+="metrics-server: "
    if kubectl top pods -A &>/dev/null 2>&1; then
        out+="available\n"
    else
        out+="not available (kubectl top failed)\n"
    fi
    # current context
    out+="current-context: $(kubectl config current-context 2>&1 || printf 'none')\n"
    out+="cluster: $(kubectl config view --minify -o jsonpath='{.clusters[0].name}' 2>&1 || printf 'none')\n"
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "k8s_logs"                 tool_k8s_logs                 '{"type":"object","properties":{"pod":{"type":"string","description":"the Kubernetes pod name"},"lines":{"type":"string","description":"number of lines to return"},"value":{"type":"string","description":"the value to set"}},"required":["pod"]}' safe all kubernetes
tool_register "k8s_events"               tool_k8s_events               '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all kubernetes
tool_register "k8s_describe"             tool_k8s_describe             '{"type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"name":{"type":"string","description":"the resource name"}},"required":["resource"]}' safe all kubernetes
tool_register "k8s_apply_dry_run"        tool_k8s_apply_dry_run        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all kubernetes
tool_register "k8s_rollout_restart"      tool_k8s_rollout_restart      '{"description":"Restart a rollout (e.g. deployment/api) — gated","type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["resource"]}' destructive all kubernetes
tool_register "k8s_rollout_undo"         tool_k8s_rollout_undo         '{"description":"Roll a deployment back to the previous (or a given) revision — gated","type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"revision":{"type":"integer","description":"the revision or commit to use"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["resource"]}' destructive all kubernetes
tool_register "k8s_scale"                tool_k8s_scale                '{"description":"Scale a resource to N replicas — gated","type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"replicas":{"type":"integer","description":"the replicas"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["resource","replicas"]}' destructive all kubernetes
tool_register "k8s_apply"                tool_k8s_apply                '{"description":"Apply a manifest (shows diff first) — gated","type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all kubernetes
tool_register "k8s_delete"               tool_k8s_delete               '{"description":"Delete one explicit object (never --all) — gated","type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"name":{"type":"string","description":"the resource name"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["resource","name"]}' destructive all kubernetes
tool_register "k8s_exec"                 tool_k8s_exec                 '{"description":"Run a command inside a pod — gated","type":"object","properties":{"pod":{"type":"string","description":"the Kubernetes pod name"},"command":{"type":"string","description":"the shell command to run"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["pod","command"]}' writes all kubernetes
tool_register "k8s_port_forward"         tool_k8s_port_forward         '{"description":"Forward a local port to a resource (backgrounded) — gated","type":"object","properties":{"resource":{"type":"string","description":"the resource identifier"},"local":{"type":"integer","description":"local path"},"remote_port":{"type":"integer","description":"the remote port number"},"namespace":{"type":"string","description":"the Kubernetes namespace"}},"required":["resource","local","remote_port"]}' writes all kubernetes
tool_register "k8s_llm_diagnose_pod"     tool_k8s_llm_diagnose_pod     '{"type":"object","properties":{"pod":{"type":"string","description":"the Kubernetes pod name"},"name":{"type":"string","description":"the resource name"}},"required":["pod"]}' safe all kubernetes mid
tool_register "k8s_llm_explain_resource" tool_k8s_llm_explain_resource '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' safe all kubernetes mid
tool_register "k8s_llm_manifest_review"  tool_k8s_llm_manifest_review  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all kubernetes mid
tool_register "k8s_llm_security_audit"   tool_k8s_llm_security_audit   '{"type":"object","properties":{}}' safe all kubernetes mid
tool_register "k8s_llm_troubleshoot"     tool_k8s_llm_troubleshoot     '{"type":"object","properties":{}}' safe all kubernetes mid
tool_register "k8s_doctor"               tool_k8s_doctor               '{"type":"object","properties":{}}' safe all kubernetes
tool_register "k8s_pod_events"           tool_k8s_pod_events           '{"type":"object","properties":{"pod":{"type":"string","description":"the Kubernetes pod name"},"name":{"type":"string","description":"the resource name"}},"required":["pod"]}' safe all kubernetes
tool_register "k8s_pod_resources"            tool_k8s_pod_resources            '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all kubernetes
tool_register "k8s_pending_pods"              tool_k8s_pending_pods              '{"type":"object","properties":{}}' safe all kubernetes
tool_register "k8s_pod_restarts"             tool_k8s_pod_restarts             '{"type":"object","properties":{}}' safe all kubernetes
tool_register "k8s_node_pressure"        tool_k8s_node_pressure        '{"type":"object","properties":{}}' safe all kubernetes
tool_register "k8s_list_images"               tool_k8s_list_images               '{"type":"object","properties":{}}' safe all kubernetes
