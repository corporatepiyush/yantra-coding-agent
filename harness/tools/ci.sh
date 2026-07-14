# tools/ci.sh — CI/CD tools: inspect GitHub Actions / GitLab CI, list runs,
# fetch failing logs, and diagnose failures with the LLM. Turns a red X in CI
# into a concrete root cause + fix — the thing juniors most often get stuck on.

_ci_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_ci_gh()      { command -v gh &>/dev/null; }

# failed_log — the log of the most recent failed run (or a given id).
tool_ci_failed_log() {
    _ci_gh || { _ci_missing gh "brew install gh"; return 1; }
    local id="$1"
    ( cd "$YCA_PROJECT_DIR" && {
        [[ -z "$id" ]] && id=$(gh run list --status failure --limit 1 --json databaseId -q '.[0].databaseId' 2>/dev/null)
        [[ -z "$id" ]] && { printf 'no failed runs found'; exit 0; }
        gh run view "$id" --log-failed 2>&1 | tail -200
    } )
}

# lint — validate workflow/pipeline YAML files.
tool_ci_lint() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$dir" 2>/dev/null || { printf 'path not allowed'; return 1; }
    local found=0
    if [[ -d "$dir/.github/workflows" ]]; then
        found=1
        if command -v actionlint &>/dev/null; then ( cd "$dir" && actionlint 2>&1 )
        else printf 'GitHub Actions detected. Install actionlint for linting: brew install actionlint\n'
             find "$dir/.github/workflows" -name '*.y*ml' 2>/dev/null; fi
    fi
    if [[ -f "$dir/.gitlab-ci.yml" ]]; then
        found=1
        if command -v yamllint &>/dev/null; then yamllint "$dir/.gitlab-ci.yml" 2>&1
        else printf 'GitLab CI detected (.gitlab-ci.yml). Install yamllint: pip install yamllint\n'; fi
    fi
    [[ "$found" == 0 ]] && printf 'no CI config found (.github/workflows or .gitlab-ci.yml)'
}

# workflows — inventory of workflow files: name, triggers, jobs.
tool_ci_workflows() {
    local dir="${1:-$YCA_PROJECT_DIR}" f found=0
    path_check_allowed "$dir" 2>/dev/null || { printf 'path not allowed'; return 1; }
    for f in "$dir"/.github/workflows/*.y*ml; do
        [[ -f "$f" ]] || continue
        found=1
        printf '=== %s ===\n' "${f#"$dir"/}"
        sed -n '/^name:/p' "$f" | head -1
        sed -n '/^on:/,/^[a-z]/p' "$f" | head -8
        printf 'jobs: %s\n\n' "$(awk '/^jobs:/{j=1;next} j && /^  [A-Za-z0-9_-]+:/{k=$1; sub(/:.*/,"",k); printf "%s ", k} j && /^[^[:space:]]/{j=0}' "$f")"
    done
    if [[ -f "$dir/.gitlab-ci.yml" ]]; then
        found=1
        printf '=== .gitlab-ci.yml ===\nstages: %s\n' \
            "$(awk '/^stages:/{s=1;next} s && /^[[:space:]]*-/{printf "%s ", $2} s && /^[^[:space:]]/{s=0}' "$dir/.gitlab-ci.yml")"
    fi
    [[ "$found" == 1 ]] || printf 'no CI workflows found (.github/workflows or .gitlab-ci.yml)'
}

# secrets_refs — which secrets/vars the workflows reference (names only).
tool_ci_secrets_refs() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$dir" 2>/dev/null || { printf 'path not allowed'; return 1; }
    [[ -d "$dir/.github/workflows" ]] || { printf 'no .github/workflows directory'; return 1; }
    printf '=== secrets.* referenced ===\n'
    grep -rhoE 'secrets\.[A-Za-z0-9_]+' "$dir/.github/workflows" 2>/dev/null | sort | uniq -c | sort -rn
    printf '\n=== vars.* referenced ===\n'
    grep -rhoE 'vars\.[A-Za-z0-9_]+' "$dir/.github/workflows" 2>/dev/null | sort | uniq -c | sort -rn
    printf '\n(verify each exists: gh secret list / gh variable list)\n'
}

# durations — how long recent runs took (spot slow/hung pipelines).
tool_ci_step_durations() {
    _ci_gh || { _ci_missing gh "brew install gh"; return 1; }
    ( cd "$YCA_PROJECT_DIR" && gh run list --limit "$(int_guard "$(tool_arg lines 15)" 15)" \
        --json workflowName,displayTitle,conclusion,createdAt,updatedAt \
        -q '.[] | "\(.conclusion // "in_progress")\t\((.updatedAt|fromdateiso8601) - (.createdAt|fromdateiso8601))s\t\(.workflowName): \(.displayTitle)"' 2>&1 )
}

# llm_diagnose — pull the failing CI log and ask the LLM for root cause + fix.
tool_ci_llm_diagnose() {
    _ci_gh || { _ci_missing gh "brew install gh"; return 1; }
    local id="$1" log
    log=$(tool_ci_failed_log "$id")
    [[ -z "$log" || "$log" == "no failed runs found" ]] && { printf '%s' "$log"; return 0; }
    local system_prompt='You are a CI/CD failure analyst. Given the failing job log below, identify: (1) which step failed and the exact error line, (2) the root cause (dependency, flaky test, env, config, compile, lint, timeout, OOM), (3) the concrete fix (command or file change), (4) whether it is likely flaky vs deterministic. Cite the exact log lines. Do not guess beyond the log.'
    llm_analyze "$system_prompt" "$log"
}

# llm_review — review a CI config for correctness and best practices.
tool_ci_llm_review() {
    local file="$1"
    [[ -z "$file" ]] && file=$(find "$YCA_PROJECT_DIR/.github/workflows" -name '*.y*ml' 2>/dev/null | head -1)
    [[ -n "$file" ]] || file="$YCA_PROJECT_DIR/.gitlab-ci.yml"
    [[ -f "$file" ]] || { printf 'no CI config found; pass .file'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed'; return 1; }
    local content; content=$(<"$file")
    local system_prompt='You are a CI/CD reviewer. Review the pipeline config below for: caching of deps, matrix coverage, pinned action/image versions (not @main/:latest), least-privilege permissions/secrets, concurrency cancellation, timeouts, artifact handling, and separation of test/deploy. Report each as [PASS/WARN/FAIL] with line references and a fix.'
    llm_analyze "$system_prompt" "$content"
}

tool_ci_doctor() {
    local out="" t
    out+="detected CI: "
    [[ -d "$YCA_PROJECT_DIR/.github/workflows" ]] && out+="GitHub Actions "
    [[ -f "$YCA_PROJECT_DIR/.gitlab-ci.yml" ]] && out+="GitLab "
    [[ -f "$YCA_PROJECT_DIR/Jenkinsfile" ]] && out+="Jenkins "
    [[ -d "$YCA_PROJECT_DIR/.circleci" ]] && out+="CircleCI "
    out+="\n"
    for t in gh act actionlint yamllint; do
        out+="$t: $(command -v "$t" &>/dev/null && printf 'ok' || printf 'not installed')\n"
    done
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "ci_failed_log"    tool_ci_failed_log    '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all ci
tool_register "ci_lint"          tool_ci_lint          '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all ci
tool_register "ci_llm_diagnose"  tool_ci_llm_diagnose  '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all ci mid
tool_register "ci_llm_review"    tool_ci_llm_review    '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' safe all ci mid
tool_register "ci_doctor"        tool_ci_doctor        '{"type":"object","properties":{}}' safe all ci
tool_register "ci_workflows"     tool_ci_workflows     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all ci
tool_register "ci_secrets_refs"  tool_ci_secrets_refs  '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all ci
tool_register "ci_step_durations"     tool_ci_step_durations     '{"type":"object","properties":{"lines":{"type":"integer","description":"number of lines to return"}}}' safe all ci
