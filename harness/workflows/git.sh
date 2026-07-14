# workflows/git.sh — Git workflows

# _git_valid_ref REF -> 0 if REF is a safe branch/tag/ref token. It must start
# with an alphanumeric (so it can NEVER be parsed as an option) and carry no shell
# metacharacters or whitespace. We do NOT reuse lib/validate.sh:val_branch_name for
# version tags: its `*.*` glob rejects ANY name containing a dot, which would reject
# every v1.2.3 tag. This is the outward-facing guard for tag/push targets.
_git_valid_ref() {
    local r="$1"
    [[ -z "$r" ]] && return 1
    [[ "$r" == -* ]] && return 1
    [[ "$r" =~ ^[A-Za-z0-9][A-Za-z0-9._/+-]*$ ]] || return 1
    return 0
}

wf_git_quicksave() {
    doctor_check_needs "git" || return 1
    local message="${INPUT_message:-}"
    # A quicksave is still a commit — refuse the two messages that make history
    # useless: empty (nothing said) and the reflexive "wip". This is what
    # reviewers and future-you read; make it a real sentence.
    if [[ -z "${message//[[:space:]]/}" ]]; then
        emit_fail "commit message required — quicksave still writes history; say what changed (inputs.message)"
        return 0
    fi
    if [[ "${message,,}" == "wip" ]]; then
        emit_fail "'wip' is not a commit message — write one real sentence describing the change"
        return 0
    fi

    emit_progress "add" "staging (git add -A)" 15
    ( cd "$YCA_PROJECT_DIR" && git add -A ) || { emit_fail "git add failed"; return 1; }

    # Senior reflex before committing: run the precommit gate (conflict markers,
    # credentials, oversized files, debug leftovers). Advisory here — its findings
    # print to stderr for a human; the commit itself is local and reversible.
    emit_progress "review" "precommit gate" 35
    wf_call "review.precommit" || true

    emit_progress "commit" "committing" 55
    if ! ( cd "$YCA_PROJECT_DIR" && git commit -m "$message" ); then
        emit_fail "nothing to commit or commit failed"
        return 0
    fi
    local sha
    sha=$(cd "$YCA_PROJECT_DIR" && git rev-parse --short HEAD)
    db_exec "INSERT INTO changes(task_id, file_path, change_type, summary) VALUES (0, $(sql_quote "$YCA_PROJECT_DIR"), 'commit', $(sql_quote "$message"));" 2>/dev/null || true

    # The commit is done and undoable (git.undo). The PUSH is the OUTWARD step, so
    # it gets its own gate — separate from the commit that already landed.
    local branch remote
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    remote=$(cd "$YCA_PROJECT_DIR" && git config "branch.${branch}.remote" 2>/dev/null || printf 'origin')
    if ! confirm_action "Push $branch" "push $branch to ${remote:-origin}"; then
        emit result "$(jq -n --arg s "$sha" --arg m "$message" \
            '{ok:true,summary:("committed "+$s+" locally — push skipped (not confirmed); run git.sync when ready"),data:{commit:$s,message:$m,pushed:false}}')"
        return 0
    fi
    emit_progress "push" "pushing (the moment of truth)" 80
    local push_out push_rc
    push_out=$( cd "$YCA_PROJECT_DIR" && git push 2>&1 ) && push_rc=0 || push_rc=$?
    if [[ $push_rc -eq 0 ]]; then
        emit result "$(jq -n --arg s "$sha" --arg m "$message" '{ok:true,summary:"committed and pushed",data:{commit:$s,message:$m,pushed:true}}')"
    else
        logmsg "$push_out"
        emit result "$(jq -n --arg s "$sha" --arg m "$message" --argjson rc "$push_rc" \
            '{ok:false,summary:("committed "+$s+" locally but push FAILED (rc="+($rc|tostring)+") — check remote/auth"),data:{commit:$s,message:$m,pushed:false,rc:$rc}}')"
    fi
}

wf_git_commit() {
    doctor_check_needs "git" || return 1
    local message="${INPUT_message:-}"
    [[ -z "$message" ]] && { emit_error "422" "INPUT_message required"; return 1; }
    emit_progress "commit" "" 50
    if ( cd "$YCA_PROJECT_DIR" && git commit -m "$message" ); then
        local sha
        sha=$(cd "$YCA_PROJECT_DIR" && git rev-parse --short HEAD)
        emit_ok "committed: $sha"
    else
        emit_fail "nothing staged or commit failed"
    fi
}

wf_git_sync() {
    doctor_check_needs "git" || return 1
    emit_progress "fetch" "" 20
    ( cd "$YCA_PROJECT_DIR" && git fetch --all -p ) || { emit_fail "fetch failed"; return 1; }
    local branch remote merge_branch
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD)
    remote=$(cd "$YCA_PROJECT_DIR" && git config "branch.${branch}.remote" 2>/dev/null || printf 'origin')
    merge_branch=$(cd "$YCA_PROJECT_DIR" && git config "branch.${branch}.merge" 2>/dev/null | sed 's|refs/heads/||' || printf "$branch")
    emit_progress "rebase" "onto $remote/$merge_branch" 50
    local synced_via=""
    if ( cd "$YCA_PROJECT_DIR" && git rebase "${remote}/${merge_branch}" ); then
        synced_via="rebase"
    else
        ( cd "$YCA_PROJECT_DIR" && git rebase --abort 2>/dev/null || true )
        if ( cd "$YCA_PROJECT_DIR" && git merge "${remote}/${merge_branch}" ); then
            synced_via="merge"
        else
            emit_fail "sync failed — conflicts to resolve (git.conflict-assist)"
            return 0
        fi
    fi
    # Local history is updated; the PUSH is the outward step. Capture its REAL exit
    # code — a push that failed (rejected, no auth, unreachable remote) must be
    # reported as a failure, never masked with `|| true` then a success frame.
    emit_progress "push" "pushing to $remote/$merge_branch" 80
    local push_out push_rc
    push_out=$( cd "$YCA_PROJECT_DIR" && git push 2>&1 ) && push_rc=0 || push_rc=$?
    if [[ $push_rc -eq 0 ]]; then
        emit result "$(jq -n --arg v "$synced_via" --arg b "$branch" \
            '{ok:true,summary:("synced via "+$v+" and pushed"),data:{via:$v,branch:$b,pushed:true}}')"
    else
        logmsg "$push_out"
        emit result "$(jq -n --arg v "$synced_via" --arg b "$branch" --argjson rc "$push_rc" \
            '{ok:false,summary:("synced via "+$v+" locally but push FAILED (rc="+($rc|tostring)+") — check remote/auth"),data:{via:$v,branch:$b,pushed:false,rc:$rc}}')"
    fi
}

wf_git_undo() {
    doctor_check_needs "git" || return 1
    local sha
    sha=$(cd "$YCA_PROJECT_DIR" && git rev-parse --short HEAD)
    ( cd "$YCA_PROJECT_DIR" && git reset --soft HEAD~1 )
    emit_ok "undid last commit $sha (changes staged)"
}

wf_git_stash() {
    doctor_check_needs "git" || return 1
    ( cd "$YCA_PROJECT_DIR" && git stash push -m "${INPUT_message:-yca-stash}" )
    emit_ok "stashed changes"
}

wf_git_branch() {
    doctor_check_needs "git" || return 1
    local action="${INPUT_action:-list}" name="${INPUT_name:-}"
    # git's human output goes to stderr (>&2) so it never pollutes the NDJSON
    # protocol stream; the structured result is the emit_ok/emit result frame.
    case "$action" in
        list)
            local branches
            branches=$(cd "$YCA_PROJECT_DIR" && git branch -a 2>&1)
            printf '%s\n' "$branches" >&2
            emit result "$(jq -n --arg b "$branches" '{ok:true,summary:"branch list",data:{branches:$b}}')" ;;
        create)
            val_required "$name" "INPUT_name" || return 1
            ( cd "$YCA_PROJECT_DIR" && git branch "$name" && git checkout "$name" ) >&2
            emit_ok "created and switched to $name" ;;
        switch)
            val_required "$name" "INPUT_name" || return 1
            ( cd "$YCA_PROJECT_DIR" && git checkout "$name" ) >&2
            emit_ok "switched to $name" ;;
    esac
}

wf_git_clean() {
    doctor_check_needs "git" || return 1
    local untracked
    untracked=$(cd "$YCA_PROJECT_DIR" && git ls-files --others --exclude-standard)
    if [[ -z "$untracked" ]]; then
        emit_ok "no untracked files"
    else
        printf '%s\n' "$untracked" >&2
        emit result "$(jq -n --arg u "$untracked" '{ok:true,summary:"untracked files found",data:{files:$u}}')"
    fi
}

wf_git_bisect() {
    doctor_check_needs "git" || return 1
    local bad="${INPUT_bad:-HEAD}" good="${INPUT_good:-}"
    val_required "$good" "INPUT_good" || return 1
    ( cd "$YCA_PROJECT_DIR" && git bisect start "$bad" "$good" )
    emit_ok "bisect started"
}

wf_git_blame_line() {
    doctor_check_needs "git" || return 1
    local file="${INPUT_file:-}" line="${INPUT_line:-}"
    val_required "$file" "INPUT_file" || return 1
    val_required "$line" "INPUT_line" || return 1
    path_check_allowed "$YCA_PROJECT_DIR/$file" || return 1
    local out
    out=$(cd "$YCA_PROJECT_DIR" && git blame -p -L "${line},${line}" -- "$file" 2>&1)
    emit result "$(jq -n --arg o "$out" '{ok:true,summary:"blame result",data:{output:$o}}')"
}

wf_git_pr() {
    doctor_check_needs "git gh" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }
    local branch
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)

    # Build a VETTED title + body via pr.prepare instead of `gh pr create --fill`
    # (which parrots raw commit subjects). pr.prepare writes a reviewed skeleton
    # ("# <title>" heading + Summary/Why/Changes/Testing/Risk) and bails cleanly
    # when you're on the base branch or have nothing ahead — so if it produced no
    # file, there is genuinely nothing to PR.
    local desc="$YCA_PROJECT_DIR/PR_DESCRIPTION.md"
    wf_call "pr.prepare" "$(jq -n --arg o "$desc" '{out:$o}')" || true
    if [[ ! -s "$desc" ]]; then
        emit_fail "no PR description generated — are you on a feature branch with commits ahead of base? (see pr.prepare)"
        return 0
    fi
    local title
    title=$(sed -n 's/^# //p' "$desc" | head -1)
    [[ -z "$title" ]] && title="$branch"

    # Push the branch — the outward step — behind a gate, with an honest exit code.
    confirm_action "Open PR for $branch" "push $branch to origin, then open a PR via gh" \
        || { emit_fail "cancelled"; return 0; }
    emit_progress "pr" "pushing $branch" 40
    local push_out push_rc
    push_out=$( cd "$YCA_PROJECT_DIR" && git push -u origin HEAD 2>&1 ) && push_rc=0 || push_rc=$?
    if [[ $push_rc -ne 0 ]]; then
        logmsg "$push_out"
        emit_fail "git push FAILED (rc=$push_rc) — no PR opened; check remote/auth"
        return 0
    fi

    # Open the PR with the vetted title/body — never claim success on a gh failure.
    emit_progress "pr" "opening PR via gh" 75
    local url gh_rc
    url=$( cd "$YCA_PROJECT_DIR" && gh pr create --title "$title" --body-file "$desc" 2>&1 ) && gh_rc=0 || gh_rc=$?
    if [[ $gh_rc -ne 0 ]]; then
        logmsg "$url"
        emit_fail "branch pushed but 'gh pr create' FAILED (rc=$gh_rc) — open the PR manually: ${url:0:200}"
        return 0
    fi
    emit result "$(jq -n --arg u "$url" --arg t "$title" '{ok:true,summary:("PR opened: "+$u),data:{url:$u,title:$t}}')"
}

# git.ship — the ONE honest release pipeline: readiness → validate → confirm →
# tag → push → (optional) GitHub release with drafted notes. Every outward step's
# exit code is checked; a failed push is reported as a failure and the local tag
# is rolled back, so nothing ever claims "released" when the remote never saw it.
wf_git_ship() {
    doctor_check_needs "git" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }

    # 1) Validate the version/tag up front (cheap, and blocks option-injection).
    local version="${INPUT_version:-}" remote="${INPUT_remote:-origin}"
    val_required "$version" "INPUT_version" || { emit_fail "version required (e.g. v1.2.0)"; return 0; }
    if ! _git_valid_ref "$version"; then
        emit_fail "invalid version/tag '$version' — must start alphanumeric with no shell metacharacters or leading '-'"
        return 0
    fi
    if ! shell_arg_safe "$remote" >/dev/null; then
        emit_fail "invalid remote name '$remote'"
        return 0
    fi

    # 2) Readiness: a release off a dirty tree / behind upstream is a rollback with
    #    extra steps. preflight now returns non-zero when it found hard blockers.
    emit_progress "ship" "release preflight" 10
    if ! wf_call "release.preflight"; then
        emit_fail "release preflight found blockers — run 'release.preflight' to see them, fix, then ship"
        return 0
    fi

    # 3) Never silently clobber an existing tag.
    if ( cd "$YCA_PROJECT_DIR" && git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 ); then
        emit_fail "tag $version already exists — bump the version or delete the tag first"
        return 0
    fi

    # 4) THE destructive gate — everything past here touches the remote / may
    #    trigger a release pipeline. Machine mode auto-denies without auto_confirm.
    confirm_action "Ship $version" "tag $version and push to $remote; may trigger a release pipeline" \
        || { emit_fail "cancelled"; return 0; }

    # 5) Tag locally (honest rc).
    emit_progress "ship" "tagging $version" 45
    local tag_out
    if ! tag_out=$( cd "$YCA_PROJECT_DIR" && git tag -a "$version" -m "release $version" 2>&1 ); then
        logmsg "$tag_out"; emit_fail "git tag $version failed"; return 0
    fi

    # 6) Push the tag — the moment of truth. NEVER `|| true`. On failure, roll the
    #    local tag back so a retry isn't blocked by our own half-finished state.
    emit_progress "ship" "pushing $version to $remote" 65
    local push_out push_rc
    push_out=$( cd "$YCA_PROJECT_DIR" && git push "$remote" "refs/tags/$version" 2>&1 ) && push_rc=0 || push_rc=$?
    if [[ $push_rc -ne 0 ]]; then
        logmsg "$push_out"
        ( cd "$YCA_PROJECT_DIR" && git tag -d "$version" >/dev/null 2>&1 || true )
        emit result "$(jq -n --arg v "$version" --arg r "$remote" --argjson rc "$push_rc" \
            '{ok:false,summary:("push of "+$v+" to "+$r+" FAILED (rc="+($rc|tostring)+") — nothing released; local tag rolled back"),data:{tag:$v,remote:$r,pushed:false,rc:$rc}}')"
        return 0
    fi

    # 7) Optional GitHub release, body = drafted release.notes (falls back to gh's
    #    own generator). The tag IS pushed at this point, so a gh failure is a
    #    partial success, reported honestly — not a hard failure.
    local via="tag+push" url=""
    if command -v gh &>/dev/null; then
        emit_progress "ship" "creating GitHub release" 85
        local notes="$YCA_PROJECT_DIR/.git/yca-ship-notes.md"
        rm -f "$notes"
        wf_call "release.notes" "$(jq -n --arg v "$version" --arg o "$notes" '{version:$v,out:$o}')" || true
        local gh_out gh_rc
        if [[ -s "$notes" ]]; then
            gh_out=$( cd "$YCA_PROJECT_DIR" && gh release create "$version" --title "$version" --notes-file "$notes" 2>&1 ) && gh_rc=0 || gh_rc=$?
        else
            gh_out=$( cd "$YCA_PROJECT_DIR" && gh release create "$version" --title "$version" --generate-notes 2>&1 ) && gh_rc=0 || gh_rc=$?
        fi
        rm -f "$notes"
        if [[ $gh_rc -eq 0 ]]; then
            via="gh release"; url="$gh_out"
        else
            logmsg "$gh_out"
            emit result "$(jq -n --arg v "$version" --arg r "$remote" \
                '{ok:false,summary:("tag "+$v+" pushed to "+$r+" but gh release create FAILED — create the GitHub release manually"),data:{tag:$v,remote:$r,pushed:true,gh_release:false}}')"
            return 0
        fi
    fi

    emit result "$(jq -n --arg v "$version" --arg r "$remote" --arg via "$via" --arg u "$url" \
        '{ok:true,summary:("shipped "+$v+" to "+$r+" via "+$via),data:{tag:$v,remote:$r,via:$via,url:$u,pushed:true}}')"
}

wf_git_release() {
    doctor_check_needs "git" || return 1
    local version="${INPUT_version:-}" notes="${INPUT_notes:-}" remote="${INPUT_remote:-origin}"
    val_required "$version" "INPUT_version" || { emit_fail "version required"; return 0; }
    if ! _git_valid_ref "$version"; then
        emit_fail "invalid version/tag '$version' — must start alphanumeric with no shell metacharacters or leading '-'"
        return 0
    fi
    shell_arg_safe "$remote" >/dev/null || { emit_fail "invalid remote name '$remote'"; return 0; }
    if ( cd "$YCA_PROJECT_DIR" && git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 ); then
        emit_fail "tag $version already exists — bump the version or delete the tag first"; return 0
    fi
    confirm_action "Release $version" "tag $version and push to $remote" \
        || { emit_fail "cancelled"; return 0; }
    local tag_out
    if ! tag_out=$( cd "$YCA_PROJECT_DIR" && git tag -a "$version" -m "${notes:-release $version}" 2>&1 ); then
        logmsg "$tag_out"; emit_fail "git tag $version failed"; return 0
    fi
    # Push the tag with an HONEST exit code — the old `|| true` claimed "released"
    # even when the push was rejected or the remote was unreachable.
    emit_progress "push" "pushing $version to $remote" 70
    local push_out push_rc
    push_out=$( cd "$YCA_PROJECT_DIR" && git push "$remote" "refs/tags/$version" 2>&1 ) && push_rc=0 || push_rc=$?
    if [[ $push_rc -eq 0 ]]; then
        emit result "$(jq -n --arg v "$version" --arg r "$remote" '{ok:true,summary:("released "+$v+" to "+$r),data:{tag:$v,remote:$r,pushed:true}}')"
    else
        logmsg "$push_out"
        ( cd "$YCA_PROJECT_DIR" && git tag -d "$version" >/dev/null 2>&1 || true )
        emit result "$(jq -n --arg v "$version" --arg r "$remote" --argjson rc "$push_rc" \
            '{ok:false,summary:("push of "+$v+" to "+$r+" FAILED (rc="+($rc|tostring)+") — nothing released; local tag rolled back"),data:{tag:$v,remote:$r,pushed:false,rc:$rc}}')"
    fi
}

# git.conflict-assist — turn a read-only conflict DIAGNOSIS (the unmerged paths
# from `git diff --diff-filter=U`) into GATED resolution. action:show (default) displays both sides of every
# conflicted file (read-only); action:continue / action:abort run the matching
# --continue / --abort for whatever merge|rebase|cherry-pick is in flight, behind
# a confirm. It refuses to --continue while unresolved paths remain.
wf_git_conflict_assist() {
    doctor_check_needs "git" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }
    local gitdir op=""
    gitdir=$(cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir 2>/dev/null)
    [[ -d "$YCA_PROJECT_DIR/$gitdir/rebase-merge" || -d "$YCA_PROJECT_DIR/$gitdir/rebase-apply" ]] && op="rebase"
    [[ -f "$YCA_PROJECT_DIR/$gitdir/MERGE_HEAD" ]] && op="merge"
    [[ -f "$YCA_PROJECT_DIR/$gitdir/CHERRY_PICK_HEAD" ]] && op="cherry-pick"

    local conflicts nconf
    conflicts=$(cd "$YCA_PROJECT_DIR" && git diff --name-only --diff-filter=U 2>/dev/null)
    nconf=$(printf '%s' "$conflicts" | grep -c . 2>/dev/null || true); [[ -z "$conflicts" ]] && nconf=0

    if [[ "$nconf" -eq 0 && -z "$op" ]]; then
        emit_ok "no conflicts and no merge/rebase/cherry-pick in progress — nothing to assist"
        return 0
    fi

    local action="${INPUT_action:-show}"
    case "$action" in
        show)
            logmsg "$(c_info "═══ Conflict assist${op:+ ($op in progress)} ═══")"
            if [[ "$nconf" -gt 0 ]]; then
                logmsg "$(c_warn "Conflicted files ($nconf):")"
                printf '%s\n' "$conflicts" | sed 's/^/    /' >&2
                logmsg "$(c_info 'Commits unique to each side (git log --merge):')"
                ( cd "$YCA_PROJECT_DIR" && git log --merge --oneline 2>/dev/null | head -20 ) | sed 's/^/    /' >&2
                logmsg "$(c_info 'Conflicting hunks (both sides, git diff):')"
                ( cd "$YCA_PROJECT_DIR" && git diff 2>/dev/null | head -200 ) >&2
            fi
            logmsg "$(c_info 'Resolve each file, `git add` it, then re-run with action:continue — or action:abort to bail out.')"
            emit result "$(jq -n --argjson n "$nconf" --arg op "${op:-none}" \
                '{ok:true,summary:("conflict assist: "+($n|tostring)+" file(s) in conflict"),data:{conflicts:$n,operation:$op}}')"
            ;;
        continue)
            [[ -z "$op" ]] && { emit_fail "no merge/rebase/cherry-pick in progress to continue"; return 0; }
            if [[ "$nconf" -gt 0 ]]; then
                emit_fail "$nconf file(s) still conflicted — resolve them and 'git add' each before continuing"
                return 0
            fi
            confirm_action "Continue $op" "git $op --continue in $YCA_PROJECT_DIR" \
                || { emit_fail "cancelled"; return 0; }
            local out rc
            out=$( cd "$YCA_PROJECT_DIR" && git "$op" --continue 2>&1 ) && rc=0 || rc=$?
            if [[ $rc -eq 0 ]]; then emit_ok "$op continued"
            else logmsg "$out"; emit_fail "git $op --continue failed (rc=$rc)"; fi
            ;;
        abort)
            [[ -z "$op" ]] && { emit_fail "no merge/rebase/cherry-pick in progress to abort"; return 0; }
            confirm_action "Abort $op" "git $op --abort — discards the in-progress $op and returns to its start" \
                || { emit_fail "cancelled"; return 0; }
            local out rc
            out=$( cd "$YCA_PROJECT_DIR" && git "$op" --abort 2>&1 ) && rc=0 || rc=$?
            if [[ $rc -eq 0 ]]; then emit_ok "$op aborted — back to the pre-$op state"
            else logmsg "$out"; emit_fail "git $op --abort failed (rc=$rc)"; fi
            ;;
        *)
            emit_fail "action must be show|continue|abort (got '$action')"; return 0 ;;
    esac
}

wf_git_worktree() {
    doctor_check_needs "git" || return 1
    local action="${INPUT_action:-list}" name="${INPUT_name:-}" path="${INPUT_path:-}" branch="${INPUT_branch:-}"
    case "$action" in
        list)
            local out
            out=$(cd "$YCA_PROJECT_DIR" && git worktree list 2>&1)
            printf '%s\n' "$out" >&2
            emit result "$(jq -n --arg w "$out" '{ok:true,summary:"worktree list",data:{worktrees:$w}}')" ;;
        add)
            val_required "$name" "INPUT_name" || return 1
            # Default layout: sibling dir <repo>-<name>, so worktrees never nest
            # inside the checkout (where they'd hit .gitignore/scanner rules).
            [[ -z "$path" ]] && path="${YCA_PROJECT_DIR%/}-${name}"
            path_check_allowed "$path" || { emit_error "403" "worktree path outside allowed directories: $path"; return 1; }
            [[ -z "$branch" ]] && branch="$name"
            emit_progress "add" "worktree $path on $branch" 50
            local out rc
            if ( cd "$YCA_PROJECT_DIR" && git show-ref --verify --quiet "refs/heads/$branch" ); then
                out=$(cd "$YCA_PROJECT_DIR" && git worktree add "$path" "$branch" 2>&1) && rc=0 || rc=$?
            else
                out=$(cd "$YCA_PROJECT_DIR" && git worktree add -b "$branch" "$path" 2>&1) && rc=0 || rc=$?
            fi
            printf '%s\n' "$out" >&2
            [[ $rc -eq 0 ]] && emit_ok "worktree added: $path ($branch)" || emit_fail "worktree add failed"
            return $rc ;;
        remove)
            [[ -z "$path" && -n "$name" ]] && path="${YCA_PROJECT_DIR%/}-${name}"
            val_required "$path" "INPUT_path (or INPUT_name)" || return 1
            path_check_allowed "$path" || { emit_error "403" "worktree path outside allowed directories: $path"; return 1; }
            emit_progress "remove" "$path" 50
            if ( cd "$YCA_PROJECT_DIR" && git worktree remove "$path" ) >&2; then
                emit_ok "worktree removed: $path"
            else
                emit_fail "worktree remove failed (uncommitted changes? use git worktree remove --force manually)"
                return 1
            fi ;;
        prune)
            ( cd "$YCA_PROJECT_DIR" && git worktree prune -v ) >&2
            emit_ok "pruned stale worktree records" ;;
        *)
            emit_error "422" "INPUT_action must be list|add|remove|prune"; return 1 ;;
    esac
}

# git.rescue — "I think I lost work" first aid (read-only, zero LLM).
# Shows everything git still has and the exact recovery commands — it changes
# nothing itself, so it is always safe to run first, before panicking.
wf_git_rescue() {
    doctor_check_needs "git" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }
    emit_progress "rescue" "inventory of recoverable state" 20

    logmsg "$(c_info '═══ Git rescue — nothing here modifies your repo ═══')"
    logmsg ""
    logmsg "$(c_info '1) Reflog — every HEAD position from the last weeks. \"Lost\" commits are here:')"
    ( cd "$YCA_PROJECT_DIR" && git reflog -15 2>/dev/null ) | sed 's/^/    /' >&2

    logmsg ""
    logmsg "$(c_info '2) Stashes:')"
    local stashes
    stashes=$(cd "$YCA_PROJECT_DIR" && git stash list 2>/dev/null)
    if [[ -n "$stashes" ]]; then printf '%s\n' "$stashes" | sed 's/^/    /' >&2
    else logmsg "    (none)"; fi

    logmsg ""
    logmsg "$(c_info '3) Dangling commits (unreachable but still stored):')"
    local dangling
    dangling=$(cd "$YCA_PROJECT_DIR" && git fsck --no-progress 2>/dev/null | grep '^dangling commit' | head -8 || true)
    if [[ -n "$dangling" ]]; then printf '%s\n' "$dangling" | sed 's/^/    /' >&2
    else logmsg "    (none)"; fi

    local orig=""
    ( cd "$YCA_PROJECT_DIR" && git rev-parse -q --verify ORIG_HEAD &>/dev/null ) && \
        orig=$(cd "$YCA_PROJECT_DIR" && git rev-parse --short ORIG_HEAD 2>/dev/null)
    if [[ -n "$orig" ]]; then
        logmsg ""
        logmsg "$(c_info "4) ORIG_HEAD = $orig — where HEAD was before the last merge/rebase/reset.")"
    fi

    logmsg ""
    logmsg "$(c_info 'Recovery recipes (copy the one that matches):')"
    logmsg "  • deleted/broke a FILE (not committed):   git checkout HEAD -- <file>"
    logmsg "  • need a lost COMMIT back:                git branch rescue/<name> <sha-from-reflog>"
    logmsg "  • regret a reset/rebase:                  git reset --hard HEAD@{1}    (check reflog entry 1 FIRST)"
    logmsg "  • lost stashed work:                      git stash apply stash@{N}"
    logmsg "  • committed to the wrong branch:          git branch right-branch && git reset --hard HEAD~1  (then switch)"
    logmsg ""
    logmsg "$(c_warn '  Rules: park anything recoverable on a rescue/* branch BEFORE experimenting,')"
    logmsg "$(c_warn '  and never run git gc / prune while hunting lost work.')"

    local nstash ndang
    nstash=$(grep -c . <<< "$stashes" || true); [[ -z "$stashes" ]] && nstash=0
    ndang=$(grep -c . <<< "$dangling" || true); [[ -z "$dangling" ]] && ndang=0
    emit result "$(jq -n --argjson s "$nstash" --argjson d "$ndang" --arg o "$orig" \
        '{ok:true,summary:("rescue inventory: "+($s|tostring)+" stash(es), "+($d|tostring)+" dangling commit(s)"),data:{stashes:$s,dangling:$d,orig_head:$o}}')"
}

wf_register "git.quicksave"  wf_git_quicksave  1 writes "git" "Add+commit+push"
wf_register "git.commit"     wf_git_commit     1 writes "git" "Commit staged changes"
wf_register "git.sync"       wf_git_sync       1 writes "git" "Fetch+rebase+push"
wf_register "git.undo"       wf_git_undo       1 writes "git" "Undo last commit (soft reset)"
wf_register "git.stash"      wf_git_stash      1 safe "git" "Stash current changes"
wf_register "git.branch"     wf_git_branch     1 safe "git" "List/create/switch branches"
wf_register "git.clean"      wf_git_clean      1 safe "git" "Show untracked files"
wf_register "git.bisect"     wf_git_bisect     3 safe "git" "Bisect for regression"
wf_register "git.blame-line" wf_git_blame_line 1 safe "git" "Show blame for a line"
wf_register "git.pr"         wf_git_pr         1 writes "git gh" "Open PR with a vetted title+body (via pr.prepare)"
wf_register "git.ship"       wf_git_ship       1 writes "git" "Honest release pipeline: preflight+validate+tag+push+gh release"
wf_register "git.release"    wf_git_release    1 writes "git" "Tag + push a release (validated, gated, honest rc)"
wf_register "git.conflict-assist" wf_git_conflict_assist 1 writes "git" "Show both sides of a conflict, then gated --continue/--abort"
wf_register "git.worktree"   wf_git_worktree   1 writes "git" "List/add/remove/prune worktrees"
wf_register "git.rescue"     wf_git_rescue     1 safe "git" "Lost-work first aid: reflog+stashes+dangling commits+recovery recipes"
