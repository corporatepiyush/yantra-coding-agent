# lib/02-strings.sh — String manipulation utilities
# Pure bash, no external commands. Uses parameter expansion.

# str_contains HAYSTACK NEEDLE -> 0 if found
str_contains() {
    [[ -z "$2" ]] && return 0
    [[ "$1" == *"$2"* ]]
}

# str_starts_with HAYSTACK PREFIX
str_starts_with() {
    [[ "$1" == "$2"* ]]
}

# str_ends_with HAYSTACK SUFFIX
str_ends_with() {
    [[ "$1" == *"$2" ]]
}

# str_trim STRING -> prints trimmed string
str_trim() {
    local s="$1"
    # leading
    s="${s#"${s%%[![:space:]]*}"}"
    # trailing
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# str_lower STRING
str_lower() { printf '%s' "${1,,}"; }

# str_upper STRING
str_upper() { printf '%s' "${1^^}"; }

# str_capitalize STRING (first char upper) — ${1^} uppercases only the first char.
# (The old ${1:0:1^^} was invalid — the ^^ was parsed as an arithmetic length.)
str_capitalize() { printf '%s' "${1^}"; }

# str_len STRING
str_len() {
    printf '%d' "${#1}"
}

# str_replace OLD NEW STRING (first occurrence only)
str_replace() {
    local old="$1" new="$2" s="$3"
    printf '%s' "${s/"$old"/"$new"}"
}

# str_replace_all OLD NEW STRING
str_replace_all() {
    local old="$1" new="$2" s="$3"
    printf '%s' "${s//"$old"/"$new"}"
}

# str_repeat N STRING
str_repeat() {
    local n="$1" s="$2"
    if (( n <= 0 )); then return 0; fi
    local out=""
    local i
    for ((i=0; i<n; i++)); do out+="$s"; done
    printf '%s' "$out"
}

# str_split DELIM STRING -> prints lines (pipe to mapfile)
# Usage: mapfile -t arr < <(str_split ',' "a,b,c")
str_split() {
    local delim="$1" s="$2"
    if [[ -z "$delim" ]]; then
        # char-by-char
        local i
        for ((i=0; i<${#s}; i++)); do printf '%s\n' "${s:i:1}"; done
        return
    fi
    local part
    while [[ "$s" == *"$delim"* ]]; do
        part="${s%%"$delim"*}"
        printf '%s\n' "$part"
        s="${s#*"$delim"}"
    done
    printf '%s\n' "$s"
}

# str_join DELIM array... -> prints joined string
# Usage: str_join ',' "${arr[@]}"
str_join() {
    local delim="$1"; shift
    local out="$1"; shift
    local item
    for item in "$@"; do out+="$delim$item"; done
    printf '%s' "$out"
}

# str_escape_regex STRING -> escape regex metacharacters for ERE
str_escape_regex() {
    printf '%s' "${1//[\\.^$\[\](){}*+?|]/\\&}"
}

# str_escape_sed STRING -> escape for sed BRE replacement
str_escape_sed() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\//\\/}"
    s="${s//&/\\&}"
    s="${s//\[/\\[}"
    s="${s//\]/\\]}"
    s="${s//\./\\.}"
    s="${s//\*/\\*}"
    s="${s//\^/\\^}"
    s="${s//\$/\\\$}"
    printf '%s' "$s"
}

# str_redact STRING SECRET -> replace SECRET with ***REDACTED***
str_redact() {
    local s="$1" secret="$2"
    [[ -z "$secret" ]] && { printf '%s' "$s"; return; }
    printf '%s' "${s//"$secret"/\*\*\*REDACTED\*\*\*}"
}

# str_quote_safe STRING -> wrap in single quotes, escaping internal quotes
# For embedding in shell command strings
str_quote_safe() {
    local s="$1"
    printf "'%s'" "${s//\'/\'\\\'\'}"
}

# str_truncate STRING MAXLEN [SUFFIX]
str_truncate() {
    local s="$1" maxlen="$2" suffix="${3:-...}"
    if (( ${#s} <= maxlen )); then
        printf '%s' "$s"
    else
        local cut=$(( maxlen - ${#suffix} ))
        (( cut < 0 )) && cut=0
        printf '%s%s' "${s:0:cut}" "$suffix"
    fi
}

# str_indent STRING SPACES -> indent each line
str_indent() {
    local s="$1" n="$2" indent=""
    indent=$(str_repeat "$n" " ")
    local line
    while IFS= read -r line; do
        printf '%s%s\n' "$indent" "$line"
    done <<< "$s"
}
