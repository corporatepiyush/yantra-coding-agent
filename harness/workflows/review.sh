# workflows/review.sh — Senior-reviewer gates over the current diff (zero LLM).
# Deterministic versions of the checks a senior runs before code goes anywhere.

# _review_base_branch -> origin default branch, else local main/master.
_review_base_branch() {
    ( cd "$YCA_PROJECT_DIR" && {
        local b
        b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        b="${b#origin/}"
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/main 2>/dev/null && b=main
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/master 2>/dev/null && b=master
        printf '%s' "${b:-main}"
    } )
}

# _review_added_lines DIFFARGS... -> only the '+' lines (the new code).
_review_added_lines() {
    ( cd "$YCA_PROJECT_DIR" && git diff "$@" 2>/dev/null ) | grep -E '^\+[^+]' | cut -c2- || true
}

_review_is_test() {
    [[ "$1" =~ (^|/)(tests?|__tests__|spec|specs)(/|$) ]] && return 0
    [[ "$1" =~ [._-](test|spec)\.[a-z]+$ ]] && return 0
    [[ "$1" =~ \.(test|spec)\.[a-z]+$ ]] && return 0
    return 1
}

_review_debug_count() {
    printf '%s\n' "$1" | grep -cE 'console\.(log|debug|trace)\(|\bdebugger\b|\bdbg!\(|binding\.pry|var_dump\(|pdb\.set_trace\(|\bbreakpoint\(\)|System\.out\.print|(^|[[:space:]])print\(' || true
}

# review.precommit — the gate a senior runs before `git commit`: conflict
# markers, secrets, large files, debug leftovers, lockfile drift, missing tests.
# INPUT_full=true additionally runs the pipeline.preflight (lint+test+secrets).
wf_review_precommit() {
    doctor_check_needs "git" || return 1
    local mode="staged" files
    local -a drange=(--cached)
    files=$(cd "$YCA_PROJECT_DIR" && git diff --cached --name-only 2>/dev/null)
    if [[ -z "$files" ]]; then
        mode="worktree"; drange=(HEAD)
        files=$(cd "$YCA_PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null)
    fi
    [[ -z "$files" ]] && { emit_ok "nothing to review — no staged or working-tree changes"; return 0; }
    emit_progress "review" "precommit gate over $mode changes" 10

    local -a blockers=() warns=()
    local added hits
    added=$(_review_added_lines "${drange[@]}")

    # 1) merge-conflict markers
    if printf '%s\n' "$added" | grep -qE '^(<<<<<<< |=======$|>>>>>>> )'; then
        blockers+=("merge-conflict markers in the diff — resolve them before committing")
    fi

    # 2) credentials in added lines
    hits=$(printf '%s\n' "$added" | grep -cE "AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY|(api[_-]?key|secret|token|passwd|password)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][A-Za-z0-9_/+=-]{12,}" || true)
    [[ "$hits" -gt 0 ]] && blockers+=("$hits added line(s) look like credentials — use env vars / a secret manager, never git")

    # 3) large files
    local f sz
    while IFS= read -r f; do
        [[ -f "$YCA_PROJECT_DIR/$f" ]] || continue
        sz=$(path_size "$YCA_PROJECT_DIR/$f")
        [[ "$sz" -gt 1048576 ]] && warns+=("large file: $f ($((sz / 1048576)) MiB) — artifacts/binaries usually don't belong in git")
    done <<< "$files"

    # 4) debug leftovers
    hits=$(_review_debug_count "$added")
    [[ "$hits" -gt 0 ]] && warns+=("$hits added line(s) look like debug output (console.log/print/dbg!) — strip or demote to a logger")

    # 5) manifest changed without its lockfile
    local pair m l
    for pair in "package.json:package-lock.json" "Cargo.toml:Cargo.lock" "Gemfile:Gemfile.lock" "composer.json:composer.lock"; do
        m="${pair%%:*}"; l="${pair#*:}"
        if grep -qx "$m" <<< "$files" && [[ -f "$YCA_PROJECT_DIR/$l" ]] && ! grep -qx "$l" <<< "$files"; then
            warns+=("$m changed but $l didn't — if deps changed, the lockfile must ride along")
        fi
    done

    # 6) source touched, tests not
    local src_touched=false test_touched=false
    while IFS= read -r f; do
        if _review_is_test "$f"; then test_touched=true
        elif [[ "$f" =~ \.(js|jsx|ts|tsx|py|rb|go|rs|java|kt|c|cc|cpp|h|hpp|php|sh|scala|swift)$ ]]; then src_touched=true; fi
    done <<< "$files"
    [[ "$src_touched" == true && "$test_touched" == false ]] && \
        warns+=("source changed but no test file touched — add/adjust a test, or say why in the commit body")

    # 7) optional full gate (lint + test + secret scan)
    if [[ "${INPUT_full:-}" == "true" ]]; then
        emit_progress "review" "full gate: lint + test + secrets" 60
        wf_call "pipeline.preflight" || true
    fi

    local n
    logmsg "$(c_info '═══ Precommit review ═══')  ($mode: $(wc -l <<< "$files" | tr -d ' ') files)"
    for n in "${blockers[@]}"; do logmsg "$(c_fail "  ✗ BLOCK: $n")"; done
    for n in "${warns[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done
    [[ ${#blockers[@]} -eq 0 && ${#warns[@]} -eq 0 ]] && logmsg "$(c_ok '  ✓ clean — commit away')"

    local ok=true; [[ ${#blockers[@]} -gt 0 ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --argjson b "${#blockers[@]}" --argjson w "${#warns[@]}" \
        --arg mode "$mode" \
        '{ok:$ok,summary:("precommit review: "+($b|tostring)+" blocker(s), "+($w|tostring)+" warning(s)"),data:{mode:$mode,blockers:$b,warnings:$w}}')"
}

# review.self — read your own diff the way a reviewer will, before pushing.
wf_review_self() {
    doctor_check_needs "git" || return 1
    local files
    files=$(cd "$YCA_PROJECT_DIR" && git diff --name-only HEAD 2>/dev/null)
    [[ -z "$files" ]] && { emit_ok "working tree clean — nothing to self-review"; return 0; }

    local ins del nfiles added
    read -r ins del < <(cd "$YCA_PROJECT_DIR" && git diff --numstat HEAD 2>/dev/null | awk '{i+=$1; d+=$2} END{print i+0, d+0}')
    nfiles=$(wc -l <<< "$files" | tr -d ' ')
    added=$(_review_added_lines HEAD)

    logmsg "$(c_info '═══ Self-review ═══')"
    ( cd "$YCA_PROJECT_DIR" && git diff --stat HEAD 2>/dev/null | tail -8 ) >&2
    logmsg ""

    local -a notes=()
    local hits
    (( ins + del > 400 )) && notes+=("this diff is $((ins + del)) lines across $nfiles files — split it; reviewers rubber-stamp anything over ~400 lines")
    hits=$(_review_debug_count "$added")
    [[ "$hits" -gt 0 ]] && notes+=("$hits debug statement(s) added — remove before pushing")
    hits=$(printf '%s\n' "$added" | grep -cE '\b(TODO|FIXME|HACK|XXX)\b' || true)
    [[ "$hits" -gt 0 ]] && notes+=("you're ADDING $hits TODO/FIXME marker(s) — do it now or file an issue; TODOs are where intentions go to die")
    hits=$(printf '%s\n' "$added" | grep -cE '^[[:space:]]*(//|#)[[:space:]]*[a-zA-Z_].*[;){=]' || true)
    [[ "$hits" -gt 3 ]] && notes+=("$hits line(s) look like commented-out code — delete it; git remembers so you don't have to")
    local src_touched=false test_touched=false f
    while IFS= read -r f; do
        if _review_is_test "$f"; then test_touched=true
        elif [[ "$f" =~ \.(js|jsx|ts|tsx|py|rb|go|rs|java|kt|c|cc|cpp|h|hpp|php|sh|scala|swift)$ ]]; then src_touched=true; fi
    done <<< "$files"
    [[ "$src_touched" == true && "$test_touched" == false ]] && notes+=("no test touched — 'it works' is a claim, a test is proof")

    local n
    for n in "${notes[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done
    [[ ${#notes[@]} -eq 0 ]] && logmsg "$(c_ok '  ✓ diff looks disciplined')"
    logmsg ""
    logmsg "$(c_info 'Questions a reviewer WILL ask:')"
    logmsg "  • what breaks if this fails halfway? (errors, timeouts, partial writes)"
    logmsg "  • is there a test that fails without this change?"
    logmsg "  • did you actually run it once, end to end?"
    logmsg "  • can any of this be deleted instead of added?"

    emit result "$(jq -n --argjson notes "${#notes[@]}" --argjson files "$nfiles" --argjson ins "$ins" --argjson del "$del" \
        '{ok:true,summary:("self-review: "+($notes|tostring)+" note(s), +"+($ins|tostring)+"/-"+($del|tostring)+" over "+($files|tostring)+" files"),data:{notes:$notes,files:$files,insertions:$ins,deletions:$del}}')"
}

# review.risk — deterministic risk score for the current change (0-10).
# Senior intuition, encoded: size, blast radius, critical paths, test presence.
wf_review_risk() {
    doctor_check_needs "git" || return 1
    local base="${INPUT_base:-}" desc
    local -a drange=()
    if [[ -n "$base" ]]; then
        drange=("${base}...HEAD"); desc="vs $base"
    elif [[ -n "$(cd "$YCA_PROJECT_DIR" && git status --porcelain 2>/dev/null)" ]]; then
        drange=(HEAD); desc="working tree vs HEAD"
    else
        base=$(_review_base_branch); drange=("${base}...HEAD"); desc="vs $base"
    fi
    local files ins del nfiles
    files=$(cd "$YCA_PROJECT_DIR" && git diff --name-only "${drange[@]}" 2>/dev/null)
    [[ -z "$files" ]] && { emit_ok "no diff to assess ($desc)"; return 0; }
    read -r ins del < <(cd "$YCA_PROJECT_DIR" && git diff --numstat "${drange[@]}" 2>/dev/null | awk '{i+=$1; d+=$2} END{print i+0, d+0}')
    nfiles=$(wc -l <<< "$files" | tr -d ' ')

    local score=0 lines=$((ins + del))
    local -a why=()
    (( lines > 1000 )) && { score=$((score + 3)); why+=("+3 huge diff ($lines lines)"); } \
        || { (( lines > 400 )) && { score=$((score + 2)); why+=("+2 large diff ($lines lines)"); } \
        || { (( lines > 100 )) && { score=$((score + 1)); why+=("+1 medium diff ($lines lines)"); }; }; }
    (( nfiles > 25 )) && { score=$((score + 2)); why+=("+2 wide blast radius ($nfiles files)"); } \
        || { (( nfiles > 10 )) && { score=$((score + 1)); why+=("+1 many files ($nfiles)"); }; }
    local crit
    crit=$(printf '%s\n' "$files" | grep -cE '(^|/)(Dockerfile|docker-compose[^/]*|Jenkinsfile|Makefile)$|\.github/workflows/|(^|/)migrations?(/|$)|schema|auth|secur|crypt|payment|billing|secret|\.env' || true)
    [[ "$crit" -gt 0 ]] && { score=$((score + 2)); why+=("+2 touches critical paths ($crit file(s): infra/auth/schema/payments)"); }
    if printf '%s\n' "$files" | grep -qE '(^|/)(package\.json|requirements[^/]*\.txt|pyproject\.toml|Cargo\.toml|go\.mod|pom\.xml|build\.gradle[^/]*|Gemfile|composer\.json)$'; then
        score=$((score + 1)); why+=("+1 dependency changes ride along")
    fi
    local src_touched=false test_touched=false f
    while IFS= read -r f; do
        if _review_is_test "$f"; then test_touched=true
        elif [[ "$f" =~ \.(js|jsx|ts|tsx|py|rb|go|rs|java|kt|c|cc|cpp|h|hpp|php|sh|scala|swift)$ ]]; then src_touched=true; fi
    done <<< "$files"
    [[ "$src_touched" == true && "$test_touched" == false ]] && { score=$((score + 2)); why+=("+2 no tests touched"); }
    (( score > 10 )) && score=10

    local label advice
    if (( score <= 2 )); then label="LOW"; advice="ship it — small, contained, reviewable in one pass"
    elif (( score <= 5 )); then label="MEDIUM"; advice="fine, but: get a real review (not a rubber stamp) and state the test plan in the PR"
    else label="HIGH"; advice="split the change, land behind a flag if user-facing, add tests for the critical paths, and have a rollback plan BEFORE merging"; fi

    logmsg "$(c_info "═══ Change risk ($desc) ═══")"
    local w; for w in "${why[@]}"; do logmsg "  $w"; done
    logmsg "  Score: $score/10 → $label"
    logmsg "  Senior call: $advice"
    emit result "$(jq -n --argjson s "$score" --arg l "$label" --arg a "$advice" \
        '{ok:true,summary:("risk "+($s|tostring)+"/10 ("+$l+")"),data:{score:$s,label:$l,advice:$a}}')"
}

wf_register "review.precommit" wf_review_precommit 1 safe "git" "Senior precommit gate: conflicts+secrets+size+debug+tests (add --full true for lint+test)"
wf_register "review.self"      wf_review_self      1 safe "git" "Review your own diff like a senior reviewer would"
wf_register "review.risk"      wf_review_risk      1 safe "git" "Deterministic 0-10 risk score for the current change"
