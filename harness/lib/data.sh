# lib/data.sh — Data transformation utilities (nushell-inspired)
# parse_table, fmt_table, fmt_csv, csv_parse, histogram, etc.

# parse_table INPUT -> parse whitespace-aligned text into JSON array of objects
# First line = headers, subsequent lines = data (whitespace-separated)
# Usage: parse_table "$(docker ps)" | jq .
parse_table() {
    local input="$1"
    local tmpfile
    tmpfile=$(path_temp_file yca-table)
    printf '%s\n' "$input" > "$tmpfile"
    # Skip empty lines, use first non-empty as header
    local headers header_line
    header_line=$(grep -v '^[[:space:]]*$' "$tmpfile" | head -1)
    [[ -z "$header_line" ]] && { printf '[]'; rm -f "$tmpfile"; return 0; }
    # Split header by 2+ spaces (common for CLI table output)
    local -a hdrs
    read -ra hdrs <<< "$(printf '%s' "$header_line" | sed 's/  */ /g')"
    # Emit each data row as JSON object
    local first=1 row
    printf '['
    tail -n +2 "$tmpfile" | grep -v '^[[:space:]]*$' | while IFS= read -r row; do
        [[ -z "$row" ]] && continue
        local -a vals
        read -ra vals <<< "$(printf '%s' "$row" | sed 's/  */ /g')"
        local jobj="{" first2=1 i
        for i in "${!hdrs[@]}"; do
            local h="${hdrs[$i]}" v="${vals[$i]:-}"
            h=$(str_lower "$h" | tr ' ' '_')
            (( first2 )) || jobj+=","
            first2=0
            jobj+=$(jq -n --arg k "$h" --arg v "$v" '{($k):$v}')
        done
        jobj+="}"
        printf '%s' "$jobj"
    done
    printf ']'
    rm -f "$tmpfile"
}

# fmt_table JSON_ARRAY -> pretty-print array of objects as aligned table
# Usage: echo '[{"name":"a","size":"10"},{"name":"bb","size":"2"}]' | fmt_table
fmt_table() {
    local input="$1"
    printf '%s' "$input" | jq -r '
        def fmtrow(rows):
            if (rows | length) == 0 then "" else
                (rows | map(. | tostring) | join("  |  "))
            end;
        (.[0] | keys) as $keys |
        ($keys | map(. | ascii_upcase) | join("  |  ")) as $header |
        $header,
        ($header | length | "-" * .),
        (.[] | fmtrow([.[$keys[]]]))
    ' 2>/dev/null
}

# fmt_csv JSON_ARRAY -> CSV output
fmt_csv() {
    local input="$1"
    printf '%s' "$input" | jq -r '
        (.[0] | keys_unsorted) as $keys |
        ($keys | map(.) | join(",")),
        (.[] | [ .[$keys[]] | tostring ] | join(","))
    ' 2>/dev/null
}

# fmt_tsv JSON_ARRAY -> TSV output
fmt_tsv() {
    local input="$1"
    printf '%s' "$input" | jq -r '
        (.[0] | keys_unsorted) as $keys |
        ($keys | map(.) | join("\t")),
        (.[] | [ .[$keys[]] | tostring ] | join("\t"))
    ' 2>/dev/null
}

# csv_parse FILE -> JSON array of objects (first row = headers)
csv_parse() {
    local file="$1"
    [[ -f "$file" ]] || { printf '[]'; return 1; }
    # Pure bash CSV parse (handles quoted fields naively)
    local tmpfile
    tmpfile=$(path_temp_file yca-csv)
    # Use awk for CSV parsing (handles quotes)
    awk -F',' '
    NR==1 { for(i=1;i<=NF;i++) gsub(/^[ \t"]+|[ \t"]+$/,"",$i); n=NF; for(i=1;i<=n;i++) hdr[i]=$i; next }
    { printf "{"; for(i=1;i<=n;i++){ gsub(/^[ \t"]+|[ \t"]+$/,"",$i); printf "\"%s\":\"%s\"",hdr[i],$i; if(i<n)printf ","} printf "}" }
    ' "$file" > "$tmpfile" 2>/dev/null
    local first=1
    printf '['
    if [[ -s "$tmpfile" ]]; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            (( first )) || printf ','
            first=0
            printf '%s' "$line"
        done < "$tmpfile"
    fi
    printf ']'
    rm -f "$tmpfile"
}

# csv_emit ROWS... -> CSV from positional args (first = headers)
csv_emit() {
    local headers="$1"; shift
    printf '%s\n' "$headers"
    local row
    for row in "$@"; do
        printf '%s\n' "$row"
    done
}

# histogram ARRAY_NAME -> frequency count (key\tcount per line)
# Usage: declare -a data=(a b a c a b); histogram data
histogram() {
    local -n _hist_ref="$1"
    declare -A counts
    local item
    for item in "${_hist_ref[@]}"; do
        counts[$item]=$(( ${counts[$item]:-0} + 1 ))
    done
    local k
    for k in "${!counts[@]}"; do
        printf '%s\t%d\n' "$k" "${counts[$k]}"
    done | sort -t$'\t' -k2 -rn
}

# describe VAR_NAME -> prints type and size (nushell-style)
describe() {
    local name="$1"
    local -n _desc_ref="$name" 2>/dev/null || { printf 'unknown\n'; return 1; }
    local t
    t=$(declare -p "$name" 2>/dev/null | head -1 | awk '{print $2}')
    case "$t" in
        *A*) printf 'hashmap (%d entries)\n' "${#_desc_ref[@]}" ;;
        *a*) printf 'array (%d elements)\n' "${#_desc_ref[@]}" ;;
        *)   printf 'string (%d chars): %s\n' "${#_desc_ref}" "$_desc_ref" ;;
    esac
}

# json_to_yaml JSON -> naive YAML (requires yq or python)
json_to_yaml() {
    if command -v yq &>/dev/null; then
        printf '%s' "$1" | yq -y '.' 2>/dev/null
    else
        printf '# yq required for YAML conversion\n' >&2
        printf '%s' "$1"
    fi
}

# yaml_to_json YAML -> JSON (requires yq)
yaml_to_json() {
    if command -v yq &>/dev/null; then
        yq -j '.' "$1" 2>/dev/null || printf '{}'
    else
        printf '# yq required for YAML parsing\n' >&2
        printf '{}'
    fi
}
