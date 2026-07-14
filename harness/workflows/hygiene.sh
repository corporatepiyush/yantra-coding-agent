# workflows/hygiene.sh — Repo hygiene the way a senior keeps house (zero LLM).
# Branch graveyards, tracked junk, TODO debt, and churn hotspots.

_hyg_base_branch() {
    ( cd "$YCA_PROJECT_DIR" && {
        local b
        b=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)
        b="${b#origin/}"
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/main 2>/dev/null && b=main
        [[ -z "$b" ]] && git show-ref -q --verify refs/heads/master 2>/dev/null && b=master
        printf '%s' "${b:-main}"
    } )
}

# hygiene.branches — merged, stale, unpushed, and WIP-commit report.
# Inputs: days (staleness cutoff, default 30).
wf_hygiene_branches() {
    doctor_check_needs "git" || return 1
    local days="${INPUT_days:-30}" base
    val_is_int "$days" "INPUT_days" || return 1
    base=$(_hyg_base_branch)
    emit_progress "hygiene" "branch audit vs $base" 20

    local merged
    merged=$(cd "$YCA_PROJECT_DIR" && git branch --merged "$base" 2>/dev/null | grep -vE '^\*' | sed 's/^[+ ]*//' | grep -vxE "main|master|develop|$base" || true)

    local now="$EPOCHSECONDS" cutoff=$(( EPOCHSECONDS - days * 86400 ))
    local stale="" unpushed="" noup=""
    local name cdate up ahead
    while read -r name cdate; do
        [[ -z "$name" ]] && continue
        [[ "$cdate" -lt "$cutoff" ]] && stale+="$name ($(( (now - cdate) / 86400 ))d)  "
        if up=$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref "${name}@{u}" 2>/dev/null); then
            ahead=$(cd "$YCA_PROJECT_DIR" && git rev-list --count "${up}..${name}" 2>/dev/null || printf '0')
            [[ "$ahead" -gt 0 ]] && unpushed+="$name (+$ahead)  "
        else
            [[ "$name" != "$base" ]] && noup+="$name  "
        fi
    done < <(cd "$YCA_PROJECT_DIR" && git for-each-ref refs/heads --format='%(refname:short) %(committerdate:unix)' 2>/dev/null)

    local wip
    wip=$(cd "$YCA_PROJECT_DIR" && git log --oneline -30 2>/dev/null | grep -iE ' (wip|tmp|temp|asdf|do not merge)( |$)|fixup!|squash!' || true)

    logmsg "$(c_info '═══ Branch hygiene ═══')  (base: $base, stale after ${days}d)"
    [[ -n "$merged" ]]   && { logmsg "$(c_warn '  Merged into '"$base"' — safe to delete (git branch -d):')"; printf '%s\n' "$merged" | sed 's/^/    /' >&2; }
    [[ -n "$stale" ]]    && logmsg "$(c_warn "  Stale (>${days}d untouched): $stale")"
    [[ -n "$unpushed" ]] && logmsg "$(c_warn "  Unpushed commits (your laptop is not a backup): $unpushed")"
    [[ -n "$noup" ]]     && logmsg "  No upstream (local-only): $noup"
    if [[ -n "$wip" ]]; then
        logmsg "$(c_warn '  WIP-style commits in recent history — squash before this hits a PR:')"
        printf '%s\n' "$wip" | sed 's/^/    /' >&2
    fi
    [[ -z "$merged$stale$unpushed$noup$wip" ]] && logmsg "$(c_ok '  ✓ branch list is clean')"

    local nmerged nwip
    nmerged=$(grep -c . <<< "$merged" || true); [[ -z "$merged" ]] && nmerged=0
    nwip=$(grep -c . <<< "$wip" || true); [[ -z "$wip" ]] && nwip=0
    emit result "$(jq -n --argjson m "$nmerged" --argjson w "$nwip" --arg base "$base" \
        '{ok:true,summary:("branch hygiene: "+($m|tostring)+" deletable, "+($w|tostring)+" WIP commit(s)"),data:{base:$base,deletable:$m,wip_commits:$w}}')"
}

# hygiene.repo — tracked junk, large tracked files, .gitignore gaps, missing basics.
wf_hygiene_repo() {
    doctor_check_needs "git" || return 1
    emit_progress "hygiene" "repo audit" 20
    local -a warns=()

    local junk
    junk=$(cd "$YCA_PROJECT_DIR" && git ls-files 2>/dev/null | grep -E '(^|/)\.DS_Store$|\.log$|(^|/)node_modules/|(^|/)__pycache__/|\.pyc$|\.swp$|(^|/)(dist|build|target)/.+\.(js|map|class|o)$' | head -15 || true)
    [[ -n "$junk" ]] && warns+=("tracked junk (generated/OS files) — untrack + gitignore:
$(sed 's/^/      /' <<< "$junk")")

    if ( cd "$YCA_PROJECT_DIR" && git ls-files --error-unmatch .env &>/dev/null ); then
        warns+=(".env is TRACKED — if it ever held real secrets, rotate them; git remembers forever")
    fi

    local big
    big=$(cd "$YCA_PROJECT_DIR" && git ls-files -z 2>/dev/null | xargs -0 du -k 2>/dev/null | sort -rn | awk '$1 > 5120 {print "      " $2 " (" int($1/1024) " MiB)"}' | head -5)
    [[ -n "$big" ]] && warns+=("large tracked files (>5 MiB) — git is not object storage; consider LFS or external storage:
$big")

    local gi="$YCA_PROJECT_DIR/.gitignore" tc missing=""
    tc=$(toolchain_detect)
    if [[ ! -f "$gi" ]]; then
        warns+=("no .gitignore at all — every build artifact is one 'git add -A' away from history")
    else
        local pat
        for pat in ".DS_Store" "*.log" ".env"; do grep -qsF "$pat" "$gi" || missing+="$pat "; done
        case "$tc" in *node*)   grep -qs "node_modules" "$gi" || missing+="node_modules/ " ;; esac
        case "$tc" in *python*) grep -qs "__pycache__" "$gi" || missing+="__pycache__/ " ;; esac
        case "$tc" in *rust*)   grep -qsE '(^|/)target' "$gi" || missing+="target/ " ;; esac
        [[ -n "$missing" ]] && warns+=(".gitignore is missing the usual suspects: $missing")
    fi

    [[ -f "$YCA_PROJECT_DIR/README.md" || -f "$YCA_PROJECT_DIR/README" ]] || warns+=("no README — the next person (or you, in 6 months) starts from zero")
    compgen -G "$YCA_PROJECT_DIR/LICENSE*" >/dev/null || warns+=("no LICENSE — legally unusable by anyone else until you add one")

    logmsg "$(c_info '═══ Repo hygiene ═══')"
    local n
    for n in "${warns[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done
    [[ ${#warns[@]} -eq 0 ]] && logmsg "$(c_ok '  ✓ tidy repo — nothing tracked that shouldn'"'"'t be')"
    emit result "$(jq -n --argjson w "${#warns[@]}" \
        '{ok:($w==0),summary:("repo hygiene: "+($w|tostring)+" finding(s)"),data:{findings:$w}}')"
}

# hygiene.todos — the TODO/FIXME debt ledger: totals + worst offenders.
wf_hygiene_todos() {
    emit_progress "hygiene" "counting deferred work" 20
    local counts
    if command -v rg &>/dev/null; then
        counts=$(cd "$YCA_PROJECT_DIR" && rg -c --no-messages '\b(TODO|FIXME|HACK|XXX)\b' 2>/dev/null | sort -t: -k2 -rn || true)
    else
        counts=$(cd "$YCA_PROJECT_DIR" && grep -rcE '\b(TODO|FIXME|HACK|XXX)\b' --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ . 2>/dev/null | grep -v ':0$' | sort -t: -k2 -rn || true)
    fi
    if [[ -z "$counts" ]]; then
        emit_ok "zero TODO/FIXME/HACK markers — either disciplined or brand new"
        return 0
    fi
    local total files
    total=$(awk -F: '{s+=$NF} END{print s+0}' <<< "$counts")
    files=$(wc -l <<< "$counts" | tr -d ' ')
    logmsg "$(c_info '═══ Deferred-work ledger ═══')  ($total markers in $files files)"
    logmsg "  Worst offenders:"
    head -10 <<< "$counts" | sed 's/^/    /' >&2
    logmsg ""
    logmsg "  Senior policy: a TODO without an issue link is a decision nobody made."
    logmsg "  Pick the top file, spend 30 minutes: fix, ticket, or delete each marker."
    emit result "$(jq -n --argjson t "$total" --argjson f "$files" \
        '{ok:true,summary:($t|tostring)+" TODO/FIXME markers in "+($f|tostring)+" files",data:{markers:$t,files:$f}}')"
}

wf_register "hygiene.branches"  wf_hygiene_branches  1 safe "git" "Branch audit: merged/stale/unpushed/WIP commits"
wf_register "hygiene.repo"      wf_hygiene_repo      1 safe "git" "Repo audit: tracked junk, big files, .gitignore gaps"
wf_register "hygiene.todos"     wf_hygiene_todos     1 safe ""    "TODO/FIXME debt ledger with worst offenders"
