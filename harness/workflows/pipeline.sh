# workflows/pipeline.sh — Composite CI pipelines (zero LLM tokens)
# Chains the deterministic workflows a senior would run before pushing.

# _pipeline_step LABEL CMD -> runs CMD in the project dir, streams output to
# stderr, prints "LABEL:ok" or "LABEL:fail:<rc>" on stdout for aggregation.
_pipeline_step() {
    local label="$1" cmd="$2"
    [[ -z "$cmd" || "$cmd" == "null" ]] && { printf '%s:skip' "$label"; return 0; }
    logmsg "$(c_info "▶ $label:") $cmd"
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" | tail -30 >&2
    if [[ $rc -eq 0 ]]; then printf '%s:ok' "$label"; else printf '%s:fail:%s' "$label" "$rc"; fi
}

# pipeline.ci — the pre-push gauntlet: format → lint → build → test.
# Stops reporting failure but runs every stage so the junior sees the full picture.
wf_pipeline_ci() {
    local profile
    profile=$(toolchain_profile_json)
    local fmt lint build test
    fmt=$(printf '%s' "$profile" | jq -r '.format // empty')
    lint=$(printf '%s' "$profile" | jq -r '.lint // empty')
    build=$(printf '%s' "$profile" | jq -r '.build // empty')
    test=$(printf '%s' "$profile" | jq -r '.test // empty')

    emit_progress "pipeline" "format → lint → build → test" 0
    local r_fmt r_lint r_build r_test
    r_fmt=$(_pipeline_step "format" "$fmt")
    emit_progress "pipeline" "$r_fmt" 25
    r_lint=$(_pipeline_step "lint" "$lint")
    emit_progress "pipeline" "$r_lint" 50
    r_build=$(_pipeline_step "build" "$build")
    emit_progress "pipeline" "$r_build" 75
    r_test=$(_pipeline_step "test" "$test")
    emit_progress "pipeline" "$r_test" 100

    # Overall ok = no stage reported :fail
    local all="$r_fmt $r_lint $r_build $r_test" ok=true
    [[ "$all" == *":fail"* ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" \
        --arg fmt "$r_fmt" --arg lint "$r_lint" --arg build "$r_build" --arg test "$r_test" \
        '{ok:$ok,summary:("CI pipeline "+(if $ok then "passed" else "FAILED" end)),
          data:{format:$fmt,lint:$lint,build:$build,test:$test}}')"
}

# pipeline.fix — the "make it green" pass: format + auto-fix lint, then test.
wf_pipeline_fix() {
    emit_progress "pipeline" "format → lint --fix → test" 0
    # Compose the single-purpose workflows as steps (wf_call suppresses their own
    # result frames so this pipeline emits exactly one result).
    wf_call "fmt.all" || true
    wf_call "lint.fix" || true
    local r_test
    r_test=$(_pipeline_step "test" "$(toolchain_profile_json | jq -r '.test // empty')")
    local ok=true; [[ "$r_test" == *":fail"* ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --arg test "$r_test" \
        '{ok:$ok,summary:("format+lint-fix done; tests "+(if $ok then "pass" else "FAIL" end)),data:{test:$test}}')"
}

# pipeline.preflight — read-only readiness check before a PR: lint check + test + secret scan.
wf_pipeline_preflight() {
    local profile lint test
    profile=$(toolchain_profile_json)
    lint=$(printf '%s' "$profile" | jq -r '.lint // empty')
    test=$(printf '%s' "$profile" | jq -r '.test // empty')
    emit_progress "preflight" "lint → test → secrets" 0
    local r_lint r_test r_sec
    r_lint=$(_pipeline_step "lint" "$lint")
    r_test=$(_pipeline_step "test" "$test")
    if declare -F tool_sec_scan_secrets &>/dev/null; then
        tool_sec_scan_secrets "$YCA_PROJECT_DIR" 2>&1 | tail -15 >&2 && r_sec="secrets:ok" || r_sec="secrets:review"
    else
        r_sec="secrets:skip"
    fi
    local ok=true; [[ "$r_lint $r_test" == *":fail"* ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --arg lint "$r_lint" --arg test "$r_test" --arg sec "$r_sec" \
        '{ok:$ok,summary:("preflight "+(if $ok then "clean" else "has issues" end)),data:{lint:$lint,test:$test,secrets:$sec}}')"
}

wf_register "pipeline.ci"        wf_pipeline_ci        1 safe  "" "Format+lint+build+test (pre-push gauntlet)"
wf_register "pipeline.fix"       wf_pipeline_fix       1 writes "" "Format + auto-fix lint, then test"
wf_register "pipeline.preflight" wf_pipeline_preflight 1 safe  "" "Read-only PR readiness: lint+test+secrets"
