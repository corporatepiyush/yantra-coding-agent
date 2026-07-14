# lib/07-json.sh — JSON utilities (jq wrappers)
# All JSON is built with jq. Never hand-build JSON.

# json_str STRING -> prints a JSON string (safely quoted)
json_str() {
    jq -Rn --arg s "$1" '$s'
}

# json_num NUMBER -> prints a JSON number
json_num() {
    if math_is_number "$1"; then
        printf '%s' "$1"
    else
        printf '0'
    fi
}

# json_bool VALUE -> prints true or false
json_bool() {
    if [[ "$1" == "true" || "$1" == "1" || "$1" == "yes" ]]; then printf 'true'
    else printf 'false'
    fi
}

# json_obj KEY1 VAL1 KEY2 VAL2 ... -> prints JSON object
# Values are treated as strings unless they look like bool/num/null
json_obj() {
    local tmpfile
    tmpfile=$(mktemp)
    while [[ $# -ge 2 ]]; do
        local k="$1" v="$2"; shift 2
        local jval
        case "$v" in
            true|false|null) jval="$v" ;;
            -[0-9]*|[0-9]*) math_is_number "$v" && jval="$v" || jval=$(json_str "$v") ;;
            *) jval=$(json_str "$v") ;;
        esac
        jq -n --arg k "$k" --argjson v "$jval" '{($k):$v}' >> "$tmpfile"
    done
    jq -s 'add // {}' "$tmpfile" 2>/dev/null || printf '{}'
    rm -f "$tmpfile"
}

# json_arr ELEMENT... -> prints JSON array (elements are strings)
json_arr() {
    if [[ $# -eq 0 ]]; then printf '[]'; return; fi
    local tmpfile
    tmpfile=$(mktemp)
    local item
    for item in "$@"; do
        jq -Rn --arg s "$item" '$s' >> "$tmpfile"
    done
    jq -s '.' "$tmpfile" 2>/dev/null || printf '[]'
    rm -f "$tmpfile"
}

# json_get JSON_STRING KEY -> prints value at KEY (top-level)
json_get() {
    printf '%s' "$1" | jq -r --arg k "$2" '.[$k] // empty' 2>/dev/null
}

# json_get_path JSON_STRING JQ_PATH -> prints value at jq path (e.g. .a.b[0])
json_get_path() {
    printf '%s' "$1" | jq -r "$2 // empty" 2>/dev/null
}

# json_set JSON_STRING KEY VALUE -> prints new JSON with KEY=VALUE
json_set() {
    local json="$1" k="$2" v="$3"
    local jval
    case "$v" in
        true|false|null) jval="$v" ;;
        -[0-9]*|[0-9]*) math_is_number "$v" && jval="$v" || jval=$(json_str "$v") ;;
        *) jval=$(json_str "$v") ;;
    esac
    printf '%s' "$json" | jq --arg k "$k" --argjson v "$jval" '.[$k]=$v' 2>/dev/null
}

# json_append JSON_STRING VALUE -> appends VALUE to JSON array
json_append() {
    printf '%s' "$1" | jq --arg v "$2" '. + [$v]' 2>/dev/null
}

# json_pretty JSON_STRING -> indented JSON
json_pretty() {
    printf '%s' "$1" | jq '.' 2>/dev/null
}

# json_valid STRING -> 0 if valid JSON
json_valid() {
    printf '%s' "$1" | jq -e . &>/dev/null
}

# json_compact JSON_STRING -> minified JSON
json_compact() {
    printf '%s' "$1" | jq -c '.' 2>/dev/null
}

# json_merge A B -> deep merge two JSON objects
json_merge() {
    jq -s '.[0] * .[1]' < <(printf '%s\n%s' "$1" "$2") 2>/dev/null
}

# json_from_file FILE -> prints parsed JSON
json_from_file() {
    [[ -f "$1" ]] || { printf '{}'; return 1; }
    jq '.' "$1" 2>/dev/null || cat "$1"
}

# json_keys JSON_OBJECT -> prints keys (one per line)
json_keys() {
    printf '%s' "$1" | jq -r 'keys[]?' 2>/dev/null
}

# json_length JSON -> number of elements (array) or keys (object)
json_length() {
    printf '%s' "$1" | jq 'length' 2>/dev/null
}
