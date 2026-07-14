# core/update.sh — Auto-update via git.
#
# If YCA_DIR is a git checkout, update is just `git pull`; otherwise we print the
# one-line `git clone` to set one up. No curl/backup/syntax-check/swap machinery:
# git already gives atomic updates, content integrity, and trivial rollback
# (`git reset --hard`). This is deliberately simple.

update_check() {
    [[ "$YCA_UPDATE_ENABLED" != "true" ]] && return 0
    if ! command -v git &>/dev/null; then
        logmsg "$(c_dim 'update: git not installed; skipping')"
        return 0
    fi
    logmsg "$(c_info "$SYM_INFO Checking for updates...")"
    if [[ -d "$YCA_DIR/.git" ]]; then
        update_git_pull
    else
        logmsg "$(c_dim "update: $YCA_DIR is not a git checkout.")"
        logmsg "$(c_dim "  set one up with:  git clone $YCA_UPDATE_GIT_URL")"
    fi
}

# update_git_pull — fast-forward the checkout to the remote branch head.
# --ff-only so a diverged/dirty local never gets a surprise merge commit; if it
# can't fast-forward, we say so and leave the tree for the user to resolve.
update_git_pull() {
    local branch="${YCA_UPDATE_BRANCH:-main}"
    if [[ "$YCA_SAFETY_CONFIRM" == "true" && "$YCA_UI_MODE" == "human" ]]; then
        local answer
        answer=$(prompt_user "update" "n" "Run 'git pull' in $YCA_DIR? [y/N]") || return 0
        [[ "${answer,,}" != "y" ]] && return 0
    fi
    local out rc
    out=$( cd "$YCA_DIR" && git pull --ff-only origin "$branch" 2>&1 ); rc=$?
    if (( rc == 0 )); then
        logmsg "$(c_ok "$SYM_OK ${out}")"
        local sha; sha=$( cd "$YCA_DIR" && git rev-parse --short HEAD 2>/dev/null || printf '' )
        [[ -n "$sha" ]] && db_exec "INSERT INTO versions(harness_version, commit_sha) VALUES ($(sql_quote "$YCA_VERSION"), $(sql_quote "$sha"));" 2>/dev/null || true
    else
        logmsg "$(c_warn "$SYM_WARN update (git pull) failed — resolve manually: ${out}")"
        return 1
    fi
}
