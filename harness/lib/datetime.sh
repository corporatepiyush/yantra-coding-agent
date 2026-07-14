# lib/datetime.sh — Date and time utilities.
# These use Bash builtins (printf '%()T', EPOCHSECONDS/EPOCHREALTIME) — no `date`
# fork, and no GNU-vs-BSD `date` flag divergence.

# date_now -> ISO 8601 timestamp (local time + offset)
date_now() {
    printf '%(%Y-%m-%dT%H:%M:%S%z)T\n' -1
}

# date_unix -> unix epoch seconds
date_unix() {
    printf '%s' "$EPOCHSECONDS"
}

# date_unix_ms -> unix epoch milliseconds. EPOCHREALTIME is "secs.micros"; convert
# micros→millis so this returns true milliseconds (the old form returned micros).
date_unix_ms() {
    local rt="$EPOCHREALTIME"
    printf '%s' "$(( ${rt%.*} * 1000 + 10#${rt#*.} / 1000 ))"
}

# date_format FORMAT [TIMESTAMP] -> strftime-format now (or the given epoch).
date_format() {
    local fmt="$1" ts="${2:--1}"
    printf "%(${fmt})T" "$ts"
}

# now_stamp [FORMAT] -> compact current timestamp for filenames (default
# YYYYMMDD_HHMMSS). No fork.
now_stamp() {
    printf "%(${1:-%Y%m%d_%H%M%S})T" -1
}

# date_parse STRING -> unix timestamp (best effort, uses date -d or date -j)
date_parse() {
    local s="$1"
    date -d "$s" +%s 2>/dev/null || date -j -f '%Y-%m-%d' "$s" +%s 2>/dev/null || printf '0'
}

# duration_parse STRING -> seconds (e.g. "1h30m" -> 5400)
duration_parse() {
    local s="$1" total=0
    # Match patterns like 1h, 30m, 45s, 2d
    local num unit
    while [[ "$s" =~ ^([0-9]+)([dhms]) ]]; do
        num="${BASH_REMATCH[1]}"
        unit="${BASH_REMATCH[2]}"
        case "$unit" in
            d) total=$(( total + num * 86400 )) ;;
            h) total=$(( total + num * 3600 )) ;;
            m) total=$(( total + num * 60 )) ;;
            s) total=$(( total + num )) ;;
        esac
        s="${s#"${BASH_REMATCH[0]}"}"
    done
    # If just a number, treat as seconds
    [[ -z "$total" && "$s" =~ ^[0-9]+$ ]] && total="$s"
    printf '%d' "$total"
}

# duration_format SECONDS -> human readable (e.g. "1h 30m 45s")
duration_format() {
    local total="$1"
    local d h m s
    d=$(( total / 86400 )); total=$(( total % 86400 ))
    h=$(( total / 3600 ));  total=$(( total % 3600 ))
    m=$(( total / 60 ));    s=$(( total % 60 ))
    local out=""
    (( d > 0 )) && out+="${d}d "
    (( h > 0 )) && out+="${h}h "
    (( m > 0 )) && out+="${m}m "
    out+="${s}s"
    printf '%s' "$out"
}

# date_diff A B -> seconds between two unix timestamps (absolute)
date_diff() {
    local a="$1" b="$2"
    math_abs $(( a - b ))
}

# date_is_past TIMESTAMP -> 0 if timestamp is in the past
date_is_past() {
    local ts="$1" now
    now=$(date_unix)
    (( ts <= now ))
}

# date_is_future TIMESTAMP -> 0 if timestamp is in the future
date_is_future() {
    local ts="$1" now
    now=$(date_unix)
    (( ts > now ))
}

# date_file_mtime FILE -> ISO timestamp of file modification
date_file_mtime() {
    local f="$1"
    [[ -f "$f" ]] || return 1
    case "$(os_detect)" in
        darwin|freebsd) stat -f '%Sm' -t '%Y-%m-%dT%H:%M:%S' "$f" 2>/dev/null ;;
        linux) stat -c '%y' "$f" 2>/dev/null | cut -d. -f1 ;;
    esac
}

# date_relative TIMESTAMP -> "2 hours ago", "3 days ago", etc.
date_relative() {
    local ts="$1" now diff
    now=$(date_unix)
    diff=$(( now - ts ))
    if (( diff < 60 )); then printf '%ds ago' "$diff"
    elif (( diff < 3600 )); then printf '%dm ago' $(( diff / 60 ))
    elif (( diff < 86400 )); then printf '%dh ago' $(( diff / 3600 ))
    elif (( diff < 604800 )); then printf '%dd ago' $(( diff / 86400 ))
    elif (( diff < 2592000 )); then printf '%dw ago' $(( diff / 604800 ))
    else printf '%dmo ago' $(( diff / 2592000 ))
    fi
}
