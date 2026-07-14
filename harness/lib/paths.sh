# lib/06-paths.sh — Path resolution and safety utilities

# path_resolve PATH -> canonical absolute path (realpath with fallback)
path_resolve() {
    local p="$1"
    if [[ -e "$p" ]]; then
        realpath "$p" 2>/dev/null || printf '%s' "$p"
    else
        # Resolve parent + append basename
        local dir base rdir
        dir=$(dirname "$p")
        base=$(basename "$p")
        rdir=$(realpath "$dir" 2>/dev/null || printf '%s' "$dir")
        printf '%s/%s' "$rdir" "$base"
    fi
}

# path_is_absolute PATH
path_is_absolute() {
    [[ "$1" == /* ]]
}

# path_is_relative PATH
path_is_relative() {
    [[ "$1" != /* ]]
}

# path_join A B -> joined path (handles trailing slashes)
path_join() {
    local a="$1" b="$2"
    if [[ -z "$a" ]]; then printf '%s' "$b"; return; fi
    if [[ -z "$b" ]]; then printf '%s' "$a"; return; fi
    if str_ends_with "$a" "/"; then
        printf '%s%s' "$a" "$b"
    else
        printf '%s/%s' "$a" "$b"
    fi
}

# path_ext PATH -> file extension (without dot), lowercase
path_ext() {
    local base="${1##*/}"
    local ext="${base##*.}"
    [[ "$ext" == "$base" ]] && { printf ''; return; }
    str_lower "$ext"
}

# path_basename PATH -> last component
path_basename() {
    printf '%s' "${1##*/}"
}

# path_dirname PATH -> parent directory
path_dirname() {
    printf '%s' "${1%/*}"
}

# path_normalize PATH -> collapse ., .., //
path_normalize() {
    local p="$1" out=""
    # Replace // with /
    p="${p//\/\///}"
    # Handle ./
    p="${p//\/\.\//\/}"
    [[ "$p" == "./" ]] && p="/"
    p="${p/#.\//}"
    # Resolve .. segments
    local IFS='/'
    local -a parts
    read -ra parts <<< "$p"
    local part
    for part in "${parts[@]}"; do
        [[ "$part" == "" || "$part" == "." ]] && continue
        if [[ "$part" == ".." ]]; then
            [[ -n "$out" ]] && out="${out%/*}"
        else
            [[ -n "$out" ]] && out="$out/$part" || out="$part"
        fi
    done
    [[ "$p" == /* ]] && out="/$out"
    [[ -z "$out" ]] && out="."
    printf '%s' "$out"
}

# path_is_inside PATH DIR -> 0 if PATH is inside DIR (trailing-slash safe)
path_is_inside() {
    local target dir
    target=$(path_resolve "$1")
    dir=$(path_resolve "$2")
    [[ "$target" == "$dir" ]] && return 0
    [[ "$target" == "$dir"/* ]] && return 0
    return 1
}

# path_check_allowed PATH -> 0 if within any allowed path
# Uses YCA_SAFETY_PATHS (colon-separated)
path_check_allowed() {
    local path="$1"
    # Fail SAFE, not open. The old `-z && return 0` meant an empty allowlist let
    # every guard (read/write/edit/bash/fs_*/kg_*) reach the ENTIRE host. In a real
    # run main() seeds YCA_SAFETY_PATHS to the project dir before any tool runs, but
    # a cleared or subshelled var would silently unconfine. Self-heal to the project
    # fence when we know it; only preserve the legacy allow-all when the harness is
    # genuinely uninitialized (e.g. a unit test that sets neither var).
    if [[ -z "$YCA_SAFETY_PATHS" ]]; then
        [[ -n "${YCA_PROJECT_DIR:-}" ]] || return 0
        YCA_SAFETY_PATHS="$YCA_PROJECT_DIR"
    fi
    local resolved allowed
    resolved=$(path_resolve "$path")
    local IFS=':'
    for allowed in $YCA_SAFETY_PATHS; do
        if path_is_inside "$resolved" "$allowed"; then return 0; fi
    done
    return 1
}

# path_relative FROM TO -> relative path from FROM to TO
path_relative() {
    local from to
    from=$(path_resolve "$1")
    to=$(path_resolve "$2")
    local common="$from" result=""
    while [[ "$to" != "$common"* ]]; do
        common=$(dirname "$common")
        result="../$result"
    done
    local sub="${to#$common}"
    sub="${sub#/}"
    [[ -n "$sub" ]] && result="${result}$sub"
    [[ -z "$result" ]] && result="."
    printf '%s' "$result"
}

# path_ensure_dir PATH -> creates directory if not exists
path_ensure_dir() {
    [[ -d "$1" ]] || mkdir -p "$1"
}

# path_temp_dir [PREFIX] -> creates and prints temp dir path
path_temp_dir() {
    local prefix="${1:-yca}"
    mktemp -d -t "$prefix.XXXXXX" 2>/dev/null || mktemp -d
}

# path_temp_file [PREFIX] [SUFFIX] -> creates and prints temp file path
path_temp_file() {
    local prefix="${1:-yca}" suffix="${2:-}"
    if [[ -n "$suffix" ]]; then
        mktemp -t "$prefix.XXXXXX$suffix" 2>/dev/null || mktemp
    else
        mktemp -t "$prefix.XXXXXX" 2>/dev/null || mktemp
    fi
}

# path_size FILE -> size in bytes
path_size() {
    if [[ -f "$1" ]]; then
        wc -c < "$1" 2>/dev/null | tr -d ' ' || printf '0'
    else
        printf '0'
    fi
}

# path_exists PATH -> 0 if file/dir exists
path_exists() {
    [[ -e "$1" ]]
}

# path_is_file PATH
path_is_file() { [[ -f "$1" ]]; }

# path_is_dir PATH
path_is_dir() { [[ -d "$1" ]]; }

# path_is_symlink PATH
path_is_symlink() { [[ -L "$1" ]]; }

# path_is_executable PATH
path_is_exec() { [[ -x "$1" ]]; }

# path_mtime FILE -> modification time (epoch seconds)
path_mtime() {
    stat -f %m "$1" 2>/dev/null || stat -c %Y "$1" 2>/dev/null || printf '0'
}
