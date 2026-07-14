# tools/quality.sh — Code quality tools (coverage, lint, duplication, complexity, dead-code)

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
_q_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_q_path()    { local p="${1:-$YCA_PROJECT_DIR}"; path_check_allowed "$p" 2>/dev/null || return 1; printf '%s' "$p"; }

# ---------------------------------------------------------------------------
# complexity — radon (Python) / lizard (multi-language)
# ---------------------------------------------------------------------------
tool_quality_complexity() {
    local p; p=$(_q_path "$1") || return 1
    if command -v lizard &>/dev/null; then
        lizard -l 15 -w "$p" 2>/dev/null
    elif command -v radon &>/dev/null; then
        radon cc "$p" -a -nb
    else
        _q_missing "radon or lizard" "pip install radon  /  brew install lizard"
    fi
}

# ---------------------------------------------------------------------------
# deadcode — vulture (Python) / knip (JS/TS)
# ---------------------------------------------------------------------------
tool_quality_deadcode() {
    local p; p=$(_q_path "$1") || return 1
    if command -v knip &>/dev/null; then
        knip --no-config --include-entry-files 2>/dev/null && return 0
        # re-run with project dir if knip understood it
    fi
    if command -v vulture &>/dev/null; then
        vulture "$p"
    else
        _q_missing "vulture or knip" "pip install vulture  /  npm i -g knip"
    fi
}

# ---------------------------------------------------------------------------
# dup — duplicate code detection (jscpd / cpd)
# ---------------------------------------------------------------------------
tool_quality_dup() {
    local p; p=$(_q_path "$1") || return 1
    if command -v jscpd &>/dev/null; then
        jscpd --min-lines 5 --min-tokens 50 --gitignore --path "$p" 2>/dev/null
    elif command -v cpd &>/dev/null; then
        cpd --minimum-tokens 50 --files "$p" 2>/dev/null
    else
        _q_missing "jscpd or cpd" "npm i -g jscpd  /  brew install pmd && ln -s /opt/homebrew/bin/cpd ..."
    fi
}

# ---------------------------------------------------------------------------
# shellcheck — bash/sh lint
# ---------------------------------------------------------------------------
tool_quality_shellcheck() {
    local p; p=$(_q_path "$1") || return 1
    if ! command -v shellcheck &>/dev/null; then
        _q_missing shellcheck "brew install shellcheck  /  apt install shellcheck"
        return 1
    fi
    local count=0
    while IFS= read -r -d '' f; do
        shellcheck -S error "$f"
        ((count++))
    done < <(find "$p" -name '*.sh' -type f -print0 2>/dev/null)
    printf 'shellcheck: %d files checked\n' "$count"
}

# ---------------------------------------------------------------------------
# dockerfile — hadolint
# ---------------------------------------------------------------------------
tool_quality_dockerfile() {
    local p; p=$(_q_path "$1") || return 1
    if ! command -v hadolint &>/dev/null; then
        _q_missing hadolint "brew install hadolint  /  docker pull hadolint/hadolint"
        return 1
    fi
    local count=0
    while IFS= read -r -d '' f; do
        hadolint "$f"
        ((count++))
    done < <(find "$p" -name 'Dockerfile*' -type f -print0 2>/dev/null)
    printf 'hadolint: %d files checked\n' "$count"
}

# ---------------------------------------------------------------------------
# markdown_lint
# ---------------------------------------------------------------------------
tool_quality_markdown_lint() {
    local p; p=$(_q_path "$1") || return 1
    if command -v mdl &>/dev/null; then
        mdl "$p" 2>/dev/null
    elif command -v markdownlint &>/dev/null; then
        markdownlint "$p" 2>/dev/null
    else
        _q_missing "mdl or markdownlint" "gem install mdl  /  npm i -g markdownlint-cli"
    fi
}

# ---------------------------------------------------------------------------
# yaml_lint
# ---------------------------------------------------------------------------
tool_quality_yaml_lint() {
    local p; p=$(_q_path "$1") || return 1
    if ! command -v yamllint &>/dev/null; then
        _q_missing yamllint "pip install yamllint"
        return 1
    fi
    local count=0
    while IFS= read -r -d '' f; do
        yamllint "$f"
        ((count++))
    done < <(find "$p" \( -name '*.yml' -o -name '*.yaml' \) -type f -print0 2>/dev/null)
    printf 'yamllint: %d files checked\n' "$count"
}

# ---------------------------------------------------------------------------
# json_lint — validate *.json via jq (ubiquitous CLI; no python runtime dep)
# ---------------------------------------------------------------------------
tool_quality_json_lint() {
    local p; p=$(_q_path "$1") || return 1
    command -v jq &>/dev/null || { _q_missing jq "brew install jq"; return 1; }
    local errors=0 count=0 f
    while IFS= read -r -d '' f; do
        ((count++))
        jq . "$f" >/dev/null 2>&1 || { printf 'invalid: %s\n' "$f"; ((errors++)); }
    done < <(find "$p" -name '*.json' -type f -print0 2>/dev/null)
    printf 'json-lint: %d files, %d errors\n' "$count" "$errors"
}

# ---------------------------------------------------------------------------
# count_loc — cloc / tokei / wc -l fallback
# ---------------------------------------------------------------------------
tool_quality_count_loc() {
    local p; p=$(_q_path "$1") || return 1
    if command -v cloc &>/dev/null; then
        cloc "$p" 2>/dev/null
    elif command -v tokei &>/dev/null; then
        tokei "$p" 2>/dev/null
    else
        find "$p" -type f -not -path '*/.git/*' -exec wc -l {} + 2>/dev/null | tail -1
    fi
}

# ---------------------------------------------------------------------------
# git_blame_todo — find TODOs and show who/when last touched each line
# ---------------------------------------------------------------------------
tool_quality_git_blame_todo() {
    local p; p=$(_q_path "$1") || return 1
    local git_dir="${p}/.git"
    [[ -d "$git_dir" ]] || { printf 'not a git repository'; return 1; }
    command -v git &>/dev/null || { _q_missing git "install git"; return 1; }
    local pattern='TODO|FIXME|HACK|XXX|BUG'
    local tmpf; tmpf=$(mktemp)
    # Collect matching files and lines, then blame each
    if command -v rg &>/dev/null; then
        rg -n "$pattern" "$p" --type-add 'all:*' -t all 2>/dev/null >"$tmpf"
    else
        grep -rn "$pattern" "$p" --include='*' --exclude-dir=.git 2>/dev/null >"$tmpf"
    fi
    [[ ! -s "$tmpf" ]] && { printf 'no TODOs found'; rm -f "$tmpf"; return 0; }
    printf '%-8s %-20s %s\n' 'LINE' 'AUTHOR' 'FILE'
    printf '%-8s %-20s %s\n' '----' '------' '----'
    local file line
    while IFS=: read -r file line _; do
        local blame
        blame=$(git -C "$p" blame -L "${line},${line}" --porcelain "$file" 2>/dev/null | head -1)
        local author="${blame%% *}"
        printf '%-8s %-20s %s\n' "$line" "${author:-?}" "${file#"$p"/}"
    done <"$tmpf"
    rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# todo_census — TODO/FIXME counts by tag and by file (fast triage view)
# ---------------------------------------------------------------------------
tool_quality_todo_census() {
    local p; p=$(_q_path "$1") || return 1
    local tmpf; tmpf=$(mktemp)
    if command -v rg &>/dev/null; then
        rg -no --no-heading '(TODO|FIXME|HACK|XXX|BUG|OPTIMIZE)' "$p" 2>/dev/null >"$tmpf"
    else
        grep -rnoE '(TODO|FIXME|HACK|XXX|BUG|OPTIMIZE)' "$p" --exclude-dir=.git 2>/dev/null >"$tmpf"
    fi
    [[ -s "$tmpf" ]] || { printf 'no TODO/FIXME markers found'; rm -f "$tmpf"; return 0; }
    printf '=== by tag ===\n'
    awk -F: '{print $NF}' "$tmpf" | sort | uniq -c | sort -rn
    printf '\n=== top files ===\n'
    awk -F: '{print $1}' "$tmpf" | sort | uniq -c | sort -rn | head -15
    rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# long_functions — heuristic finder for functions over N lines (default 60).
# Brace languages: fn start line ... first "}" at column 0. Python: def→def.
# ---------------------------------------------------------------------------
tool_quality_long_functions() {
    local p; p=$(_q_path "$1") || return 1
    local max; max=$(int_guard "$(tool_arg lines 60)" 60)
    local f tmpf; tmpf=$(mktemp)
    while IFS= read -r -d '' f; do
        if [[ "$f" == *.py ]]; then
            awk -v file="$f" -v max="$max" '
                /^[[:space:]]*(async[[:space:]]+)?def[[:space:]]/ {
                    if (infn && NR-start > max) printf "%s:%d  ~%d lines  %.60s\n", file, start, NR-start, name
                    infn=1; start=NR; name=$0
                }
                END { if (infn && NR-start+1 > max) printf "%s:%d  ~%d lines  %.60s\n", file, start, NR-start+1, name }
            ' "$f" >>"$tmpf"
        else
            awk -v file="$f" -v max="$max" '
                !infn && (/^[[:alnum:]_].*\(.*\).*\{[[:space:]]*$/ || /^(function|func|fn|sub)[[:space:]]/) { infn=1; start=NR; name=$0; next }
                infn && /^\}/ { if (NR-start+1 > max) printf "%s:%d  %d lines  %.60s\n", file, start, NR-start+1, name; infn=0 }
            ' "$f" >>"$tmpf"
        fi
    done < <(find "$p" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.go' -o -name '*.java' -o -name '*.rs' -o -name '*.c' -o -name '*.cpp' -o -name '*.rb' -o -name '*.php' -o -name '*.kt' \) ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.venv/*' -print0 2>/dev/null)
    if [[ -s "$tmpf" ]]; then sort -t: -k1,1 "$tmpf"; else printf 'no functions over %d lines (heuristic)' "$max"; fi
    rm -f "$tmpf"
}

# ---------------------------------------------------------------------------
# churn — most-changed files + busiest authors (git history)
# ---------------------------------------------------------------------------
tool_quality_churn() {
    local p; p=$(_q_path "$1") || return 1
    [[ -d "$p/.git" ]] || { printf 'not a git repository'; return 1; }
    local days; days=$(int_guard "$(tool_arg days 90)" 90)
    printf '=== most-changed files (last %s days) ===\n' "$days"
    git -C "$p" log --since="${days} days ago" --name-only --pretty=format: 2>/dev/null \
        | awk 'NF' | sort | uniq -c | sort -rn | head -20
    printf '\n=== commits per author ===\n'
    # HEAD makes the revision range explicit — without it `git shortlog` reads
    # the commit list from stdin (drains the caller's stdin when not a TTY).
    git -C "$p" shortlog -sn --since="${days} days ago" HEAD 2>/dev/null | head -10
}

# ---------------------------------------------------------------------------
# hotspots — churn x size: big files that also change often = refactor first
# ---------------------------------------------------------------------------
tool_quality_hotspots() {
    local p; p=$(_q_path "$1") || return 1
    [[ -d "$p/.git" ]] || { printf 'not a git repository'; return 1; }
    local days; days=$(int_guard "$(tool_arg days 180)" 180)
    printf 'score = commits x LOC (last %s days) — highest first\n' "$days"
    local count file loc
    while read -r count file; do
        [[ -f "$p/$file" ]] || continue
        loc=$(wc -l < "$p/$file" 2>/dev/null | tr -d ' ')
        printf '%10d  %4d commits  %6d loc  %s\n' $((count * loc)) "$count" "$loc" "$file"
    done < <(git -C "$p" log --since="${days} days ago" --name-only --pretty=format: 2>/dev/null | awk 'NF' | sort | uniq -c | sort -rn | head -30) \
        | sort -rn | head -15
}

# ---------------------------------------------------------------------------
# large_files — top source files by LOC (split candidates)
# ---------------------------------------------------------------------------
tool_quality_large_files() {
    local p; p=$(_q_path "$1") || return 1
    find "$p" -type f \( -name '*.sh' -o -name '*.py' -o -name '*.js' -o -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' -o -name '*.go' -o -name '*.java' -o -name '*.rs' -o -name '*.c' -o -name '*.cpp' -o -name '*.rb' -o -name '*.php' -o -name '*.kt' \) ! -path '*/.git/*' ! -path '*/node_modules/*' ! -path '*/.venv/*' -print0 2>/dev/null \
        | xargs -0 wc -l 2>/dev/null | awk '$2 != "total"' | sort -rn | head -20
}

# ---------------------------------------------------------------------------
# doctor — report status of all quality tools
# ---------------------------------------------------------------------------
tool_quality_doctor() {
    local p="${1:-$YCA_PROJECT_DIR}"
    printf '=== quality tool doctor ===\n'
    printf 'project dir: %s\n\n' "$p"

    local tools=(
        "radon:radon (py complexity)"
        "lizard:lizard (multi-lang complexity)"
        "vulture:vulture (py deadcode)"
        "knip:knip (js/ts deadcode)"
        "jscpd:jscpd (dup detection)"
        "cpd:cpd (pmd dup detection)"
        "shellcheck:shellcheck (bash lint)"
        "hadolint:hadolint (dockerfile lint)"
        "mdl:mdl (md lint)"
        "markdownlint:markdownlint-cli (md lint)"
        "yamllint:yamllint (yaml lint)"
        "jq:jq (json lint)"
        "cloc:cloc (loc counting)"
        "tokei:tokei (loc counting)"
    )
    local maxw=0 entry bin label
    for entry in "${tools[@]}"; do
        label="${entry#*:}"
        [[ ${#label} -gt $maxw ]] && maxw=${#label}
    done
    for entry in "${tools[@]}"; do
        bin="${entry%%:*}"
        label="${entry#*:}"
        if command -v "$bin" &>/dev/null; then
            printf '  [✓] %-*s  %s\n' "$maxw" "$label" "$(command -v "$bin")"
        else
            printf '  [ ] %-*s  (not installed)\n' "$maxw" "$label"
        fi
    done

    printf '\n--- integrated quality tools ---\n'
    printf '  fs_find_todos  —  available in the fs category (tl:fs todos)\n'
    printf '\n--- lint targets found ---\n'
    local totals=0
    while IFS= read -r -d '' f; do ((totals++)); done < <(find "$p" -not -path '*/.git/*' -type f -print0 2>/dev/null)
    printf '  total files: %d\n' "$totals"
    printf '  *.sh:        %d\n' "$(find "$p" -name '*.sh' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  *.py:        %d\n' "$(find "$p" -name '*.py' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  *.js/ts/jsx: %d\n' "$(find "$p" \( -name '*.js' -o -name '*.ts' -o -name '*.tsx' -o -name '*.jsx' \) -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  *.json:      %d\n' "$(find "$p" -name '*.json' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  *.yml/yaml:  %d\n' "$(find "$p" \( -name '*.yml' -o -name '*.yaml' \) -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  Dockerfile*: %d\n' "$(find "$p" -name 'Dockerfile*' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
    printf '  *.md:        %d\n' "$(find "$p" -name '*.md' -not -path '*/.git/*' -type f 2>/dev/null | wc -l | tr -d ' ')"
}

# ---------------------------------------------------------------------------
# registrations
# ---------------------------------------------------------------------------
tool_register "quality_complexity"     tool_quality_complexity     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_deadcode"       tool_quality_deadcode       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_dup"            tool_quality_dup            '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_shellcheck"     tool_quality_shellcheck     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_dockerfile"     tool_quality_dockerfile     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_markdown_lint"  tool_quality_markdown_lint  '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_yaml_lint"      tool_quality_yaml_lint      '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_json_lint"      tool_quality_json_lint      '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_count_loc"      tool_quality_count_loc      '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_git_blame_todo" tool_quality_git_blame_todo '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_doctor"         tool_quality_doctor         '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_todo_census"    tool_quality_todo_census    '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
tool_register "quality_long_functions" tool_quality_long_functions '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"lines":{"type":"integer","description":"number of lines to return"}}}' safe all quality
tool_register "quality_churn"          tool_quality_churn          '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"days":{"type":"integer","description":"number of days"}}}' safe all quality
tool_register "quality_hotspots"       tool_quality_hotspots       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"days":{"type":"integer","description":"number of days"}}}' safe all quality
tool_register "quality_large_files"    tool_quality_large_files    '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all quality
