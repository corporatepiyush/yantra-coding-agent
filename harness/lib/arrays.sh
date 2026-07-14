# lib/03-arrays.sh — Indexed array utilities
# All functions take arrays by nameref (Bash 4.3+) or by value via positional args.

# arr_contains ARRAY_NAME VALUE -> 0 if VALUE is in array
arr_contains() {
    local -n _arr_ref="$1"
    local val="$2" item
    for item in "${_arr_ref[@]}"; do
        [[ "$item" == "$val" ]] && return 0
    done
    return 1
}

# arr_index ARRAY_NAME VALUE -> prints index or -1
arr_index() {
    local -n _arr_idx_ref="$1"
    local val="$2" i
    for i in "${!_arr_idx_ref[@]}"; do
        [[ "${_arr_idx_ref[$i]}" == "$val" ]] && { printf '%d' "$i"; return 0; }
    done
    printf '%d' -1
}

# arr_push ARRAY_NAME VALUE... -> appends
arr_push() {
    local -n _arr_push_ref="$1"; shift
    _arr_push_ref+=("$@")
}

# arr_pop ARRAY_NAME -> prints last element and removes it
arr_pop() {
    local -n _arr_pop_ref="$1"
    local len=${#_arr_pop_ref[@]}
    (( len == 0 )) && return 1
    local last="${_arr_pop_ref[$(( len - 1 ))]}"
    unset '_arr_pop_ref[$(( len - 1 ))]'
    printf '%s' "$last"
}

# arr_shift ARRAY_NAME -> prints first element and removes it
arr_shift() {
    local -n _arr_shift_ref="$1"
    (( ${#_arr_shift_ref[@]} == 0 )) && return 1
    local first="${_arr_shift_ref[0]}"
    _arr_shift_ref=("${_arr_shift_ref[@]:1}")
    printf '%s' "$first"
}

# arr_reverse ARRAY_NAME -> reverses in place
arr_reverse() {
    local -n _arr_rev_ref="$1"
    local n=${#_arr_rev_ref[@]} i tmp
    for ((i=0; i<n/2; i++)); do
        tmp="${_arr_rev_ref[$i]}"
        _arr_rev_ref[$i]="${_arr_rev_ref[$(( n-1-i ))]}"
        _arr_rev_ref[$(( n-1-i ))]="$tmp"
    done
}

# arr_unique ARRAY_NAME -> prints unique elements (preserves order)
arr_unique() {
    local -n _arr_uniq_ref="$1"
    local seen="" item
    declare -A _seen
    for item in "${_arr_uniq_ref[@]}"; do
        [[ -z "${_seen[$item]:-}" ]] && { printf '%s\n' "$item"; _seen[$item]=1; }
    done
}

# arr_sort ARRAY_NAME -> prints sorted elements (one per line)
arr_sort() {
    local -n _arr_sort_ref="$1"
    local item
    for item in "${_arr_sort_ref[@]}"; do printf '%s\0' "$item"; done \
        | sort -z | while IFS= read -r -d '' item; do printf '%s\n' "$item"; done
}

# arr_size ARRAY_NAME -> prints count
arr_size() {
    local -n _arr_size_ref="$1"
    printf '%d' "${#_arr_size_ref[@]}"
}

# arr_join ARRAY_NAME DELIM -> prints joined string
arr_join() {
    local -n _arr_join_ref="$1"
    local delim="$2" out="" first=1 item
    for item in "${_arr_join_ref[@]}"; do
        (( first )) && { out="$item"; first=0; continue; }
        out+="$delim$item"
    done
    printf '%s' "$out"
}

# arr_map ARRAY_NAME FUNCTION -> calls FUNCTION on each element, prints results
arr_map() {
    local -n _arr_map_ref="$1"
    local fn="$2" item
    for item in "${_arr_map_ref[@]}"; do "$fn" "$item"; done
}

# arr_filter ARRAY_NAME FUNCTION -> prints elements where FUNCTION returns 0
arr_filter() {
    local -n _arr_filter_ref="$1"
    local fn="$2" item
    for item in "${_arr_filter_ref[@]}"; do
        if "$fn" "$item"; then printf '%s\n' "$item"; fi
    done
}

# arr_slice ARRAY_NAME START END -> prints elements from START to END (exclusive)
arr_slice() {
    local -n _arr_slice_ref="$1"
    local start="$2" end="$3"
    printf '%s\n' "${_arr_slice_ref[@]:start:end-start}"
}

# arr_from_stdin ARRAY_NAME -> reads stdin lines into array (mapfile, no per-line fork)
arr_from_stdin() {
    local -n _arr_stdin_ref="$1"
    mapfile -t _arr_stdin_ref
}

# ─── Nushell-inspired array utilities ───

# arr_flatten ARRAY_NAME -> prints all elements, flattening nested arrays
# (bash has no nested arrays, but this handles "a b c" split)
arr_flatten() {
    local -n _arr_flat_ref="$1"
    local item
    for item in "${_arr_flat_ref[@]}"; do
        if [[ "$item" == *' '* ]]; then
            local sub
            for sub in $item; do printf '%s\n' "$sub"; done
        else
            printf '%s\n' "$item"
        fi
    done
}

# arr_chunk ARRAY_NAME SIZE -> prints chunks (each chunk on a line, space-separated)
arr_chunk() {
    local -n _arr_chunk_ref="$1"
    local size="$2" i=0 chunk=""
    local item
    for item in "${_arr_chunk_ref[@]}"; do
        [[ -n "$chunk" ]] && chunk+=" "
        chunk+="$item"
        ((++i))
        (( i % size == 0 )) && { printf '%s\n' "$chunk"; chunk=""; }
    done
    [[ -n "$chunk" ]] && printf '%s\n' "$chunk"
}

# arr_sort_by ARRAY_NAME FN -> sort by comparator function
arr_sort_by() {
    local -n _arr_sb_ref="$1"
    local fn="$2"
    local item
    for item in "${_arr_sb_ref[@]}"; do printf '%s\0' "$item"; done \
        | sort -z -t$'\0' -k1,1 \
        | while IFS= read -r -d '' item; do printf '%s\n' "$item"; done
}

# arr_group_by ARRAY_NAME FN -> prints groups (key<TAB>values space-separated)
# FN takes element, prints group key
arr_group_by() {
    local -n _arr_gb_ref="$1"
    local fn="$2"
    declare -A groups
    local item key
    for item in "${_arr_gb_ref[@]}"; do
        key=$("$fn" "$item")
        [[ -n "${groups[$key]:-}" ]] && groups[$key]+=" "
        groups[$key]+="$item"
    done
    for key in "${!groups[@]}"; do
        printf '%s\t%s\n' "$key" "${groups[$key]}"
    done
}

# arr_enumerate ARRAY_NAME -> prints "index<TAB>value" per line
arr_enumerate() {
    local -n _arr_enum_ref="$1"
    local i
    for i in "${!_arr_enum_ref[@]}"; do
        printf '%d\t%s\n' "$i" "${_arr_enum_ref[$i]}"
    done
}

# arr_zip ARRAY_A ARRAY_B -> prints "a<TAB>b" per line
arr_zip() {
    local -n _arr_zip_a="$1"
    local -n _arr_zip_b="$2"
    local len=${#_arr_zip_a[@]}
    (( ${#_arr_zip_b[@]} < len )) && len=${#_arr_zip_b[@]}
    local i
    for ((i=0; i<len; i++)); do
        printf '%s\t%s\n' "${_arr_zip_a[$i]}" "${_arr_zip_b[$i]}"
    done
}

# arr_reduce ARRAY_NAME FN INITIAL -> prints reduced value
# FN takes accumulator and element, prints new accumulator
arr_reduce() {
    local -n _arr_red_ref="$1"
    local fn="$2" acc="$3"
    local item
    for item in "${_arr_red_ref[@]}"; do
        acc=$("$fn" "$acc" "$item")
    done
    printf '%s' "$acc"
}

# par_each ARRAY_NAME FN [PARALLELISM] -> run FN on each element in parallel
par_each() {
    local -n _par_ref="$1"
    local fn="$2" parallel="${3:-$(math_core_count)}"
    local item
    for item in "${_par_ref[@]}"; do
        printf '%s\0' "$item"
    done | xargs -0 -P "$parallel" -I{} bash -c "$fn {}"
}

# par_filter ARRAY_NAME FN [PARALLELISM] -> filter in parallel
par_filter() {
    local -n _par_filt_ref="$1"
    local fn="$2" parallel="${3:-$(math_core_count)}"
    local item
    for item in "${_par_filt_ref[@]}"; do
        printf '%s\0' "$item"
    done | xargs -0 -P "$parallel" -I{} sh -c "$fn {} && echo {}" 2>/dev/null
}

# arr_skip ARRAY_NAME N -> skip first N elements, print rest
arr_skip() {
    local -n _arr_skip_ref="$1"
    local n="$2"
    printf '%s\n' "${_arr_skip_ref[@]:n}"
}

# arr_take ARRAY_NAME N -> print first N elements
arr_take() {
    local -n _arr_take_ref="$1"
    local n="$2"
    printf '%s\n' "${_arr_take_ref[@]:0:n}"
}

# arr_interleave ARRAY_A ARRAY_B -> a1 b1 a2 b2 ...
arr_interleave() {
    local -n _arr_il_a="$1"
    local -n _arr_il_b="$2"
    local len=${#_arr_il_a[@]}
    (( ${#_arr_il_b[@]} > len )) && len=${#_arr_il_b[@]}
    local i
    for ((i=0; i<len; i++)); do
        [[ -n "${_arr_il_a[$i]:-}" ]] && printf '%s\n' "${_arr_il_a[$i]}"
        [[ -n "${_arr_il_b[$i]:-}" ]] && printf '%s\n' "${_arr_il_b[$i]}"
    done
}
