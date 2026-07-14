# lib/09-io.sh — I/O wrappers (cat, head, tail, grep, wc, etc.)
# Streaming, no-slurp discipline. Avoids $(cat file) memory waste.

# io_cat FILE -> prints entire file (streaming)
io_cat() {
    [[ -f "$1" ]] || { printf 'file not found: %s\n' "$1" >&2; return 1; }
    cat "$1"
}

# io_head N FILE -> first N lines (streaming)
io_head() {
    local n="${1:-10}" file="$2"
    [[ -f "$file" ]] || return 1
    head -n "$n" "$file"
}

# io_tail N FILE -> last N lines
io_tail() {
    local n="${1:-10}" file="$2"
    [[ -f "$file" ]] || return 1
    tail -n "$n" "$file"
}

# io_tail_follow FILE -> follow file (like tail -f)
io_tail_follow() {
    [[ -f "$1" ]] || return 1
    tail -f "$1"
}

# io_read_lines FILE -> prints all lines (for piping to mapfile)
io_read_lines() {
    [[ -f "$1" ]] || return 1
    # Use plain cat — caller pipes to mapfile or while read
    cat "$1"
}

# io_read_lines_into ARRAY_NAME FILE
io_read_lines_into() {
    local -n _io_lines_ref="$1"
    local file="$2"
    [[ -f "$file" ]] || return 1
    mapfile -t _io_lines_ref < "$file"
}

# io_write FILE CONTENT -> writes content (no trailing newline added)
io_write() {
    local file="$1" content="$2"
    path_ensure_dir "$(dirname "$file")"
    printf '%s' "$content" > "$file"
}

# io_write_lines FILE LINE... -> writes lines (each with \n)
io_write_lines() {
    local file="$1"; shift
    path_ensure_dir "$(dirname "$file")"
    local line
    for line in "$@"; do printf '%s\n' "$line"; done > "$file"
}

# io_append FILE CONTENT -> appends content
io_append() {
    local file="$1" content="$2"
    path_ensure_dir "$(dirname "$file")"
    printf '%s' "$content" >> "$file"
}

# io_append_line FILE LINE -> appends a line with \n
io_append_line() {
    printf '%s\n' "$2" >> "$1"
}

# io_grep PATTERN FILE [OPTIONS] -> search file
io_grep() {
    local pattern="$1" file="$2" opts="${3:-}"
    [[ -f "$file" ]] || return 1
    if command -v rg &>/dev/null; then
        rg -n $opts "$pattern" "$file" 2>/dev/null
    else
        grep -n $opts "$pattern" "$file" 2>/dev/null
    fi
}

# io_grep_recursive PATTERN DIR [OPTIONS] -> search directory
# OPTIONS: include_ignored=true to include .git/node_modules/target/dist/build/__pycache__/.venv
io_grep_recursive() {
    local pattern="$1" dir="$2" opts="${3:-}"
    local include_ignored="false"
    [[ "$opts" == *"include_ignored=true"* ]] && include_ignored="true"

    if command -v rg &>/dev/null; then
        if [[ "$include_ignored" == "true" ]]; then
            rg -n --no-ignore "$pattern" "$dir" 2>/dev/null
        else
            rg -n "$pattern" "$dir" 2>/dev/null
        fi
    else
        # grep fallback: exclude common ignored directories
        if [[ "$include_ignored" == "true" ]]; then
            grep -rn "$pattern" "$dir" 2>/dev/null
        else
            grep -rn --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=target \
                --exclude-dir=dist --exclude-dir=build --exclude-dir=__pycache__ \
                --exclude-dir=.venv "$pattern" "$dir" 2>/dev/null
        fi
    fi
}

# io_wc_lines FILE -> line count (integer)
io_wc_lines() {
    [[ -f "$1" ]] || { printf '0'; return; }
    wc -l < "$1" | tr -d ' '
}

# io_wc_words FILE
io_wc_words() {
    [[ -f "$1" ]] || { printf '0'; return; }
    wc -w < "$1" | tr -d ' '
}

# io_wc_bytes FILE
io_wc_bytes() {
    [[ -f "$1" ]] || { printf '0'; return; }
    wc -c < "$1" | tr -d ' '
}

# io_is_binary FILE -> 0 if file contains binary data
io_is_binary() {
    [[ -f "$1" ]] || return 1
    # grep -qI returns 0 for text files, 1 for binary
    grep -qI '.' "$1" 2>/dev/null
    local rc=$?
    # rc=0 means text, rc=1 means binary, rc=2 means error
    [[ $rc -ne 0 ]]
}

# io_read_stdin -> reads all of stdin into REPLY (no subshell)
io_read_stdin() {
    REPLY=""
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$REPLY" ]] && REPLY+=$'\n'
        REPLY+="$line"
    done
}

# io_read_stdin_lines ARRAY_NAME -> reads stdin lines into named array
io_read_stdin_lines() {
    local -n _io_stdin_ref="$1"
    mapfile -t _io_stdin_ref
}

# io_print_lines ARRAY_NAME -> prints each element on its own line
io_print_lines() {
    local -n _io_print_ref="$1"
    local item
    for item in "${_io_print_ref[@]}"; do printf '%s\n' "$item"; done
}

# io_copy SRC DST -> copy file
io_copy() {
    cp -- "$1" "$2"
}

# io_move SRC DST
io_move() {
    mv -- "$1" "$2"
}

# io_delete FILE
io_delete() {
    rm -f -- "$1"
}

# io_symlink TARGET LINKNAME
io_symlink() {
    ln -sf -- "$1" "$2"
}

# io_diff FILE1 FILE2 -> unified diff
io_diff() {
    if command -v delta &>/dev/null; then
        diff -u "$1" "$2" 2>/dev/null | delta 2>/dev/null || diff -u "$1" "$2"
    else
        diff -u "$1" "$2" 2>/dev/null
    fi
}

# cmd_wrote OUT MSG CMD [ARG...] — run CMD as argv (no shell) and report HONESTLY.
# On success (CMD exited 0 AND OUT is a non-empty file) it prints MSG; otherwise
# it prints the exit code + the tail of CMD's combined output and returns 1.
# This is the single honest replacement for the `cmd 2>&1 | tail -N && printf
# 'wrote…'` idiom that pervaded the media/doc tools: a pipeline's exit status is
# its LAST stage (tail, always 0), so `&& printf` ran even when ffmpeg/pandoc/gs
# had failed — the tool declared success and named an output file that was never
# written (or was a broken 0-byte stub). Callers pass the fully-built success
# message so a tool with two substitutions doesn't need a printf format here.
cmd_wrote() {
    local out="$1" msg="$2"; shift 2
    local log rc
    log=$("$@" 2>&1); rc=$?
    if [[ $rc -eq 0 && -s "$out" ]]; then
        printf '%s' "$msg"
    else
        printf '%s failed (exit %s):\n%s' "${1:-command}" "$rc" "$(printf '%s' "$log" | tail -8)"
        return 1
    fi
}
