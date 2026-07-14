# lib/10-files.sh — File discovery and bulk file operations

# files_find DIR [PATTERN] [MAX_DEPTH] -> prints matching file paths
files_find() {
    local dir="$1" pattern="${2:-}" depth="${3:-}"
    if command -v fd &>/dev/null; then
        fd ${pattern:+-g "$pattern"} ${depth:+--max-depth "$depth"} --type f . "$dir" 2>/dev/null
    elif command -v find &>/dev/null; then
        local args=(-type f)
        [[ -n "$depth" ]] && args+=(-maxdepth "$depth")
        [[ -n "$pattern" ]] && args+=(-name "$pattern")
        find "$dir" "${args[@]}" 2>/dev/null
    fi
}

# files_find_recent DIR DAYS -> files modified in last N days
files_find_recent() {
    local dir="$1" days="${2:-7}"
    find "$dir" -type f -mtime -"$days" 2>/dev/null
}

# files_list DIR [GLOB] -> list files (not dirs) in directory
files_list() {
    local dir="$1" glob="${2:-*}"
    local f
    for f in "$dir"/$glob; do
        [[ -f "$f" ]] && printf '%s\n' "$f"
    done
}

# files_list_dirs DIR -> list subdirectories
files_list_dirs() {
    local dir="$1" d
    for d in "$dir"/*/; do
        [[ -d "$d" ]] && printf '%s\n' "${d%/}"
    done
}

# files_copy_tree SRC DST -> recursive copy
files_copy_tree() {
    local src="$1" dst="$2"
    path_ensure_dir "$dst"
    cp -R "$src"/. "$dst"/ 2>/dev/null || cp -R "$src" "$dst"
}

# files_sync SRC DST -> rsync dry-run (safe preview)
files_sync_preview() {
    rsync -avz --dry-run "$1/" "$2/" 2>/dev/null
}

# files_sync SRC DST -> actual rsync
files_sync() {
    rsync -avz "$1/" "$2/" 2>/dev/null
}

# files_delete_dir DIR -> rm -rf with safety check
files_delete_dir() {
    local dir="$1"
    # Safety: never delete root or home
    [[ "$dir" == "/" || "$dir" == "$HOME" || -z "$dir" ]] && return 1
    path_check_allowed "$dir" || return 1
    rm -rf "$dir"
}

# files_clean_dir DIR -> remove contents but keep dir
files_clean_dir() {
    local dir="$1"
    path_check_allowed "$dir" || return 1
    rm -rf "${dir:?}/"*
}

# files_find_dupes DIR -> find duplicate files (by size+hash)
files_find_dupes() {
    local dir="$1"
    if command -v fdupes &>/dev/null; then
        fdupes -r "$dir" 2>/dev/null
    else
        # Pure bash: group by size, then by first 4KB hash
        declare -A size_map
        local f sz
        while IFS= read -r f; do
            [[ -f "$f" ]] || continue
            sz=$(path_size "$f")
            size_map[$sz]+="$f;"
        done < <(find "$dir" -type f 2>/dev/null)
        local s files first_hash
        for s in "${!size_map[@]}"; do
            files="${size_map[$s]}"
            # Only check groups with >1 file
            local count
            count=$(printf '%s' "$files" | tr ';' '\n' | grep -c .)
            (( count > 1 )) || continue
            declare -A hash_map=()
            local ff
            for ff in $(printf '%s' "$files" | tr ';' '\n'); do
                [[ -z "$ff" ]] && continue
                local h
                h=$(head -c 4096 "$ff" 2>/dev/null | shasum -a 256 | cut -d' ' -f1)
                hash_map[$h]+="$ff;"
            done
            local hh group
            for hh in "${!hash_map[@]}"; do
                group="${hash_map[$hh]}"
                local gc
                gc=$(printf '%s' "$group" | tr ';' '\n' | grep -c .)
                (( gc > 1 )) && {
                    printf 'Duplicates (hash %s):\n' "${hh:0:12}"
                    printf '%s\n' "$group" | tr ';' '\n' | grep -v '^$'
                    printf '\n'
                }
            done
            unset hash_map
            declare -A hash_map=()
        done
    fi
}

# files_disk_usage DIR -> sorted disk usage (top 15)
files_disk_usage() {
    local dir="${1:-.}"
    if command -v ncdu &>/dev/null; then
        ncdu -rx --color dark "$dir" 2>/dev/null
    else
        du -sh "$dir"/* 2>/dev/null | sort -rh | head -15
    fi
}

# files_watch DIR CMD -> run CMD when files in DIR change
files_watch() {
    local dir="$1" cmd="$2"
    if command -v fswatch &>/dev/null; then
        fswatch -1 "$dir" | while read -r _; do eval "$cmd"; done
    elif command -v entr &>/dev/null; then
        find "$dir" -type f | entr -r sh -c "$cmd"
    else
        printf 'install fswatch or entr\n' >&2
        return 1
    fi
}

# files_touch FILE -> create empty file or update mtime
files_touch() {
    path_ensure_dir "$(dirname "$1")"
    touch "$1"
}

# files_chmod_recursive DIR MODE
files_chmod_recursive() {
    chmod -R "$2" "$1" 2>/dev/null
}

# files_count DIR [PATTERN] -> count of files
files_count() {
    local dir="$1" pattern="${2:-}"
    if [[ -n "$pattern" ]]; then
        find "$dir" -type f -name "$pattern" 2>/dev/null | wc -l | tr -d ' '
    else
        find "$dir" -type f 2>/dev/null | wc -l | tr -d ' '
    fi
}
