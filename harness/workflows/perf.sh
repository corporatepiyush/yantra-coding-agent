# workflows/perf.sh — Build/test wall-clock discipline (zero LLM).
# Seniors notice "the build got slow" because they MEASURED it when it was fast.
# perf.baseline records; perf.compare reruns and calls out drift.

_perfw_now_ms() { local t="${EPOCHREALTIME/./}"; printf '%s' "$(( t / 1000 ))"; }

# _perfw_time CMD -> "rc:ms" (output discarded; we only want the clock).
_perfw_time() {
    local start rc
    start=$(_perfw_now_ms)
    ( cd "$YCA_PROJECT_DIR" && eval "$1" ) >/dev/null 2>&1 && rc=0 || rc=$?
    printf '%s:%s' "$rc" "$(( $(_perfw_now_ms) - start ))"
}

_perfw_file() { printf '%s' "$YCA_PROJECT_DIR/.yca-perf-baseline.json"; }

# perf.baseline — time build + test and persist as the reference point.
wf_perf_baseline() {
    local profile build test
    profile=$(toolchain_profile_json)
    build=$(printf '%s' "$profile" | jq -r '.build // empty')
    test=$(printf '%s' "$profile" | jq -r '.test // empty')
    [[ -z "$build" && -z "$test" ]] && { emit_fail "no build/test commands detected for this project"; return 1; }

    local file r b_rc="skip" b_ms=0 t_rc="skip" t_ms=0
    file=$(_perfw_file)
    confirm_action "Measure and save perf baseline" "time build+test, write $file" || { emit_fail "cancelled"; return 0; }
    if [[ -n "$build" ]]; then
        emit_progress "perf" "timing build: $build" 20
        r=$(_perfw_time "$build"); b_rc="${r%%:*}"; b_ms="${r##*:}"
    fi
    if [[ -n "$test" ]]; then
        emit_progress "perf" "timing test: $test" 60
        r=$(_perfw_time "$test"); t_rc="${r%%:*}"; t_ms="${r##*:}"
    fi
    local sha
    sha=$(cd "$YCA_PROJECT_DIR" && git rev-parse --short HEAD 2>/dev/null) || sha="n/a"
    jq -n --arg ts "$(now_stamp '%Y-%m-%dT%H:%M:%S')" --arg sha "$sha" \
        --argjson bms "$b_ms" --argjson tms "$t_ms" --arg brc "$b_rc" --arg trc "$t_rc" \
        '{ts:$ts,commit:$sha,build_ms:$bms,build_rc:$brc,test_ms:$tms,test_rc:$trc}' > "$file"
    logmsg "$(c_ok "✓ baseline saved: build ${b_ms}ms (rc $b_rc), test ${t_ms}ms (rc $t_rc) @ $sha")"
    logmsg "  Rerun 'perf.compare' after changes — a slow creep nobody measured becomes the new normal."
    emit result "$(jq -n --argjson b "$b_ms" --argjson t "$t_ms" --arg f "$file" \
        '{ok:true,summary:("baseline: build "+($b|tostring)+"ms, test "+($t|tostring)+"ms"),data:{file:$f,build_ms:$b,test_ms:$t}}')"
}

# _perfw_delta LABEL OLD NEW -> report line + "regressed"/"" on stdout.
_perfw_delta() {
    local label="$1" old="$2" new="$3"
    [[ "$old" -le 0 ]] && { logmsg "  $label: ${new}ms (no previous timing)"; return 0; }
    local pct verdict=""
    pct=$(awk -v o="$old" -v n="$new" 'BEGIN{printf "%+.1f", (n - o) * 100.0 / o}')
    if awk -v o="$old" -v n="$new" 'BEGIN{exit !(n > o * 1.15)}'; then
        logmsg "$(c_warn "  $label: ${old}ms → ${new}ms (${pct}%) — noticeably slower")"
        verdict="regressed"
    elif awk -v o="$old" -v n="$new" 'BEGIN{exit !(n < o * 0.85)}'; then
        logmsg "$(c_ok "  $label: ${old}ms → ${new}ms (${pct}%) — faster, nice")"
    else
        logmsg "  $label: ${old}ms → ${new}ms (${pct}%) — within noise"
    fi
    printf '%s' "$verdict"
}

# perf.compare — rerun build+test and diff against the stored baseline.
wf_perf_compare() {
    local file
    file=$(_perfw_file)
    [[ -f "$file" ]] || { emit_fail "no baseline yet — run perf.baseline first"; return 1; }
    local base profile build test
    base=$(<"$file")
    profile=$(toolchain_profile_json)
    build=$(printf '%s' "$profile" | jq -r '.build // empty')
    test=$(printf '%s' "$profile" | jq -r '.test // empty')

    local r b_ms=0 t_ms=0
    if [[ -n "$build" ]]; then
        emit_progress "perf" "timing build" 20
        r=$(_perfw_time "$build"); b_ms="${r##*:}"
    fi
    if [[ -n "$test" ]]; then
        emit_progress "perf" "timing test" 60
        r=$(_perfw_time "$test"); t_ms="${r##*:}"
    fi

    local ob ot ots osha
    ob=$(printf '%s' "$base" | jq -r '.build_ms // 0')
    ot=$(printf '%s' "$base" | jq -r '.test_ms // 0')
    ots=$(printf '%s' "$base" | jq -r '.ts // "?"')
    osha=$(printf '%s' "$base" | jq -r '.commit // "?"')

    logmsg "$(c_info '═══ Perf vs baseline ═══')  (baseline: $ots @ $osha)"
    local reg=""
    [[ -n "$build" ]] && reg+=$(_perfw_delta "build" "$ob" "$b_ms")
    [[ -n "$test" ]]  && reg+=$(_perfw_delta "test " "$ot" "$t_ms")
    if [[ -n "$reg" ]]; then
        logmsg "  Regression >15% — find the cause NOW (new dep? extra work in a hot path?) while the diff is small."
    fi
    emit result "$(jq -n --argjson ok "$([[ -z "$reg" ]] && printf 'true' || printf 'false')" \
        --argjson b "$b_ms" --argjson t "$t_ms" --argjson ob "$ob" --argjson ot "$ot" \
        '{ok:$ok,summary:(if $ok then "perf within noise of baseline" else "perf REGRESSED vs baseline" end),data:{build_ms:$b,test_ms:$t,baseline_build_ms:$ob,baseline_test_ms:$ot}}')"
}

wf_register "perf.baseline" wf_perf_baseline 1 writes "" "Time build+test, save as baseline (.yca-perf-baseline.json)"
wf_register "perf.compare"  wf_perf_compare  1 safe   "" "Rerun build+test and flag drift >15% vs baseline"
