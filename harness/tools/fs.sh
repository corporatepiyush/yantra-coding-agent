# tools/fs.sh — Filesystem & search tools (category: fs).
# Merges the old `search` (grep/replace/todos) and `files` (dups/disk/sync/find)
# opt-ins into one coherent category, and adds tree/dirsize/archive/crypto tools.
# {pattern, path} collide in the generic dispatcher, so tools read exact fields
# via tool_arg. Write/crypto tools honor path_check_allowed.

# ── Search ───────────────────────────────────────────────────────────────────
tool_fs_search() {
    local pattern path
    pattern=$(tool_arg pattern "$1")
    path=$(tool_arg path "$YCA_PROJECT_DIR")
    [[ -z "$pattern" ]] && { printf 'pattern required'; return 1; }
    path_check_allowed "$path" || return 1
    io_grep_recursive "$pattern" "$path"
}
tool_fs_replace() {
    local path pattern replacement
    path=$(tool_arg path "$YCA_PROJECT_DIR")
    pattern=$(tool_arg pattern)
    replacement=$(tool_arg replacement)
    [[ -z "$pattern" ]] && { printf 'pattern required'; return 1; }
    path_check_allowed "$path" || return 1
    local files
    if command -v rg &>/dev/null; then files=$(rg -l "$pattern" "$path" 2>/dev/null)
    else files=$(grep -rl "$pattern" "$path" 2>/dev/null); fi
    [[ -z "$files" ]] && { printf 'no matches'; return 0; }
    confirm_action "Replace '$pattern' -> '$replacement' in $path" "files: $files" || { confirm_denied_msg; return 1; }
    if command -v sd &>/dev/null; then
        printf '%s\n' "$files" | xargs -P "$(math_core_count)" sd "$pattern" "$replacement"
    else
        local esc_old esc_new sed_cmd
        esc_old=$(str_escape_sed "$pattern"); esc_new=$(str_escape_sed "$replacement"); sed_cmd=$(config_detect_sed)
        case "$sed_cmd" in
            "sed -i")   printf '%s\n' "$files" | xargs sed -i "s/${esc_old}/${esc_new}/g" ;;
            "sed -i ''") printf '%s\n' "$files" | xargs sed -i '' "s/${esc_old}/${esc_new}/g" ;;
        esac
    fi
    printf 'replaced in %d files' "$(printf '%s\n' "$files" | wc -l | tr -d ' ')"
}
tool_fs_find_todos() {
    local path; path=$(tool_arg path "$YCA_PROJECT_DIR")
    path_check_allowed "$path" || return 1
    io_grep_recursive "(TODO|FIXME|HACK|XXX|WARN|NOTE):" "$path"
}

# ── Inventory ────────────────────────────────────────────────────────────────
tool_fs_find_duplicates()  { files_find_dupes "$(tool_arg path "$YCA_PROJECT_DIR")"; }
tool_fs_disk_usage()  { files_disk_usage "$(tool_arg path "$YCA_PROJECT_DIR")"; }
tool_fs_recent_files()  { files_find_recent "$(tool_arg path "$YCA_PROJECT_DIR")" "$(int_guard "$(tool_arg days 7)" 7)"; }
tool_fs_sync()  {
    local src dst; src=$(tool_arg src "${1:-}"); dst=$(tool_arg dst)
    [[ -n "$src" && -n "$dst" ]] || { printf 'src and dst required'; return 1; }
    command -v rsync &>/dev/null || { printf 'rsync missing'; return 127; }
    path_check_allowed "$src" || { printf 'source not allowed: %s' "$src"; return 1; }
    path_check_allowed "$dst" || { printf 'destination not allowed: %s' "$dst"; return 1; }
    # Preview by default (no data moved); only apply:true performs the real copy,
    # behind a confirm — so a mistaken call can't overwrite. No --delete (additive
    # sync only) so a wrong dst can't wipe files. Was dry-run-ONLY before (a
    # registered `writes` tool that could never actually write).
    if [[ "$(tool_arg apply)" != "true" ]]; then
        printf '# DRY RUN (set apply:true to perform the sync)\n'
        rsync -avz --dry-run "$src/" "$dst/" 2>&1
        return 0
    fi
    confirm_action "Sync $src/ -> $dst/ (rsync, real copy)" "rsync -avz $src/ $dst/" || { confirm_denied_msg; return 1; }
    rsync -avz "$src/" "$dst/" 2>&1 && printf '\nsynced %s -> %s' "$src" "$dst"
}
tool_fs_tree() {
    local path depth; path=$(tool_arg path "$YCA_PROJECT_DIR"); depth=$(int_guard "$(tool_arg depth 2)" 2)
    path_check_allowed "$path" || return 1
    if command -v tree &>/dev/null; then
        tree -L "$depth" -a -I '.git|node_modules|.venv|__pycache__|target|dist|.harness*' "$path"
    else
        # Portable fallback: indent by directory depth.
        find "$path" -maxdepth "$depth" \( -name .git -o -name node_modules -o -name target \) -prune -o -print 2>/dev/null \
            | sed -e "s|^$path||" -e 's|[^/]*/|  |g' | head -300
    fi
}
tool_fs_largest_files() {
    local path count; path=$(tool_arg path "$YCA_PROJECT_DIR"); count=$(int_guard "$(tool_arg lines 20)" 20)
    path_check_allowed "$path" || return 1
    find "$path" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' -print0 2>/dev/null \
        | xargs -0 du -h 2>/dev/null | sort -rh | head -"$count"
}
tool_fs_broken_links() {
    local path out; path=$(tool_arg path "$YCA_PROJECT_DIR"); path_check_allowed "$path" || return 1
    out=$(find "$path" -type l ! -exec test -e {} \; -print 2>/dev/null | head -100)
    [[ -n "$out" ]] && printf '%s\n' "$out" || printf 'no broken symlinks'
}
tool_fs_extension_counts() {
    local path; path=$(tool_arg path "$YCA_PROJECT_DIR"); path_check_allowed "$path" || return 1
    find "$path" -type f ! -path '*/.git/*' ! -path '*/node_modules/*' 2>/dev/null | awk -F/ '
        { n=$NF; if (n ~ /\..+$/ && n !~ /^\./) { sub(/^.*\./, "", n); ext="."tolower(n) } else ext="(no ext)"; c[ext]++ }
        END { for (e in c) printf "%6d  %s\n", c[e], e }' | sort -rn | head -30
}
tool_fs_empty_files() {
    local path; path=$(tool_arg path "$YCA_PROJECT_DIR"); path_check_allowed "$path" || return 1
    printf '=== empty files (top 50) ===\n'
    find "$path" -type f -empty ! -path '*/.git/*' 2>/dev/null | head -50
    printf '\n=== empty dirs (top 50) ===\n'
    find "$path" -type d -empty ! -path '*/.git/*' 2>/dev/null | head -50
}
tool_fs_file_info() {
    local f; f=$(tool_arg file "$1"); [[ -e "$f" ]] || { printf 'path not found: %s' "$f"; return 1; }
    case "$(os_detect)" in
        darwin) stat -f 'perms: %Sp (%Lp)%nowner: %Su:%Sg%nsize: %z bytes%nmodified: %Sm%ntype: %HT' "$f" 2>&1; printf '\n' ;;
        *)      stat --printf 'perms: %A (%a)\nowner: %U:%G\nsize: %s bytes\nmodified: %y\ntype: %F\n' "$f" 2>&1 ;;
    esac
    if command -v file &>/dev/null; then printf 'content: %s\n' "$(file -b "$f" 2>/dev/null)"; fi
}

# ── Archives ─────────────────────────────────────────────────────────────────
tool_fs_archive() {
    local src out; src=$(tool_arg path "$1"); out=$(tool_arg file "${2:-archive_$(now_stamp).tar.gz}")
    [[ -e "$src" ]] || { printf 'path not found: %s' "$src"; return 1; }
    path_check_allowed "$src" || { printf 'source path not allowed: %s' "$src"; return 1; }
    path_check_allowed "$out" || { printf 'output path not allowed: %s' "$out"; return 1; }
    tar -czf "$out" -C "$(dirname "$src")" "$(basename "$src")" && printf 'created: %s' "$out"
}
tool_fs_extract_archive() {
    local f dest; f=$(tool_arg file "$1"); dest=$(tool_arg path "${2:-.}")
    [[ -f "$f" ]] || { printf 'archive not found: %s' "$f"; return 1; }
    path_check_allowed "$dest" || return 1
    # Refuse a tarball whose members would escape $dest — an absolute path or a
    # '..' component lets a crafted archive overwrite files anywhere on the host
    # (path_check only vetted the nominal dest, not where each member lands).
    # Listing first is portable across GNU/BSD tar, which differ on extract flags.
    local members
    members=$(tar -tzf "$f" 2>/dev/null) || { printf 'cannot read archive: %s (not a gzip tar?)' "$f"; return 1; }
    if printf '%s\n' "$members" | grep -qE '(^[[:space:]]*/|(^|/)\.\.(/|$))'; then
        printf 'refused: archive has absolute or ../ member paths (path traversal). Extract it manually if you trust the source.'
        return 1
    fi
    path_ensure_dir "$dest"
    tar -xzf "$f" -C "$dest" && printf 'extracted to: %s (%d entries)' "$dest" "$(printf '%s\n' "$members" | grep -c .)"
}

# ── Encryption (openssl AES-256; passphrase via $FS_PASSPHRASE, never argv) ──
_fs_passphrase() {
    if [[ -n "${FS_PASSPHRASE:-}" ]]; then printf 'env:FS_PASSPHRASE'; return 0; fi
    if [[ "$YCA_UI_MODE" == "human" ]]; then
        local p; p=$(prompt_user "passphrase" "" "Passphrase (not echoed to args)") || return 1
        [[ -z "$p" ]] && return 1
        export FS_PASSPHRASE="$p"; printf 'env:FS_PASSPHRASE'; return 0
    fi
    return 1
}
tool_fs_encrypt() {
    command -v openssl &>/dev/null || { printf 'openssl missing'; return 127; }
    local f; f=$(tool_arg file "$1"); [[ -f "$f" ]] || { printf 'file not found: %s' "$f"; return 1; }
    path_check_allowed "$f" || return 1
    local pass; pass=$(_fs_passphrase) || { printf 'set $FS_PASSPHRASE (or run interactively) to supply a passphrase'; return 1; }
    openssl enc -aes-256-cbc -pbkdf2 -salt -in "$f" -out "$f.enc" -pass "$pass" 2>&1 && printf 'encrypted: %s.enc' "$f"
}
tool_fs_decrypt() {
    command -v openssl &>/dev/null || { printf 'openssl missing'; return 127; }
    local f out; f=$(tool_arg file "$1"); [[ -f "$f" ]] || { printf 'file not found: %s' "$f"; return 1; }
    path_check_allowed "$f" || return 1
    out="${f%.enc}"; [[ "$out" == "$f" ]] && out="$f.dec"
    local pass; pass=$(_fs_passphrase) || { printf 'set $FS_PASSPHRASE (or run interactively) to supply a passphrase'; return 1; }
    openssl enc -d -aes-256-cbc -pbkdf2 -in "$f" -out "$out" -pass "$pass" 2>&1 && printf 'decrypted: %s' "$out"
}

# ── Act-half: move / copy / rename / organize / dedupe / apply-to-glob ────────
# Every write is confined to the project fence (path_check both ends), confirmed,
# and never clobbers silently. These complete the file-management jobs that were
# report/dry-run only before (fs_find_duplicates/fs_sync).
_fs_sha256() { shasum -a 256 "$1" 2>/dev/null | cut -d' ' -f1 || sha256sum "$1" 2>/dev/null | cut -d' ' -f1; }

# fs_apply — apply a registered tool to every file matching a glob (or in a dir).
# Turns any single-file tool (media_*/opencv_*/doc_*/fs_*) into a folder batch:
# ONE consent covers the whole run (per-file sub-tool prompts are suppressed),
# fan-out is capped, each path is re-checked, and nesting is refused.
tool_fs_apply() {
    local glob dir tool field extra maxf
    glob=$(tool_arg glob); dir=$(tool_arg dir); tool=$(tool_arg tool)
    field=$(tool_arg field file); extra=$(tool_arg args '{}')
    maxf=$(int_guard "$(tool_arg max 200)" 200); (( maxf > 1000 )) && maxf=1000
    [[ -n "$tool" ]] || { printf 'tool required (.tool — the per-file tool to apply)'; return 1; }
    # Only per-file transforms make sense here; refuse the arbitrary-code / whole-
    # content tools (batching them over a folder is a footgun, and tool_invoke
    # bypasses the category gate).
    case "$tool" in
        fs_apply|batch|bash|write|edit) printf 'refused: %s cannot be batched via fs_apply (not a safe per-file transform)' "$tool"; return 1 ;;
    esac
    local -a files=()
    if [[ -n "$glob" ]]; then
        mapfile -t files < <(compgen -G "$glob" 2>/dev/null)
    elif [[ -n "$dir" ]]; then
        path_check_allowed "$dir" || { printf 'path not allowed: %s' "$dir"; return 1; }
        mapfile -t files < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
    else
        printf 'glob or dir required'; return 1
    fi
    (( ${#files[@]} == 0 )) && { printf 'no files matched'; return 0; }
    (( ${#files[@]} > maxf )) && { printf 'refused: %d files exceed the cap of %d (raise .max deliberately)' "${#files[@]}" "$maxf"; return 1; }
    local preview="${files[*]:0:5}"; (( ${#files[@]} > 5 )) && preview+=" … (+$(( ${#files[@]} - 5 )) more)"
    confirm_action "Apply $tool to ${#files[@]} file(s)" "$preview" || { confirm_denied_msg; return 1; }
    local _saved_ac="$YCA_AUTO_CONFIRM"; YCA_AUTO_CONFIRM=true    # batch consent already given
    local f rc out overall=0 n=0 callargs
    for f in "${files[@]}"; do
        [[ -e "$f" ]] || continue
        if ! path_check_allowed "$f"; then printf '[skip] %s (outside allowed paths)\n' "$f"; overall=1; continue; fi
        callargs=$(printf '%s' "$extra" | jq -c --arg k "$field" --arg v "$f" '. + {($k):$v}' 2>/dev/null) || callargs="{\"$field\":\"$f\"}"
        out=$(tool_invoke "$tool" "$callargs"); rc=$?
        printf '[%s] %s: %s\n' "$([[ $rc -eq 0 ]] && printf ok || printf FAIL)" "$f" "$(printf '%s' "$out" | head -1)"
        (( rc != 0 )) && overall=1; (( n++ ))
    done
    YCA_AUTO_CONFIRM="$_saved_ac"
    printf 'applied %s to %d file(s)\n' "$tool" "$n"
    return $overall
}

tool_fs_move() {
    local src dst; src=$(tool_arg src "${1:-}"); dst=$(tool_arg dst)
    [[ -n "$src" && -n "$dst" ]] || { printf 'src and dst required'; return 1; }
    [[ -e "$src" ]] || { printf 'source not found: %s' "$src"; return 1; }
    path_check_allowed "$src" || { printf 'source not allowed: %s' "$src"; return 1; }
    path_check_allowed "$dst" || { printf 'destination not allowed: %s' "$dst"; return 1; }
    local action="Move $src -> $dst"; [[ -e "$dst" && ! -d "$dst" ]] && action="OVERWRITE $dst by moving $src onto it"
    confirm_action "$action" "mv $src $dst" || { confirm_denied_msg; return 1; }
    path_ensure_dir "$(dirname "$dst")"
    mv -- "$src" "$dst" 2>&1 && printf 'moved %s -> %s' "$src" "$dst"
}

tool_fs_copy() {
    local src dst; src=$(tool_arg src "${1:-}"); dst=$(tool_arg dst)
    [[ -n "$src" && -n "$dst" ]] || { printf 'src and dst required'; return 1; }
    [[ -e "$src" ]] || { printf 'source not found: %s' "$src"; return 1; }
    path_check_allowed "$src" || { printf 'source not allowed: %s' "$src"; return 1; }
    path_check_allowed "$dst" || { printf 'destination not allowed: %s' "$dst"; return 1; }
    local action="Copy $src -> $dst"; [[ -e "$dst" && ! -d "$dst" ]] && action="OVERWRITE $dst with a copy of $src"
    confirm_action "$action" "cp -R $src $dst" || { confirm_denied_msg; return 1; }
    path_ensure_dir "$(dirname "$dst")"
    cp -R -- "$src" "$dst" 2>&1 && printf 'copied %s -> %s' "$src" "$dst"
}

# fs_organize — move a directory's files into subfolders by extension or by month.
tool_fs_organize() {
    local dir by; dir=$(tool_arg dir "$(tool_arg path)"); by=$(tool_arg by ext)
    [[ -n "$dir" ]] || { printf 'dir required'; return 1; }
    path_check_allowed "$dir" || { printf 'path not allowed: %s' "$dir"; return 1; }
    [[ -d "$dir" ]] || { printf 'not a directory: %s' "$dir"; return 1; }
    case "$by" in ext|type|date) ;; *) printf 'by must be ext|date'; return 1 ;; esac
    local -a files=(); mapfile -t files < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
    (( ${#files[@]} == 0 )) && { printf 'no files to organize in %s' "$dir"; return 0; }
    confirm_action "Organize ${#files[@]} file(s) in $dir into subfolders by $by" "move files into $dir/<$by>/" || { confirm_denied_msg; return 1; }
    local f base bucket mt moved=0
    for f in "${files[@]}"; do
        base=$(basename "$f")
        case "$by" in
            ext|type) bucket=$(path_ext "$f"); [[ -z "$bucket" ]] && bucket="no_ext" ;;
            date)     mt=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f" 2>/dev/null); printf -v bucket '%(%Y-%m)T' "${mt:-0}" ;;
        esac
        path_ensure_dir "$dir/$bucket"
        [[ -e "$dir/$bucket/$base" ]] && continue   # never clobber
        mv -- "$f" "$dir/$bucket/$base" 2>/dev/null && (( moved++ ))
    done
    printf 'organized %d file(s) into %s/<%s>/' "$moved" "$dir" "$by"
}

# fs_rename — literal-substring rename across a directory's files (collision-safe).
tool_fs_rename() {
    local dir match replace; dir=$(tool_arg dir "$(tool_arg path)"); match=$(tool_arg match); replace=$(tool_arg replace)
    [[ -n "$dir" && -n "$match" ]] || { printf 'dir and match required (replace defaults to empty = delete the matched text)'; return 1; }
    path_check_allowed "$dir" || { printf 'path not allowed: %s' "$dir"; return 1; }
    [[ -d "$dir" ]] || { printf 'not a directory: %s' "$dir"; return 1; }
    local -a from=() to=(); local f base newbase
    while IFS= read -r f; do
        base=$(basename "$f"); newbase="${base//"$match"/"$replace"}"
        [[ "$newbase" == "$base" || -z "$newbase" ]] && continue
        # Keep the result a bare filename — a '/' (or . / ..) in `replace` would
        # turn it into a path and escape the folder (e.g. replace='../etc/x').
        case "$newbase" in */*|.|..) continue ;; esac
        from+=("$f"); to+=("$dir/$newbase")
    done < <(find "$dir" -maxdepth 1 -type f 2>/dev/null)
    (( ${#from[@]} == 0 )) && { printf 'no filenames contain "%s" in %s' "$match" "$dir"; return 0; }
    local preview="" i
    for (( i=0; i<${#from[@]} && i<5; i++ )); do preview+="$(basename "${from[i]}") -> $(basename "${to[i]}")"$'\n'; done
    confirm_action "Rename ${#from[@]} file(s): '$match' -> '$replace'" "$preview" || { confirm_denied_msg; return 1; }
    local renamed=0
    for (( i=0; i<${#from[@]}; i++ )); do
        [[ -e "${to[i]}" ]] && { printf '[skip] %s (target exists)\n' "$(basename "${to[i]}")"; continue; }
        mv -- "${from[i]}" "${to[i]}" 2>/dev/null && (( renamed++ ))
    done
    printf 'renamed %d file(s)' "$renamed"
}

# fs_dedupe — find byte-identical files (full sha256) and, with apply:true, delete
# all but the first copy of each. Preview by default; irreversible on apply.
tool_fs_dedupe() {
    local dir apply; dir=$(tool_arg path "$(tool_arg dir)"); apply=$(tool_arg apply)
    [[ -n "$dir" ]] || { printf 'path required'; return 1; }
    path_check_allowed "$dir" || { printf 'path not allowed: %s' "$dir"; return 1; }
    [[ -d "$dir" ]] || { printf 'not a directory: %s' "$dir"; return 1; }
    local -A seen=(); local -a dupes=(); local f h
    while IFS= read -r f; do
        [[ -f "$f" ]] || continue
        h=$(_fs_sha256 "$f"); [[ -z "$h" ]] && continue
        if [[ -n "${seen[$h]:-}" ]]; then dupes+=("$f"); else seen[$h]="$f"; fi
    done < <(find "$dir" -type f 2>/dev/null | sort)
    (( ${#dupes[@]} == 0 )) && { printf 'no duplicate files in %s' "$dir"; return 0; }
    if [[ "$apply" != "true" ]]; then
        printf '%d duplicate file(s) (each identical to an earlier copy):\n' "${#dupes[@]}"
        printf '%s\n' "${dupes[@]}"
        printf '\n(preview only — set apply:true to delete these, keeping the first copy of each)'
        return 0
    fi
    confirm_action "DELETE ${#dupes[@]} duplicate file(s) in $dir (keep the first copy of each)" "$(printf '%s\n' "${dupes[@]:0:5}")" || { confirm_denied_msg; return 1; }
    local removed=0
    for f in "${dupes[@]}"; do
        path_check_allowed "$f" || continue
        rm -- "$f" 2>/dev/null && (( removed++ ))
    done
    printf 'removed %d duplicate file(s)' "$removed"
}

tool_register "fs_search"     tool_fs_search     '{"type":"object","properties":{"pattern":{"type":"string","description":"the search pattern (text or regex)"},"path":{"type":"string","description":"file or directory path relative to the project root"}},"required":["pattern"]}' safe all fs
tool_register "fs_replace"  tool_fs_replace  '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"pattern":{"type":"string","description":"the search pattern (text or regex)"},"replacement":{"type":"string","description":"the replacement text"}},"required":["pattern","replacement"]}' writes all fs
tool_register "fs_find_todos"    tool_fs_find_todos    '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_find_duplicates"     tool_fs_find_duplicates     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_disk_usage"     tool_fs_disk_usage     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_recent_files"     tool_fs_recent_files     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"days":{"type":"integer","description":"number of days"}}}' safe all fs
tool_register "fs_sync"     tool_fs_sync     '{"type":"object","properties":{"src":{"type":"string","description":"source path"},"dst":{"type":"string","description":"destination path"}},"required":["src","dst"]}' writes all fs
tool_register "fs_tree"     tool_fs_tree     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"depth":{"type":"integer","description":"the depth"}}}' safe all fs
tool_register "fs_archive"      tool_fs_archive      '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["path"]}' writes all fs
tool_register "fs_extract_archive"    tool_fs_extract_archive    '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"path":{"type":"string","description":"file or directory path relative to the project root"}},"required":["file"]}' writes all fs
tool_register "fs_encrypt"  tool_fs_encrypt  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all fs
tool_register "fs_decrypt"  tool_fs_decrypt  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all fs
tool_register "fs_largest_files"      tool_fs_largest_files      '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"lines":{"type":"integer","description":"number of lines to return"}}}' safe all fs
tool_register "fs_broken_links" tool_fs_broken_links '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_extension_counts"   tool_fs_extension_counts   '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_empty_files"        tool_fs_empty_files        '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all fs
tool_register "fs_file_info"         tool_fs_file_info         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all fs
tool_register "fs_apply"    tool_fs_apply    '{"description":"Apply a tool to every file matching a glob/dir (batch)","type":"object","properties":{"glob":{"type":"string","description":"the glob"},"dir":{"type":"string","description":"directory path relative to the project root"},"tool":{"type":"string","description":"the tool"},"field":{"type":"string","description":"the field"},"args":{"type":"object","description":"the args"},"max":{"type":"integer","description":"the max"}},"required":["tool"]}' writes all fs
tool_register "fs_move"     tool_fs_move     '{"type":"object","properties":{"src":{"type":"string","description":"source path"},"dst":{"type":"string","description":"destination path"}},"required":["src","dst"]}' writes all fs
tool_register "fs_copy"     tool_fs_copy     '{"type":"object","properties":{"src":{"type":"string","description":"source path"},"dst":{"type":"string","description":"destination path"}},"required":["src","dst"]}' writes all fs
tool_register "fs_organize" tool_fs_organize '{"description":"Move a folder'"'"'s files into subfolders by ext or month","type":"object","properties":{"dir":{"type":"string","description":"directory path relative to the project root"},"by":{"type":"string","enum":["ext","date"],"description":"how to group files: by file extension (ext) or by date"}},"required":["dir"]}' writes all fs
tool_register "fs_rename"   tool_fs_rename   '{"description":"Batch-rename files by literal substring substitution","type":"object","properties":{"dir":{"type":"string","description":"directory path relative to the project root"},"match":{"type":"string","description":"the match"},"replace":{"type":"string","description":"the replace"}},"required":["dir","match"]}' writes all fs
tool_register "fs_dedupe"   tool_fs_dedupe   '{"description":"Find identical files; apply:true deletes all but the first","type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"apply":{"type":"boolean","description":"the apply"}},"required":["path"]}' writes all fs
