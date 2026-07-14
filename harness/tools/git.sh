# tools/git.sh — Read-only git introspection (category: git).
# Git existed only as workflows (git.quicksave etc.); the LLM had to shell out
# via `bash` for every status/log/diff. These give it precise, token-bounded
# views instead. Everything here is read-only — mutations stay in workflows/git.sh
# where the confirmation gates live. All fields read via tool_arg ({path, file,
# pattern} collide in the generic dispatcher).

# _git_p ... — run git against the project dir without a cd subshell.
_git_p() { git -C "$YCA_PROJECT_DIR" "$@"; }

# _git_repo_check — print a friendly error (and fail) outside a repo.
_git_repo_check() {
    command -v git &>/dev/null || { printf 'git missing'; return 127; }
    _git_p rev-parse --git-dir &>/dev/null || { printf 'not a git repository: %s' "$YCA_PROJECT_DIR"; return 1; }
}

tool_git_log() {
    _git_repo_check || return $?
    local count path author grep_term
    count=$(int_guard "$(tool_arg count 20)" 20); (( count > 200 )) && count=200; (( count < 1 )) && count=20
    path=$(tool_arg path); author=$(tool_arg author); grep_term=$(tool_arg grep)
    local -a args=(log -n "$count" --date=short --pretty='format:%h %ad %an  %s')
    [[ -n "$author" ]] && args+=(--author="$author")
    [[ -n "$grep_term" ]] && args+=(--grep="$grep_term" -i)
    [[ -n "$path" ]] && args+=(-- "$path")
    _git_p "${args[@]}" 2>&1
}

tool_git_diff() {
    _git_repo_check || return $?
    local ref path staged
    ref=$(tool_arg ref); path=$(tool_arg path); staged=$(tool_arg staged false)
    [[ "$ref" == -* ]] && { printf 'invalid ref (must not start with -)'; return 1; }
    # Options and pathspec kept separate: an option appended after `--` would be
    # silently read as a pathspec, not an option.
    local -a opts=(diff) pathspec=()
    [[ "$staged" == "true" ]] && opts+=(--cached)
    [[ -n "$ref" ]] && opts+=("$ref")
    [[ -n "$path" ]] && pathspec=(-- "$path")
    local out
    out=$(_git_p "${opts[@]}" --stat "${pathspec[@]}" 2>&1 && printf '\n' \
        && _git_p "${opts[@]}" "${pathspec[@]}" 2>&1 | head -400)
    [[ -z "$out" ]] && { printf 'no differences'; return 0; }
    printf '%s' "$out"
}

tool_git_show() {
    _git_repo_check || return $?
    local ref; ref=$(tool_arg ref HEAD)
    [[ "$ref" == -* ]] && { printf 'invalid ref (must not start with -)'; return 1; }
    _git_p show --stat --patch "$ref" 2>&1 | head -400
}

tool_git_file_history() {
    _git_repo_check || return $?
    local file count
    file=$(tool_arg file "$1"); count=$(int_guard "$(tool_arg count 20)" 20)
    [[ -z "$file" ]] && { printf 'file required'; return 1; }
    _git_p log --follow -n "$count" --date=short --pretty='format:%h %ad %an  %s' -- "$file" 2>&1
}

# Pickaxe: which commits added/removed a string (who introduced this?).
tool_git_search_history() {
    _git_repo_check || return $?
    local pattern count
    pattern=$(tool_arg pattern "$1"); count=$(int_guard "$(tool_arg count 20)" 20)
    [[ -z "$pattern" ]] && { printf 'pattern required'; return 1; }
    # -S"$pattern" attached: a pattern starting with '-' can't become an option.
    _git_p log -n "$count" --date=short --pretty='format:%h %ad %an  %s' -S"$pattern" 2>&1
}

tool_git_remotes() {
    _git_repo_check || return $?
    _git_p remote -v 2>&1
    local upstream counts
    upstream=$(_git_p rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null) || return 0
    counts=$(_git_p rev-list --left-right --count "HEAD...$upstream" 2>/dev/null) || return 0
    printf '\nahead %s / behind %s of %s\n' "${counts%%[[:space:]]*}" "${counts##*[[:space:]]}" "$upstream"
}

tool_register "git_log"          tool_git_log          '{"type":"object","properties":{"count":{"type":"integer","description":"maximum number of results to return"},"path":{"type":"string","description":"file or directory path relative to the project root"},"author":{"type":"string","description":"filter by commit author"},"grep":{"type":"string","description":"filter by matching commit message text"}}}' safe all git
tool_register "git_diff"         tool_git_diff         '{"type":"object","properties":{"ref":{"type":"string","description":"a git ref (branch, tag, or commit)"},"path":{"type":"string","description":"file or directory path relative to the project root"},"staged":{"type":"boolean","description":"the staged"}}}' safe all git
tool_register "git_show"         tool_git_show         '{"type":"object","properties":{"ref":{"type":"string","description":"a git ref (branch, tag, or commit)"}}}' safe all git
tool_register "git_file_history" tool_git_file_history '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"count":{"type":"integer","description":"maximum number of results to return"}},"required":["file"]}' safe all git
tool_register "git_search_history"       tool_git_search_history       '{"type":"object","properties":{"pattern":{"type":"string","description":"the search pattern (text or regex)"},"count":{"type":"integer","description":"maximum number of results to return"}},"required":["pattern"]}' safe all git
tool_register "git_remotes"      tool_git_remotes      '{"type":"object","properties":{}}' safe all git
