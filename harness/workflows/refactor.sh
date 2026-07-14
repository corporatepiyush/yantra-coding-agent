# workflows/refactor.sh — Refactor workflows

# _refactor_lang EXT -> ast-grep language id for a file extension (empty if unknown).
# ast-grep needs -l to force a grammar on a single file; for a directory it infers
# per-file, so an empty result just means "let ast-grep decide from extensions".
_refactor_lang() {
    case "$1" in
        js|jsx|mjs|cjs)         printf 'javascript' ;;
        ts)                     printf 'typescript' ;;
        tsx)                    printf 'tsx' ;;
        py|pyi)                 printf 'python' ;;
        rs)                     printf 'rust' ;;
        go)                     printf 'go' ;;
        java)                   printf 'java' ;;
        kt|kts)                 printf 'kotlin' ;;
        rb)                     printf 'ruby' ;;
        php)                    printf 'php' ;;
        c|h)                    printf 'c' ;;
        cc|cpp|cxx|hpp|hh|hxx)  printf 'cpp' ;;
        cs)                     printf 'csharp' ;;
        scala|sc)               printf 'scala' ;;
        swift)                  printf 'swift' ;;
        lua)                    printf 'lua' ;;
        sh|bash)                printf 'bash' ;;
        *)                      printf '' ;;
    esac
}

# refactor.rename-symbol — rename a symbol across files with ast-grep.
# Was a FALSE SUCCESS: it ran `sg run -p old -r new` WITHOUT -U, so ast-grep only
# printed a diff and wrote nothing, then the workflow emitted emit_ok "renamed".
# Now: require sg, constrain to bare identifiers, DRY-RUN for a real diff, confirm
# with that diff, APPLY with -U, and emit_fail honestly when nothing changed.
wf_refactor_rename() {
    local old="${INPUT_old:-}" new="${INPUT_new:-}"
    local path="${INPUT_path:-.}" lang="${INPUT_lang:-}"
    val_required "$old" "INPUT_old" || return 1
    val_required "$new" "INPUT_new" || return 1

    # ast-grep is mandatory — never fake a rename without it.
    if ! command -v sg &>/dev/null; then
        emit_fail "rename needs ast-grep (the 'sg' binary), which isn't installed. Install with: brew install ast-grep (or: cargo install ast-grep). Nothing was changed."
        return 0
    fi

    # Constrain to a real symbol rename: both names must be bare identifiers. This
    # keeps ast-grep matching identifier NODES (so member access like x.old is left
    # alone) and stops an arbitrary structural pattern ($A, foo(), a.b) from
    # rewriting far more than a symbol.
    local id_re='^[A-Za-z_][A-Za-z0-9_]*$'
    [[ "$old" =~ $id_re ]] || { emit_fail "old symbol '$old' is not a bare identifier; refactor.rename-symbol renames identifiers only"; return 0; }
    [[ "$new" =~ $id_re ]] || { emit_fail "new symbol '$new' is not a bare identifier"; return 0; }

    # Keep the scan inside the project (path is relative to it). Neutralise a
    # leading dash so ast-grep can't read the target as an option.
    [[ "$path" == -* ]] && path="./$path"
    path_check_allowed "$YCA_PROJECT_DIR/$path" || return 1

    # Infer a language: explicit INPUT_lang wins; else derive from a single-file
    # target's extension; else leave empty so ast-grep infers per file.
    [[ -z "$lang" && -f "$YCA_PROJECT_DIR/$path" ]] && lang=$(_refactor_lang "$(path_ext "$YCA_PROJECT_DIR/$path")")

    local -a tail=(-p "$old" -r "$new")
    [[ -n "$lang" ]] && tail+=(-l "$lang")
    tail+=("$path")

    emit_progress "rename" "planning $old -> $new"

    # 1) Dry run: ast-grep prints a unified diff and writes NOTHING.
    local dry=""
    dry=$(cd "$YCA_PROJECT_DIR" && sg run "${tail[@]}" 2>/dev/null) || true
    if [[ -z "$dry" ]]; then
        emit_fail "no occurrences of identifier '$old' found in ${path} — nothing to rename"
        return 0
    fi

    # 2) Confirm with the ACTUAL diff of what will change.
    confirm_action "Rename '$old' -> '$new' via ast-grep (${lang:-auto}, in ${path}). Diff:"$'\n'"$dry" \
        || { emit_fail "cancelled"; return 0; }

    # 3) Apply for real with -U/--update-all.
    local applied="" rc=0
    applied=$(cd "$YCA_PROJECT_DIR" && sg run -U "${tail[@]}" 2>&1) || rc=$?
    if (( rc != 0 )); then
        emit_fail "ast-grep failed to apply the rename (exit $rc): ${applied:-no output}"
        return 0
    fi
    [[ -n "$applied" ]] && printf '%s\n' "$applied" >&2
    emit_ok "renamed '$old' -> '$new' (${applied:-applied})"
}

# _refactor_insert_at EXT LINES_ARRAY_NAME -> index at which a top-level
# declaration should be inserted: AFTER any shebang and the language's header
# block (package / import / use / #include). The old code prepended to LINE 1 —
# above `package`/imports/shebang — which is a syntax error in most languages.
_refactor_insert_at() {
    local ext="$1"; local -n _L="$2"
    local i=0 n=${#_L[@]} t
    (( n == 0 )) && { printf '0'; return 0; }
    [[ "${_L[0]}" == '#!'* ]] && i=1
    while (( i < n )); do
        t="${_L[i]#"${_L[i]%%[![:space:]]*}"}"   # left-trimmed line
        case "$ext" in
            go)
                if [[ -z "$t" || "$t" == '//'* || "$t" == package* ]]; then i=$((i+1)); continue; fi
                if [[ "$t" == 'import ('* || "$t" == 'import('* ]]; then
                    i=$((i+1))
                    while (( i < n )) && [[ "${_L[i]}" != *')'* ]]; do i=$((i+1)); done
                    i=$((i+1)); continue
                fi
                if [[ "$t" == 'import '* ]]; then i=$((i+1)); continue; fi
                break ;;
            py|pyi)
                if [[ -z "$t" || "$t" == '#'* || "$t" == 'import '* || "$t" == 'from '* ]]; then i=$((i+1)); continue; fi
                break ;;
            js|jsx|mjs|cjs|ts|tsx)
                if [[ -z "$t" || "$t" == '//'* || "$t" == 'import '* || "$t" == *'require('* \
                      || "$t" == "'use strict'"* || "$t" == '"use strict"'* ]]; then i=$((i+1)); continue; fi
                break ;;
            rs)
                if [[ -z "$t" || "$t" == '//'* || "$t" == 'use '* || "$t" == 'extern crate'* || "$t" == '#!'* ]]; then i=$((i+1)); continue; fi
                break ;;
            c|h|cc|cpp|cxx|hpp|hh|hxx)
                if [[ -z "$t" || "$t" == '//'* || "$t" == '#include'* || "$t" == '#define'* \
                      || "$t" == '#pragma'* || "$t" == '#ifndef'* || "$t" == '#ifdef'* ]]; then i=$((i+1)); continue; fi
                break ;;
            *)
                break ;;
        esac
    done
    printf '%s' "$i"
}

# refactor.extract-const — lift a literal into a named constant.
# Was broken two ways: it prepended the declaration to LINE 1 (above package/
# import/shebang -> syntax error) AND never substituted the value with the name.
# Now: insert AFTER the header block and replace the literal with the new name.
wf_refactor_extract() {
    local value="${INPUT_value:-}" name="${INPUT_name:-}" file="${INPUT_file:-}"
    val_required "$value" "INPUT_value" || return 1
    val_required "$name" "INPUT_name" || return 1
    val_required "$file" "INPUT_file" || return 1
    path_check_allowed "$YCA_PROJECT_DIR/$file" || return 1
    [[ -f "$YCA_PROJECT_DIR/$file" ]] || { emit_fail "file not found: $file"; return 0; }
    [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { emit_fail "constant name '$name' is not a valid identifier"; return 0; }

    # `value` is the literal AS WRITTEN in source (include its quotes for a string,
    # e.g. "hello"); we insert it verbatim and substitute the same text, so the
    # declaration and the replaced occurrences stay consistent.
    local ext decl
    ext=$(path_ext "$YCA_PROJECT_DIR/$file")
    case "$ext" in
        py|pyi)                 decl="${name} = ${value}" ;;
        js|jsx|mjs|cjs|ts|tsx)  decl="const ${name} = ${value};" ;;
        rs)
            local rty="&str"
            if   [[ "$value" =~ ^-?[0-9]+$ ]];          then rty="i64"
            elif [[ "$value" =~ ^-?[0-9]+\.[0-9]+$ ]];  then rty="f64"
            fi
            decl="const ${name}: ${rty} = ${value};" ;;
        go)                     decl="const ${name} = ${value}" ;;
        rb)                     decl="${name} = ${value}" ;;
        java)                   decl="private static final var ${name} = ${value};" ;;
        c|h|cc|cpp|cxx|hpp)     decl="#define ${name} ${value}" ;;
        *)                      decl="#define ${name} ${value}" ;;
    esac

    local -a lines=()
    mapfile -t lines < "$YCA_PROJECT_DIR/$file"

    # Require the literal to actually be present — "extract" lifts an EXISTING
    # value; otherwise we'd inject an orphan constant and silently "succeed".
    local cnt=0 ln
    for ln in "${lines[@]}"; do
        [[ "$ln" == *"$value"* ]] && cnt=$((cnt+1))
    done
    if (( cnt == 0 )); then
        emit_fail "value ${value} not found in ${file} — nothing to extract"
        return 0
    fi

    local at; at=$(_refactor_insert_at "$ext" lines)

    confirm_action "Extract constant '${name}' = ${value} in ${file}" \
        "insert '${decl}' after line ${at}" \
        "replace ${cnt} line(s) containing ${value} with ${name}" \
        || { emit_fail "cancelled"; return 0; }

    # Reassemble: insert the declaration at the computed position and substitute the
    # literal (never inside the inserted decl, which is emitted verbatim).
    local out="" idx line
    for idx in "${!lines[@]}"; do
        [[ "$idx" -eq "$at" ]] && out+="${decl}"$'\n'
        line="${lines[idx]}"
        line="${line//"$value"/$name}"
        out+="${line}"$'\n'
    done
    [[ "$at" -ge "${#lines[@]}" ]] && out+="${decl}"$'\n'

    printf '%s' "$out" > "$YCA_PROJECT_DIR/$file"
    emit_ok "extracted constant ${name} in ${file} (${cnt} line(s) updated)"
}

# refactor.signature — was a no-op stub that emitted success. A safe, type-aware
# rewrite of every call site is out of scope for a mechanical tool, so this is now
# HONEST: it prints a concrete plan and emit_fail (plan-only, not implemented). It
# never claims a change it didn't make.
wf_refactor_signature() {
    local fn="${INPUT_fn:-the function}"
    emit_progress "signature" "planning"
    {
        printf 'Signature change is NOT automated: safely updating every call site needs type-aware analysis.\n'
        printf 'Plan for %s:\n' "$fn"
        printf '  1. If the name changes, run refactor.rename-symbol (mechanical).\n'
        printf '  2. Edit the definition signature (params/return) by hand or via an ast-grep rule.\n'
        printf '  3. Find call sites (grep / ast-grep) and adjust arguments at each.\n'
        printf '  4. Re-run build + tests to catch the ones you missed.\n'
    } >&2
    emit_fail "signature refactor is plan-only (not implemented) — see the printed plan; nothing was changed"
    return 0
}

wf_register "refactor.rename-symbol" wf_refactor_rename    2 writes "ast-grep" "Rename a symbol across files"
wf_register "refactor.extract-const" wf_refactor_extract   2 writes "" "Extract a literal into a named constant"
wf_register "refactor.signature"     wf_refactor_signature 2 safe   "" "Signature change plan (advisory, no writes)"
