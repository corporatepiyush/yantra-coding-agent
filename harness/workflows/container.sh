# workflows/container.sh — Container workflows.
# These compose the docker TOOLS via tool_invoke — one seam, JSON args, and it
# works regardless of whether the user enabled the docker tool category (the
# workflow, not the LLM toggle, decides).

wf_container_logs()   { local c="${INPUT_container:-${INPUT_name:-}}"; val_required "$c" "container" || return 1; tool_invoke docker_logs "$(jq -n --arg c "$c" --arg l "${INPUT_lines:-100}" '{container:$c,lines:$l}')" >&2; emit_ok "logs shown"; }
wf_container_health() { local c="${INPUT_container:-${INPUT_name:-}}"; val_required "$c" "container" || return 1; tool_invoke docker_inspect "$(jq -n --arg c "$c" '{container:$c}')" >&2; emit_ok "health/inspect shown"; }

# container.overview — one-call triage snapshot of the local Docker host: what is
# running (ps), live resource usage (stats), each container's health, and what is
# reclaimable (dangling). Replaces the old container.stats / container.list
# single-verb workflows — a novice asks "how are my containers doing?", not four
# separate questions. `docker stats` has no kept tool (it was a pure passthrough),
# so it is inlined here with stdin redirected from /dev/null (run_workflow does
# NOT redirect stdin, and a stdin-reading child would swallow the MCP frame
# stream — the known drain-the-session bug class).
wf_container_overview() {
    command -v docker &>/dev/null || { emit_fail "docker not installed — see https://docs.docker.com/engine/install/"; return 1; }
    logmsg "$(c_info "── containers ──")"
    tool_invoke docker_list_containers >&2
    logmsg "$(c_info "── resource usage ──")"
    docker stats --no-stream </dev/null 2>&1 >&2 || true
    logmsg "$(c_info "── health ──")"
    tool_invoke docker_health >&2
    logmsg "$(c_info "── reclaimable ──")"
    tool_invoke docker_list_dangling >&2
    emit_ok "container overview complete"
}

wf_register "container.logs"      wf_container_logs      1 safe "docker" "View container logs"
wf_register "container.health"    wf_container_health    1 safe "docker" "Container health / inspect"
wf_register "container.overview"  wf_container_overview  1 safe "docker" "Docker triage: ps + stats + health + reclaimable in one call"
