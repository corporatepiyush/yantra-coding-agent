# tools/docker.sh — Docker tools (shell + LLM-backed)

# ── Helpers ──────────────────────────────────────────────────────────────────
_docker_run() {
    local cmd="$1"
    (cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1)
}
_docker_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_docker_prune_preview() {
    docker system df --format '{{.Type}}\t{{.TotalCount}}\t{{.Size}}' 2>/dev/null | awk '{printf "  %-12s %s items  %s\n",$1,$2,$3}'
}
_docker_redact_secrets() {
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
tool_docker_list_containers() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local target="${1:-}"
    case "$target" in
        all|"")  docker ps -a 2>&1 ;;
        running) docker ps 2>&1 ;;
        stopped) docker ps --filter "status=exited" --filter "status=created" 2>&1 ;;
        *)       docker ps -a --filter "name=$target" 2>&1 ;;
    esac
}

tool_docker_logs() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local container="$1" lines="${2:-100}"
    [[ -n "$container" ]] || { printf 'container name/id required'; return 1; }
    docker logs --tail "$lines" "$container" 2>&1
}

tool_docker_inspect() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local target="$1"
    [[ -n "$target" ]] || { printf 'container or image name required'; return 1; }
    docker inspect "$target" 2>&1
}

tool_docker_build() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local ctx="${1:-$YCA_PROJECT_DIR}" tag="$2"
    confirm_action "Build Docker image from $ctx${tag:+ tagged $tag}" \
        "docker build${tag:+ -t $tag} $ctx" || { printf 'build cancelled'; return 1; }
    (cd "$ctx" && docker build ${tag:+-t "$tag"} . 2>&1)
}

tool_docker_run() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local args="$1"
    [[ -n "$args" ]] || { printf 'docker run arguments required (use .command)'; return 1; }

    local warnings=""
    if printf '%s' "$args" | grep -q -- '--privileged'; then
        warnings+="  WARNING: --privileged grants all capabilities (elevated risk)\n"
    fi
    if printf '%s' "$args" | grep -qE -- '(^|[ ])--net=host([ ]|$)'; then
        warnings+="  WARNING: --net=host shares host network namespace\n"
    fi
    if printf '%s' "$args" | grep -qE -- '(^|[ ])--pid=host([ ]|$)'; then
        warnings+="  WARNING: --pid=host shares host process namespace\n"
    fi
    if printf '%s' "$args" | grep -qE -- '(^|[ ])--cap-add=ALL([ ]|$)'; then
        warnings+="  WARNING: --cap-add=ALL grants all capabilities\n"
    fi
    if printf '%s' "$args" | grep -qE -- '(^|[ ])-v /var/run/docker\.sock([ :]|$)'; then
        warnings+="  WARNING: mounting docker.sock gives container root-level host access\n"
    fi

    confirm_action "Run docker container: $args" "${warnings:+$warnings}docker run $args" || { printf 'run cancelled'; return 1; }
    # No eval: split the arg string into words and pass them as argv, so shell
    # metacharacters in an LLM-authored string (`nginx; rm -rf ~`, `$(...)`,
    # backticks, pipes) are inert instead of executing on the host. A value that
    # needs embedded spaces is a rare case better served by a follow-up exec.
    local -a _dargs; read -ra _dargs <<< "$args"
    docker run "${_dargs[@]}" 2>&1
}

tool_docker_remove() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local target="$1"
    [[ -n "$target" ]] || { printf 'container name/id required'; return 1; }
    confirm_action "Stop and remove container: $target" "docker stop $target" "docker rm $target" || { printf 'removal cancelled'; return 1; }
    docker stop "$target" 2>&1 || true
    docker rm "$target" 2>&1
}

tool_docker_prune() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    # No silent default: an empty target used to fall through to `docker system
    # prune -af` — the MOST destructive scope (wipes all stopped containers,
    # unused images, networks, and build cache). Require an explicit known scope.
    local target; target=$(tool_arg target "$1")
    local -a cmd
    case "$target" in
        system)     cmd=(docker system prune -af) ;;
        images)     cmd=(docker image prune -af) ;;
        containers) cmd=(docker container prune -f) ;;
        volumes)    cmd=(docker volume prune -f) ;;
        networks)   cmd=(docker network prune -f) ;;
        builder)    cmd=(docker builder prune -af) ;;
        *) printf 'target required: one of system|images|containers|volumes|networks|builder (no default — prune is destructive)'; return 1 ;;
    esac
    local warn=""
    [[ "$target" == "volumes" || "$target" == "system" ]] && warn="  DATA LOSS: this permanently deletes anonymous volume data.\n"
    # Preview shows EXACTLY the command that runs (the old preview rendered a
    # glued, invalid `docker system prune-a -f` that differed from the action).
    confirm_action "Prune Docker: $target\nCurrent usage:\n$(_docker_prune_preview)" "${warn}${cmd[*]}" \
        || { printf 'prune cancelled'; return 1; }
    "${cmd[@]}" 2>&1
}

tool_docker_list_dangling() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    printf '=== dangling images ===\n'
    docker images -f dangling=true 2>&1
    printf '\n=== dangling volumes ===\n'
    docker volume ls -f dangling=true 2>&1
    printf '\n=== reclaimable ===\n'
    docker system df 2>&1
}

tool_docker_container_changes() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local container="$1"
    [[ -n "$container" ]] || { printf 'container name/id required'; return 1; }
    # A=added, C=changed, D=deleted vs the image the container started from
    docker diff "$container" 2>&1 | head -100
}

# ── Write / act verbs (gated; container/image validated → no docker option
# injection; exec's command runs INSIDE the container via a fixed argv). ──────
tool_docker_exec() {
    local container cmd
    container=$(shell_arg_safe "$(tool_arg container "${1:-}")") || { printf 'invalid container name'; return 1; }
    [[ -n "$container" ]] || { printf 'container required (.container)'; return 1; }
    cmd=$(tool_arg command); [[ -n "$cmd" ]] || { printf 'command required (.command)'; return 1; }
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    confirm_action "EXEC in container $container" "$cmd" || { confirm_denied_msg; return 1; }
    docker exec "$container" sh -c "$cmd" 2>&1
}
tool_docker_restart() {
    local container
    container=$(shell_arg_safe "$(tool_arg container "$(tool_arg target "${1:-}")")") || { printf 'invalid container name'; return 1; }
    [[ -n "$container" ]] || { printf 'container required'; return 1; }
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    confirm_action "Restart container $container" "docker restart $container" || { confirm_denied_msg; return 1; }
    docker restart "$container" 2>&1
}
tool_docker_copy() {
    local src dst
    src=$(shell_arg_safe "$(tool_arg src "${1:-}")") || { printf 'invalid src'; return 1; }
    dst=$(shell_arg_safe "$(tool_arg dst)") || { printf 'invalid dst'; return 1; }
    [[ -n "$src" && -n "$dst" ]] || { printf 'src and dst required (use container:/path for the container side)'; return 1; }
    # Path-check the LOCAL side (the one without a container: ref) so a
    # container->host copy can't write, nor a host->container copy read, outside
    # the fence.
    case "$src" in *:*) : ;; *) path_check_allowed "$src" || { printf 'local source not allowed: %s' "$src"; return 1; } ;; esac
    case "$dst" in *:*) : ;; *) path_check_allowed "$dst" || { printf 'local destination not allowed: %s' "$dst"; return 1; } ;; esac
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    confirm_action "docker cp $src -> $dst" "docker cp $src $dst" || { confirm_denied_msg; return 1; }
    docker cp "$src" "$dst" 2>&1
}
tool_docker_push() {
    local image
    image=$(shell_arg_safe "$(tool_arg name "$(tool_arg target "${1:-}")")") || { printf 'invalid image ref'; return 1; }
    [[ -n "$image" ]] || { printf 'image ref required (.name, e.g. registry/repo:tag)'; return 1; }
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    confirm_action "PUSH image $image to its registry (publishes it)" "docker push $image" || { confirm_denied_msg; return 1; }
    docker push "$image" 2>&1
}

tool_docker_health() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local target="$1"
    if [[ -n "$target" ]]; then
        docker inspect --format '{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' "$target" 2>&1
        printf '\n=== last probes ===\n'
        docker inspect --format '{{if .State.Health}}{{range .State.Health.Log}}{{.End}} exit={{.ExitCode}} {{.Output}}{{end}}{{else}}n/a{{end}}' "$target" 2>&1 | tail -5
    else
        local ids; ids=$(docker ps -q 2>/dev/null)
        [[ -z "$ids" ]] && { printf 'no running containers'; return 0; }
        # shellcheck disable=SC2086
        docker inspect --format '{{.Name}}: {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' $ids 2>&1
    fi
}

# ── LLM-backed tools ─────────────────────────────────────────────────────────
tool_docker_llm_diagnose() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local container="$1"
    [[ -n "$container" ]] || { printf 'container name/id required'; return 1; }

    local inspect_data logs_data stats_data
    inspect_data=$(docker inspect "$container" 2>/dev/null || printf '[unable to inspect]')
    logs_data=$(docker logs --tail 200 "$container" 2>&1 || printf '[unable to fetch logs]')
    stats_data=$(docker stats --no-stream "$container" 2>/dev/null || printf '[unable to fetch stats]')

    local combined
    combined=$(printf '=== CONTAINER INSPECT ===\n%s\n\n=== LOGS (last 200) ===\n%s\n\n=== STATS ===\n%s' \
        "$inspect_data" "$logs_data" "$stats_data")
    combined=$(_docker_redact_secrets "$combined")

    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Docker diagnostics expert. Analyze the container inspect, logs, and stats below. Identify the root cause of the container issue. Report:
1) Root cause (with evidence from the logs)
2) Immediate fix
3) Long-term prevention
Be concise. Cite specific log lines. If the issue is unclear, say so — do not guess.
PROMPT
)
    llm_analyze "$system_prompt" "$combined"
}

tool_docker_llm_dockerfile_review() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local file="${1:-$YCA_PROJECT_DIR/Dockerfile}"

    if [[ ! -f "$file" ]]; then
        printf 'Dockerfile not found at: %s' "$file"
        return 1
    fi

    local content
    content=$(<"$file")

    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Dockerfile best-practices reviewer. Review the Dockerfile below against these checks: multi-stage builds, .dockerignore usage, non-root USER, pinned base image versions (not :latest), layer caching order, minimal base image, HEALTHCHECK, no secrets in layers, .dockerignore. Report findings as:
[PASS/WARN/FAIL] check: explanation. Cite line numbers.
PROMPT
)
    llm_analyze "$system_prompt" "$content"
}

tool_docker_llm_compose_review() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local file="${1:-$YCA_PROJECT_DIR/docker-compose.yml}"

    if [[ ! -f "$file" ]]; then
        printf 'docker-compose.yml not found at: %s' "$file"
        return 1
    fi

    local content
    content=$(<"$file")

    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Docker Compose best-practices reviewer. Review the docker-compose.yml below for: resource limits (memory/cpu), HEALTHCHECK directives, restart policy, network isolation, volume persistence, env_file vs inline environment variables, secrets management. Report findings as:
[PASS/WARN/FAIL] check: explanation. Cite line numbers.
PROMPT
)
    llm_analyze "$system_prompt" "$content"
}

tool_docker_llm_security_audit() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local target="$1"
    [[ -n "$target" ]] || { printf 'container or image name required'; return 1; }

    local inspect_data
    inspect_data=$(docker inspect "$target" 2>/dev/null || printf '[unable to inspect]')
    inspect_data=$(_docker_redact_secrets "$inspect_data")

    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a container security auditor. Analyze the container/image config below. Check: runs as root?, privileged mode?, dangerous capabilities?, mounted docker socket?, no resource limits (memory/cpu)?, no read-only filesystem?, exposed sensitive ports (databases, admin)?, secrets in env vars? Report each as CRITICAL/HIGH/MEDIUM/LOW with evidence.
PROMPT
)
    llm_analyze "$system_prompt" "$inspect_data"
}

tool_docker_llm_explain() {
    command -v docker &>/dev/null || { _docker_missing "docker" "see https://docs.docker.com/engine/install/"; return 1; }
    local command="$1"
    [[ -n "$command" ]] || { printf 'question or error text required (use .command)'; return 1; }

    local system_prompt
    system_prompt=$(cat <<'PROMPT'
You are a Docker explainer. Explain the Docker concept, error message, or command output below in plain, practical language. Cover what it means, why it happens, and how to fix or use it. Be concise. If it is an error, include the exact fix command.
PROMPT
)
    llm_analyze "$system_prompt" "$command"
}

# ── Doctor ───────────────────────────────────────────────────────────────────
tool_docker_doctor() {
    local out=""

    out+="Docker: "
    if command -v docker &>/dev/null; then
        out+="$(docker --version 2>&1)\n"
    else
        out+="MISSING\n"
    fi

    out+="Docker Compose (v2 plugin): "
    if docker compose version &>/dev/null; then
        out+="$(docker compose version 2>&1)\n"
    else
        out+="MISSING\n"
    fi

    local t
    for t in docker-buildx docker-scout trivy hadolint dive; do
        local v
        if command -v "$t" &>/dev/null; then
            v=$("$t" --version 2>&1 | head -1)
        else
            v="MISSING"
        fi
        out+="$t: $v\n"
    done

    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "docker_list_containers"                 tool_docker_list_containers                 '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on","enum":["all","running","stopped"]}}}' safe all docker
tool_register "docker_logs"               tool_docker_logs               '{"type":"object","properties":{"container":{"type":"string","description":"the container name or id"},"lines":{"type":"string","description":"number of lines to return"}},"required":["container"]}' safe all docker
tool_register "docker_inspect"            tool_docker_inspect            '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all docker
tool_register "docker_build"              tool_docker_build              '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"name":{"type":"string","description":"the resource name"}}}' writes all docker
tool_register "docker_run"                tool_docker_run                '{"type":"object","properties":{"command":{"type":"string","description":"the shell command to run"}},"required":["command"]}' writes all docker
tool_register "docker_remove"            tool_docker_remove            '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' destructive all docker
tool_register "docker_prune"              tool_docker_prune              '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' destructive all docker
tool_register "docker_llm_diagnose"       tool_docker_llm_diagnose       '{"type":"object","properties":{"container":{"type":"string","description":"the container name or id"}},"required":["container"]}' safe all docker mid
tool_register "docker_llm_dockerfile_review" tool_docker_llm_dockerfile_review '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' safe all docker mid
tool_register "docker_llm_compose_review" tool_docker_llm_compose_review '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' safe all docker mid
tool_register "docker_llm_security_audit" tool_docker_llm_security_audit '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all docker mid
tool_register "docker_llm_explain"        tool_docker_llm_explain        '{"type":"object","properties":{"command":{"type":"string","description":"the shell command to run"}},"required":["command"]}' safe all docker mid
tool_register "docker_doctor"             tool_docker_doctor             '{"type":"object","properties":{}}' safe all docker
tool_register "docker_list_dangling"           tool_docker_list_dangling           '{"type":"object","properties":{}}' safe all docker
tool_register "docker_container_changes"               tool_docker_container_changes               '{"type":"object","properties":{"container":{"type":"string","description":"the container name or id"}},"required":["container"]}' safe all docker
tool_register "docker_health"             tool_docker_health             '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all docker
tool_register "docker_exec"               tool_docker_exec               '{"description":"Run a command inside a container — gated","type":"object","properties":{"container":{"type":"string","description":"the container name or id"},"command":{"type":"string","description":"the shell command to run"}},"required":["container","command"]}' writes all docker
tool_register "docker_restart"            tool_docker_restart            '{"description":"Restart a container — gated","type":"object","properties":{"container":{"type":"string","description":"the container name or id"}},"required":["container"]}' writes all docker
tool_register "docker_copy"                 tool_docker_copy                 '{"description":"Copy files host<->container (container:/path) — gated","type":"object","properties":{"src":{"type":"string","description":"source path"},"dst":{"type":"string","description":"destination path"}},"required":["src","dst"]}' writes all docker
tool_register "docker_push"               tool_docker_push               '{"description":"Push an image to its registry — gated","type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' writes all docker
