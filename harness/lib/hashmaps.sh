# lib/04-hashmaps.sh — Associative array (hashmap/dict) utilities
# Uses Bash 4.0+ declare -A. Pass map name as first arg (nameref).

# map_set MAPNAME KEY VALUE
map_set() {
    local -n _map_set_ref="$1"
    _map_set_ref["$2"]="$3"
}

# map_get MAPNAME KEY -> prints value (empty if missing)
map_get() {
    local -n _map_get_ref="$1"
    printf '%s' "${_map_get_ref[$2]:-}"
}

# map_has MAPNAME KEY -> 0 if key exists
map_has() {
    local -n _map_has_ref="$1"
    [[ -v "_map_has_ref[$2]" ]]
}

# map_delete MAPNAME KEY
map_delete() {
    local -n _map_del_ref="$1"
    unset "_map_del_ref[$2]"
}

# map_keys MAPNAME -> prints all keys (one per line)
map_keys() {
    local -n _map_keys_ref="$1"
    local k
    for k in "${!_map_keys_ref[@]}"; do printf '%s\n' "$k"; done
}

# map_values MAPNAME -> prints all values (one per line)
map_values() {
    local -n _map_vals_ref="$1"
    local v
    for v in "${_map_vals_ref[@]}"; do printf '%s\n' "$v"; done
}

# map_size MAPNAME -> prints count of entries
map_size() {
    local -n _map_size_ref="$1"
    printf '%d' "${#_map_size_ref[@]}"
}

# map_each MAPNAME FUNCTION -> calls FUNCTION KEY VALUE for each entry
map_each() {
    local -n _map_each_ref="$1"
    local fn="$2" k
    for k in "${!_map_each_ref[@]}"; do
        "$fn" "$k" "${_map_each_ref[$k]}"
    done
}

# map_merge DST_MAPNAME SRC_MAPNAME -> copies all entries from SRC into DST
map_merge() {
    local -n _map_dst_ref="$1"
    local -n _map_src_ref="$2"
    local k
    for k in "${!_map_src_ref[@]}"; do
        _map_dst_ref["$k"]="${_map_src_ref[$k]}"
    done
}

# map_to_json MAPNAME -> prints a JSON object {"key":"value",...}
map_to_json() {
    local -n _map_json_ref="$1"
    local k first=1 out="{"
    for k in "${!_map_json_ref[@]}"; do
        (( first )) && { first=0; } || out+=","
        out+=$(jq -n --arg k "$k" --arg v "${_map_json_ref[$k]}" '{($k):$v}')
        # Fix: build incrementally with jq
    done
    out+="}"
    # The above is fragile; use jq properly:
    local tmpfile
    tmpfile=$(mktemp)
    for k in "${!_map_json_ref[@]}"; do
        jq -n --arg k "$k" --arg v "${_map_json_ref[$k]}" '{($k):$v}' >> "$tmpfile"
    done
    jq -s 'add // {}' "$tmpfile" 2>/dev/null || printf '{}'
    rm -f "$tmpfile"
}

# map_from_json MAPNAME JSON_STRING -> populates map from JSON object
map_from_json() {
    local -n _map_from_ref="$1"
    local json="$2" k v
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        _map_from_ref["$k"]="$v"
    done < <(printf '%s' "$json" | jq -r 'to_entries[] | "\(.key)\t\(.value|tostring)"' 2>/dev/null)
}

# map_clear MAPNAME -> remove all entries
map_clear() {
    local -n _map_clear_ref="$1"
    unset _map_clear_ref
    declare -gA _map_clear_ref
}

# ─── Nushell-inspired hashmap utilities ───

# map_select MAPNAME KEY1 KEY2... -> new map with only specified keys
map_select() {
    local -n _map_sel_src="$1"; shift
    local -n _map_sel_dst 2>/dev/null
    _map_sel_dst=()
    local k
    for k in "$@"; do
        [[ -v "_map_sel_src[$k]" ]] && _map_sel_dst[$k]="${_map_sel_src[$k]}"
    done
}

# map_reject MAPNAME KEY1 KEY2... -> new map without specified keys
map_reject() {
    local -n _map_rej_src="$1"; shift
    local -n _map_rej_dst 2>/dev/null
    _map_rej_dst=()
    local k skip
    for k in "${!_map_rej_src[@]}"; do
        skip=0
        local rej
        for rej in "$@"; do
            [[ "$k" == "$rej" ]] && { skip=1; break; }
        done
        (( skip )) || _map_rej_dst[$k]="${_map_rej_src[$k]}"
    done
}

# map_to_csv MAPNAME -> CSV (key,value per line)
map_to_csv() {
    local -n _map_csv_ref="$1"
    local k
    for k in "${!_map_csv_ref[@]}"; do
        printf '%s,%s\n' "$k" "${_map_csv_ref[$k]}"
    done
}

# map_invert MAPNAME -> swap keys and values
map_invert() {
    local -n _map_inv_src="$1"
    local -n _map_inv_dst 2>/dev/null
    _map_inv_dst=()
    local k
    for k in "${!_map_inv_src[@]}"; do
        _map_inv_dst[${_map_inv_src[$k]}]="$k"
    done
}

# map_filter MAPNAME FN -> keep only entries where FN(key, value) returns 0
map_filter() {
    local -n _map_filt_src="$1"
    local fn="$2"
    local -n _map_filt_dst 2>/dev/null
    _map_filt_dst=()
    local k
    for k in "${!_map_filt_src[@]}"; do
        if "$fn" "$k" "${_map_filt_src[$k]}"; then
            _map_filt_dst[$k]="${_map_filt_src[$k]}"
        fi
    done
}
