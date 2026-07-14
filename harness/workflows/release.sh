# workflows/release.sh — Release discipline (zero LLM).
# The checks a senior runs before tagging anything, plus a notes draft.

_release_last_tag() {
    ( cd "$YCA_PROJECT_DIR" && git describe --tags --abbrev=0 2>/dev/null ) || true
}

# _release_section TITLE ITEMS... -> markdown section (nothing if no items).
_release_section() {
    local title="$1"; shift
    [[ $# -eq 0 ]] && return 0
    printf '## %s\n\n' "$title"
    local x; for x in "$@"; do printf -- '- %s\n' "$x"; done
    printf '\n'
}

# release.preflight — is this repo actually ready to cut a release?
# Clean tree, right branch, synced, commits since last tag, changelog touched,
# version bumped, no snapshot/wildcard deps. INPUT_run_tests=true also runs tests.
wf_release_preflight() {
    doctor_check_needs "git" || return 1
    local -a blockers=() warns=()
    emit_progress "preflight" "release readiness" 10

    # 1) clean tree
    local dirty
    dirty=$(cd "$YCA_PROJECT_DIR" && git status --porcelain 2>/dev/null)
    [[ -n "$dirty" ]] && blockers+=("working tree is dirty ($(wc -l <<< "$dirty" | tr -d ' ') paths) — never release uncommitted state")

    # 2) branch
    local branch
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ "$branch" =~ ^(main|master|release[/-].*)$ ]] || warns+=("releasing from '$branch' — releases usually cut from main/master or a release/* branch")

    # 3) synced with upstream
    if ( cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref '@{u}' &>/dev/null ); then
        local behind ahead
        behind=$(cd "$YCA_PROJECT_DIR" && git rev-list --count 'HEAD..@{u}' 2>/dev/null || printf '0')
        ahead=$(cd "$YCA_PROJECT_DIR" && git rev-list --count '@{u}..HEAD' 2>/dev/null || printf '0')
        [[ "$behind" -gt 0 ]] && blockers+=("behind upstream by $behind commit(s) — pull first or you'll tag stale code")
        [[ "$ahead" -gt 0 ]] && warns+=("ahead of upstream by $ahead commit(s) — push before tagging so CI sees what you ship")
    else
        warns+=("no upstream configured — nothing verifies this matches what's deployed")
    fi

    # 4) commits since last tag
    local last_tag count
    last_tag=$(_release_last_tag)
    if [[ -n "$last_tag" ]]; then
        count=$(cd "$YCA_PROJECT_DIR" && git rev-list --count "${last_tag}..HEAD" 2>/dev/null || printf '0')
        [[ "$count" -eq 0 ]] && blockers+=("zero commits since $last_tag — there is nothing to release")
    else
        warns+=("no tags yet — first release; consider starting at v0.1.0, not v1.0.0")
    fi

    if [[ -n "$last_tag" ]]; then
        # 5) changelog touched since last tag
        if compgen -G "$YCA_PROJECT_DIR/CHANGELOG*" >/dev/null; then
            local cl
            cl=$(cd "$YCA_PROJECT_DIR" && git diff --name-only "${last_tag}..HEAD" -- 'CHANGELOG*' 2>/dev/null)
            [[ -z "$cl" ]] && warns+=("CHANGELOG not updated since $last_tag — users read this, write it (or run release.notes)")
        fi
        # 6) version bump present
        local -a vfiles=(package.json Cargo.toml pyproject.toml setup.py VERSION version.txt pom.xml build.gradle build.gradle.kts)
        local vchanged
        vchanged=$(cd "$YCA_PROJECT_DIR" && git diff --name-only "${last_tag}..HEAD" -- "${vfiles[@]}" 2>/dev/null)
        [[ -z "$vchanged" ]] && warns+=("no version file changed since $last_tag — did you bump the version?")
    fi

    # 7) snapshot / wildcard / git deps
    if grep -sq -- '-SNAPSHOT' "$YCA_PROJECT_DIR/pom.xml" "$YCA_PROJECT_DIR/build.gradle" "$YCA_PROJECT_DIR/build.gradle.kts" 2>/dev/null; then
        blockers+=("SNAPSHOT dependency in the build file — releases must pin released versions")
    fi
    if [[ -f "$YCA_PROJECT_DIR/package.json" ]]; then
        local loose
        loose=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | to_entries[] | select(.value | test("^\\*$|^latest$|^git\\+|^http")) | .key' "$YCA_PROJECT_DIR/package.json" 2>/dev/null)
        [[ -n "$loose" ]] && warns+=("unpinned npm deps ($(tr '\n' ' ' <<< "$loose")) — '*'/latest/git deps make releases unreproducible")
    fi
    if [[ -f "$YCA_PROJECT_DIR/Cargo.toml" ]] && grep -sqE '^[a-zA-Z0-9_-]+[[:space:]]*=[[:space:]]*\{[^}]*git[[:space:]]*=' "$YCA_PROJECT_DIR/Cargo.toml" 2>/dev/null; then
        warns+=("git dependency in Cargo.toml — pin a released crate version before shipping")
    fi

    # 8) tests (opt-in — they can be slow)
    if [[ "${INPUT_run_tests:-}" == "true" ]]; then
        emit_progress "preflight" "running tests" 60
        local tcmd rc=0
        tcmd=$(toolchain_profile_json | jq -r '.test // empty')
        if [[ -n "$tcmd" ]]; then
            ( cd "$YCA_PROJECT_DIR" && eval "$tcmd" ) >&2 2>&1 || rc=$?
            [[ "$rc" -ne 0 ]] && blockers+=("tests fail (exit $rc) — a release with red tests is a rollback with extra steps")
        fi
    else
        warns+=("tests not run here — rerun with --run_tests true (or make sure CI is green on this exact commit)")
    fi

    local n
    logmsg "$(c_info "═══ Release preflight ═══")  (branch: $branch, last tag: ${last_tag:-none})"
    for n in "${blockers[@]}"; do logmsg "$(c_fail "  ✗ BLOCK: $n")"; done
    for n in "${warns[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done
    [[ ${#blockers[@]} -eq 0 && ${#warns[@]} -eq 0 ]] && logmsg "$(c_ok '  ✓ ready — tag it (git.release)')"

    local ok=true; [[ ${#blockers[@]} -gt 0 ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --argjson b "${#blockers[@]}" --argjson w "${#warns[@]}" --arg t "${last_tag:-}" \
        '{ok:$ok,summary:("release preflight: "+($b|tostring)+" blocker(s), "+($w|tostring)+" warning(s)"),data:{blockers:$b,warnings:$w,last_tag:$t}}')"
    # Return the readiness in the EXIT CODE too, so a composite pipeline
    # (git.ship) can wf_call this and refuse to tag when there are blockers —
    # the emitted frame is unchanged, so the client contract is preserved.
    [[ "$ok" == true ]] || return 1
    return 0
}

# release.notes — draft grouped release notes from commits since the last tag.
wf_release_notes() {
    doctor_check_needs "git" || return 1
    local last_tag subjects
    last_tag=$(_release_last_tag)
    if [[ -n "$last_tag" ]]; then
        subjects=$(cd "$YCA_PROJECT_DIR" && git log --no-merges --pretty='%s' "${last_tag}..HEAD" 2>/dev/null)
    else
        subjects=$(cd "$YCA_PROJECT_DIR" && git log --no-merges --pretty='%s' 2>/dev/null)
    fi
    [[ -z "$subjects" ]] && { emit_fail "no commits since ${last_tag:-repo start} — nothing to write up"; return 0; }

    local -a feats=() fixes=() perfs=() docs=() chores=() other=()
    local s
    while IFS= read -r s; do
        case "$s" in
            feat*|feature*)                                    feats+=("$s") ;;
            fix*|bug*|hotfix*)                                 fixes+=("$s") ;;
            perf*)                                             perfs+=("$s") ;;
            docs*|doc\ *|doc:*)                                docs+=("$s") ;;
            refactor*|chore*|test*|tests*|ci*|build*|style*)   chores+=("$s") ;;
            *)                                                 other+=("$s") ;;
        esac
    done <<< "$subjects"

    local out="${INPUT_out:-$YCA_PROJECT_DIR/RELEASE_NOTES.md}" tmpfile
    path_check_allowed "$out" || return 1
    tmpfile=$(path_temp_file yca-relnotes)
    {
        printf '# Release notes — %s\n\n' "${INPUT_version:-unreleased}"
        printf '_Since %s, drafted %s. Edit before publishing: keep the user-facing story, cut the noise._\n\n' \
            "${last_tag:-the beginning}" "$(now_stamp '%Y-%m-%d')"
        _release_section "Features"          "${feats[@]}"
        _release_section "Fixes"             "${fixes[@]}"
        _release_section "Performance"       "${perfs[@]}"
        _release_section "Docs"              "${docs[@]}"
        _release_section "Internal"          "${chores[@]}"
        _release_section "Uncategorized (fix your commit prefixes)" "${other[@]}"
    } > "$tmpfile"

    confirm_action "Write release notes draft" "write $out" || { rm -f "$tmpfile"; emit_fail "cancelled"; return 0; }
    cp "$tmpfile" "$out"; rm -f "$tmpfile"
    logmsg "$(c_ok "✓ draft at $out — now edit it like a human wrote it")"
    emit result "$(jq -n --arg o "$out" --arg t "${last_tag:-}" \
        '{ok:true,summary:("release notes drafted: "+$o),data:{file:$o,since:$t}}')"
}

wf_register "release.preflight" wf_release_preflight 1 safe   "git" "Release readiness: clean+synced+changelog+version+no snapshot deps"
wf_register "release.notes"     wf_release_notes     1 writes "git" "Draft grouped release notes since the last tag"
