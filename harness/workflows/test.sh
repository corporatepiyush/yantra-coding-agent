# workflows/test.sh — Test workflows

wf_test_run() {
    local profile cmd
    profile=$(toolchain_profile_json)
    cmd=$(printf '%s' "$profile" | jq -r '.test // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no test command detected"; return 1; }
    emit_progress "test" "$cmd (works on my machine... let's see about yours)" 20
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" '{ok:($rc==0),summary:("tests exit "+($rc|tostring)),data:{exit_code:$rc}}')"
}

wf_test_failed() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *python*) cmd="pytest --lf" ;;
        *rust*)   cmd="cargo test --no-fail-fast" ;;
        *node*)   cmd="npm test" ;;
        *)        cmd=$(toolchain_profile_json | jq -r '.test // "npm test"') ;;
    esac
    emit_progress "test" "$cmd"
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" '{ok:($rc==0),summary:("failed tests exit "+($rc|tostring))}')"
}

wf_test_coverage() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *python*) cmd="pytest --cov" ;;
        *rust*)   cmd="cargo tarpaulin 2>/dev/null || cargo test" ;;
        *node*)   cmd="npm test -- --coverage 2>/dev/null || npm test" ;;
        *)        cmd="npm test" ;;
    esac
    emit_progress "coverage" ""
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit_ok "coverage run done"
}

# Run the suite N times and classify: a suite that passes 4/5 is not "mostly
# fine", it is flaky — this makes that visible before CI does.
wf_test_flaky() {
    local runs cmd
    runs=$(int_guard "${INPUT_runs:-5}" 5)
    (( runs < 2 )) && runs=2; (( runs > 20 )) && runs=20
    cmd=$(toolchain_profile_json | jq -r '.test // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no test command detected"; return 1; }
    local i rc failures=0 out
    local -a codes=()
    for ((i=1; i<=runs; i++)); do
        emit_progress "run" "$cmd ($i/$runs)" $(( i * 100 / (runs + 1) ))
        out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
        codes+=("$rc")
        if (( rc != 0 )); then
            ((failures++))
            # Only failing runs get their tail shown — a green run's output is noise here.
            printf '%s\n' "$out" | tail -20 >&2
        fi
        logmsg "  run $i/$runs: exit $rc"
    done
    local verdict="stable-pass"
    if (( failures == runs )); then verdict="stable-fail"
    elif (( failures > 0 )); then verdict="FLAKY"; fi
    emit result "$(jq -n --argjson r "$runs" --argjson f "$failures" --arg v "$verdict" \
        --arg codes "${codes[*]}" \
        '{ok:($f==0),summary:("test.flaky: "+$v+" ("+($f|tostring)+"/"+($r|tostring)+" runs failed)"),
          data:{runs:$r,failures:$f,verdict:$v,exit_codes:$codes}}')"
    (( failures == 0 ))
}

wf_register "test.run"      wf_test_run      1 safe "" "Run project tests"
wf_register "test.failed"   wf_test_failed   1 safe "" "Rerun failed tests"
wf_register "test.coverage" wf_test_coverage 1 safe "" "Tests with coverage"
wf_register "test.flaky"    wf_test_flaky    2 safe "" "Run tests N times to expose flakiness"
