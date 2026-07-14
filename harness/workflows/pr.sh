# workflows/pr.sh — PR preparation done the senior way (zero LLM).
# Summarize the branch, vet the commit subjects, draft the description skeleton.

_prw_base_branch() {
    ( cd "$YCA_PROJECT_DIR" && {
        local b
        b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        b="${b#origin/}"
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/main 2>/dev/null && b=main
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/master 2>/dev/null && b=master
        printf '%s' "${b:-main}"
    } )
}

# pr.prepare — branch-vs-base summary + commit vetting + PR description draft.
# Inputs: base (default: detected), out (default: PR_DESCRIPTION.md).
wf_pr_prepare() {
    doctor_check_needs "git" || return 1
    local base="${INPUT_base:-$(_prw_base_branch)}" branch
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    [[ "$branch" == "$base" ]] && { emit_fail "you're ON $base — PRs come from a feature branch (git.branch create <name>)"; return 0; }

    local subjects ncommits
    subjects=$(cd "$YCA_PROJECT_DIR" && git log --no-merges --pretty='%s' "${base}..HEAD" 2>/dev/null)
    [[ -z "$subjects" ]] && { emit_fail "no commits ahead of $base — nothing to PR"; return 0; }
    ncommits=$(wc -l <<< "$subjects" | tr -d ' ')
    emit_progress "pr" "$ncommits commit(s) vs $base" 20

    local stat ins del nfiles
    stat=$(cd "$YCA_PROJECT_DIR" && git diff --stat "${base}...HEAD" 2>/dev/null)
    read -r ins del < <(cd "$YCA_PROJECT_DIR" && git diff --numstat "${base}...HEAD" 2>/dev/null | awk '{i+=$1; d+=$2} END{print i+0, d+0}')
    nfiles=$(cd "$YCA_PROJECT_DIR" && git diff --name-only "${base}...HEAD" 2>/dev/null | wc -l | tr -d ' ')

    # Vet the commit subjects the way a reviewer skims them.
    local -a notes=()
    local s vague=0 long=0
    while IFS= read -r s; do
        [[ ${#s} -gt 72 ]] && long=$((long + 1))
        grep -qiE '^(wip|fix|fixes|stuff|misc|minor|update|updates|changes|oops|asdf|tmp|temp|test)$|^(fix bug|more fixes|final fix|small fix)' <<< "$s" && vague=$((vague + 1))
    done <<< "$subjects"
    [[ "$vague" -gt 0 ]] && notes+=("$vague vague commit subject(s) — squash/reword before review (git rebase makes history look intentional)")
    [[ "$long" -gt 0 ]] && notes+=("$long subject(s) over 72 chars")
    (( ins + del > 400 )) && notes+=("diff is $((ins + del)) lines over $nfiles files — consider splitting into stacked PRs")

    logmsg "$(c_info "═══ PR prep: $branch → $base ═══")  ($ncommits commits, +$ins/-$del, $nfiles files)"
    printf '%s\n' "$subjects" | sed 's/^/    • /' | head -15 >&2
    local n
    for n in "${notes[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done

    # Title: single commit → its subject; else humanized branch name.
    local title
    if [[ "$ncommits" -eq 1 ]]; then
        title="$subjects"
    else
        title="${branch#*/}"; title="${title//[-_]/ }"
    fi

    local out="${INPUT_out:-$YCA_PROJECT_DIR/PR_DESCRIPTION.md}" tmpfile tcmd
    path_check_allowed "$out" || return 1
    tcmd=$(toolchain_profile_json | jq -r '.test // "make test"')
    tmpfile=$(path_temp_file yca-pr)
    {
        printf '# %s\n\n' "$title"
        printf '## Summary\n\n'
        printf '%s\n' "$subjects" | head -10 | sed 's/^/- /'
        printf '\n## Why\n\n<!-- The problem this solves and why now. Link the issue. A reviewer who only reads this section should get it. -->\n\n'
        printf '## Changes\n\n```\n%s\n```\n\n' "$(printf '%s\n' "$stat" | tail -15)"
        printf '## Testing\n\n- [ ] `%s` passes locally\n- [ ] exercised the change end-to-end once (not just unit tests)\n- [ ] <!-- how a reviewer can verify in 2 minutes -->\n\n' "$tcmd"
        printf '## Risk & rollback\n\n- Impact: <!-- low/medium/high — what breaks if this is wrong? -->\n- Rollback: <!-- revert-safe? any migration/config to undo? -->\n'
    } > "$tmpfile"

    confirm_action "Write PR description skeleton" "write $out" || { rm -f "$tmpfile"; emit_fail "cancelled"; return 0; }
    cp "$tmpfile" "$out"; rm -f "$tmpfile"
    logmsg "$(c_ok "✓ skeleton at $out — fill in Why and Risk; those are the sections reviewers actually read")"
    emit result "$(jq -n --arg o "$out" --arg t "$title" --argjson c "$ncommits" --argjson notes "${#notes[@]}" \
        '{ok:true,summary:("PR prep done: "+($c|tostring)+" commit(s), skeleton at "+$o),data:{file:$o,title:$t,commits:$c,notes:$notes}}')"
}

# pr.review-triage — read-only situational awareness for the current branch's PR:
# state + review decision + failing checks + open review threads/comments. This is
# the "what does the PR actually look like right now" surface the act-half was
# missing. Zero mutations, so it is `safe`.
wf_pr_review_triage() {
    doctor_check_needs "gh" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }
    local branch
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)
    emit_progress "triage" "PR for $branch" 20

    local view
    view=$( cd "$YCA_PROJECT_DIR" && gh pr view --json number,title,state,url,isDraft,mergeable,reviewDecision,statusCheckRollup,reviews,comments 2>&1 ) || {
        emit_fail "no PR found for '$branch' (gh pr view failed) — open one with git.pr"; return 0; }

    # Pull the fields a reviewer scans first; jq is guarded so a shape change or an
    # older gh degrades to zeros instead of erroring the whole workflow.
    local number title state decision mergeable failing nthreads
    number=$(printf '%s' "$view" | jq -r '.number // "?"' 2>/dev/null)
    title=$(printf '%s'  "$view" | jq -r '.title // ""' 2>/dev/null)
    state=$(printf '%s'  "$view" | jq -r '.state // "?"' 2>/dev/null)
    decision=$(printf '%s' "$view" | jq -r '.reviewDecision // "NONE"' 2>/dev/null)
    mergeable=$(printf '%s' "$view" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null)
    failing=$(printf '%s' "$view" | jq -r '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="ERROR" or .conclusion=="CANCELLED" or .state=="FAILURE" or .state=="ERROR")] | length' 2>/dev/null || printf 0)
    nthreads=$(printf '%s' "$view" | jq -r '[.comments[]?] | length' 2>/dev/null || printf 0)
    [[ "$failing" =~ ^[0-9]+$ ]] || failing=0
    [[ "$nthreads" =~ ^[0-9]+$ ]] || nthreads=0

    logmsg "$(c_info "═══ PR #$number triage ═══")  $title"
    logmsg "  state: $state   review: $decision   mergeable: $mergeable"
    [[ "$failing" -gt 0 ]] && logmsg "$(c_fail "  ✗ $failing failing/errored check(s) — do not merge over red")"
    [[ "$decision" == "CHANGES_REQUESTED" ]] && logmsg "$(c_warn '  ⚠ changes requested — address the review before merging')"
    printf '%s' "$view" | jq -r '.comments[]? | "  • \(.author.login // "?"): \(.body|gsub("\n";" ")|.[0:100])"' 2>/dev/null | head -15 >&2

    local ok=true; { [[ "$failing" -gt 0 || "$decision" == "CHANGES_REQUESTED" ]]; } && ok=false
    emit result "$(jq -n --argjson ok "$ok" --argjson n "${number:-0}" --arg s "$state" --arg d "$decision" \
        --arg m "$mergeable" --argjson f "$failing" --argjson t "$nthreads" \
        '{ok:$ok,summary:("PR #"+($n|tostring)+": "+$s+", review "+$d+", "+($f|tostring)+" failing check(s)"),data:{number:$n,state:$s,review_decision:$d,mergeable:$m,failing_checks:$f,comments:$t}}')"
}

# pr.merge — merge the current branch's PR. `writes` + gated, and it REFUSES to
# merge over failing checks unless force:true. method ∈ squash|merge|rebase.
wf_pr_merge() {
    doctor_check_needs "gh" || return 1
    ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ) || { emit_fail "not a git repo"; return 1; }
    local method="${INPUT_method:-squash}" branch
    case "$method" in squash|merge|rebase) ;; *) emit_fail "method must be squash|merge|rebase (got '$method')"; return 0 ;; esac
    branch=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)

    local view
    view=$( cd "$YCA_PROJECT_DIR" && gh pr view --json number,url,state,mergeable,reviewDecision,statusCheckRollup 2>&1 ) || {
        emit_fail "no PR found for '$branch' — nothing to merge (open one with git.pr)"; return 0; }
    local url failing decision
    url=$(printf '%s' "$view" | jq -r '.url // ""' 2>/dev/null)
    decision=$(printf '%s' "$view" | jq -r '.reviewDecision // "NONE"' 2>/dev/null)
    failing=$(printf '%s' "$view" | jq -r '[.statusCheckRollup[]? | select(.conclusion=="FAILURE" or .conclusion=="ERROR" or .conclusion=="CANCELLED" or .state=="FAILURE" or .state=="ERROR")] | length' 2>/dev/null || printf 0)
    [[ "$failing" =~ ^[0-9]+$ ]] || failing=0

    # Respect the checks — merging over red CI is how bad releases happen.
    if [[ "$failing" -gt 0 && "${INPUT_force:-}" != "true" ]]; then
        emit_fail "$failing failing check(s) on this PR — fix them, or pass force:true to override (you shouldn't)"
        return 0
    fi
    [[ "$decision" == "CHANGES_REQUESTED" && "${INPUT_force:-}" != "true" ]] && \
        logmsg "$(c_warn '  ⚠ changes were requested on this PR — merging anyway')"

    # The gate: a merge is an outward, hard-to-undo action.
    confirm_action "Merge PR ($method)" "gh pr merge --$method for $branch ($url)" \
        || { emit_fail "cancelled"; return 0; }
    emit_progress "merge" "gh pr merge --$method" 60
    local out rc
    out=$( cd "$YCA_PROJECT_DIR" && gh pr merge "--$method" 2>&1 ) && rc=0 || rc=$?
    if [[ $rc -ne 0 ]]; then
        logmsg "$out"; emit_fail "gh pr merge FAILED (rc=$rc) — ${out:0:200}"; return 0
    fi
    emit result "$(jq -n --arg m "$method" --arg u "$url" '{ok:true,summary:("PR merged ("+$m+")"),data:{method:$m,url:$u}}')"
}

wf_register "pr.prepare"       wf_pr_prepare       1 writes "git" "Branch summary + commit vetting + PR description skeleton"
wf_register "pr.review-triage" wf_pr_review_triage 1 safe   "gh"  "Read-only PR triage: state+review+failing checks+comments"
wf_register "pr.merge"         wf_pr_merge         1 writes "gh"  "Merge the current branch's PR (gated, refuses red checks)"
