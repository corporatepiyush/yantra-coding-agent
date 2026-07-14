# lib/http.sh — HTTP utilities (curl wrappers with retry)
# Inspired by nushell's `http get`/`http post`/`fetch`

# Some sites 403 curl's default User-Agent; a stable identifying UA is both
# polite and more compatible.
YCA_CURL_UA="${HARNESS_CURL_UA:-yantra-coding-agent/3.0 (+https://github.com/corporatepiyush/yantra-coding-agent)}"

# curl_web [ARGS...] — the shared base for every web-facing curl in the harness.
# Security: --proto/--proto-redir pin http(s) so a redirect can never downgrade
#   to file:// ftp:// gopher:// etc.
# Compatibility: --compressed negotiates gzip/br (many CDNs require it or send
#   it anyway), -A sets a real UA.
# Robustness: --connect-timeout fails fast on dead hosts instead of eating the
#   whole --max-time; --max-redirs bounds redirect chains wherever -L is used.
curl_web() {
    curl -sS --proto '=http,https' --proto-redir '=http,https' \
        --connect-timeout 10 --max-redirs 5 --compressed -A "$YCA_CURL_UA" "$@"
}

# Bodies slurped into shell variables are capped: --max-filesize rejects
# oversized responses that declare Content-Length up front (chunked responses
# are bounded by --max-time instead). 16 MiB default.
YCA_HTTP_MAX_BODY="${HARNESS_HTTP_MAX_BODY:-16777216}"

# http_get URL [HEADERS...] -> prints response body
# The bearer token is passed via a header FILE (-H @<(...)), never on the curl
# command line: argv is world-readable through `ps`, so an inline
# Authorization header would leak the token to every local process.
http_get() {
    local url="$1"; shift
    local args=(--fail-with-body --max-time 30 --retry 2 --retry-connrefused -L --max-filesize "$YCA_HTTP_MAX_BODY")
    while [[ $# -gt 0 ]]; do
        args+=(-H "$1"); shift
    done
    args+=("$url")
    if [[ -n "$YCA_API_TOKEN" ]]; then
        curl_web "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$YCA_API_TOKEN") 2>/dev/null
    else
        curl_web "${args[@]}" 2>/dev/null
    fi
}

# http_post URL BODY [CONTENT_TYPE] [HEADERS...]
# The body streams over stdin (--data-binary @-) so a large payload never
# lands on argv (ARG_MAX) and is written with curl's own buffering.
http_post() {
    local url="$1" body="$2" ct="${3:-application/json}"; shift 3
    local args=(--fail-with-body --max-time 30 --retry 2 -X POST -H "Content-Type: $ct")
    while [[ $# -gt 0 ]]; do
        args+=(-H "$1"); shift
    done
    args+=(--data-binary @- "$url")
    if [[ -n "$YCA_API_TOKEN" ]]; then
        # Token via header file — see http_get.
        printf '%s' "$body" | curl_web "${args[@]}" -H @<(printf 'Authorization: Bearer %s\n' "$YCA_API_TOKEN") 2>/dev/null
    else
        printf '%s' "$body" | curl_web "${args[@]}" 2>/dev/null
    fi
}

# http_post_json URL JSON_BODY [HEADERS...]
http_post_json() {
    local url="$1" body="$2"; shift 2
    http_post "$url" "$body" "application/json" "$@"
}

# http_put URL BODY [CONTENT_TYPE]
http_put() {
    local url="$1" body="$2" ct="${3:-application/octet-stream}"
    if [[ -n "$YCA_API_TOKEN" ]]; then
        # Token via header file — see http_get.
        printf '%s' "$body" | curl_web --fail-with-body --max-time 30 --retry 2 -X PUT \
            -H "Content-Type: $ct" \
            -H @<(printf 'Authorization: Bearer %s\n' "$YCA_API_TOKEN") \
            --data-binary @- "$url" 2>/dev/null
    else
        printf '%s' "$body" | curl_web --fail-with-body --max-time 30 --retry 2 -X PUT \
            -H "Content-Type: $ct" \
            --data-binary @- "$url" 2>/dev/null
    fi
}

# http_delete URL
http_delete() {
    if [[ -n "$YCA_API_TOKEN" ]]; then
        # Token via header file — see http_get.
        curl_web --fail-with-body --max-time 30 --retry 2 -X DELETE \
            -H @<(printf 'Authorization: Bearer %s\n' "$YCA_API_TOKEN") \
            "$1" 2>/dev/null
    else
        curl_web --fail-with-body --max-time 30 --retry 2 -X DELETE \
            "$1" 2>/dev/null
    fi
}

# http_head URL -> prints headers
http_head() {
    curl_web --max-time 15 -I -L "$1" 2>/dev/null
}

# http_download URL FILE -> download to file (streaming to disk, no slurp).
# --speed-limit/--speed-time abort a stalled transfer (<1 KiB/s for 30s)
# instead of holding the connection until --max-time.
http_download() {
    local url="$1" file="$2"
    path_ensure_dir "$(dirname "$file")"
    curl_web --fail-with-body --max-time 300 --retry 2 --retry-connrefused \
        --speed-limit 1024 --speed-time 30 -L -o "$file" "$url" 2>/dev/null
}

# http_status URL -> HTTP status code
http_status() {
    curl_web --max-time 10 -o /dev/null -w '%{http_code}' -L "$1" 2>/dev/null
}

# http_fetch URL -> prints body (alias for http_get, nushell-style)
http_fetch() { http_get "$@"; }

# url_parse URL -> prints "scheme host port path query"
url_parse() {
    local url="$1"
    local scheme host port path query
    scheme="${url%%://*}"
    local rest="${url#*://}"
    # Split host:port/path?query
    if [[ "$rest" == */* ]]; then
        local hostport="${rest%%/*}"
        path="/${rest#*/}"
    else
        hostport="$rest"
        path=""
    fi
    query=""
    if [[ "$path" == *\?* ]]; then
        query="${path#*\?}"
        path="${path%%\?*}"
    fi
    if [[ "$hostport" == *:* ]]; then
        host="${hostport%%:*}"
        port="${hostport##*:}"
    else
        host="$hostport"
        port=""
    fi
    [[ -z "$port" ]] && case "$scheme" in
        http) port=80 ;; https) port=443 ;;
    esac
    printf '%s %s %s %s %s' "$scheme" "$host" "$port" "$path" "$query"
}

# url_join BASE RELATIVE -> joined URL
url_join() {
    local base="$1" rel="$2"
    if [[ "$rel" == http* ]]; then printf '%s' "$rel"; return; fi
    if [[ "$rel" == /* ]]; then
        local scheme host
        scheme="${base%%://*}"
        local rest="${base#*://}"
        host="${rest%%/*}"
        printf '%s://%s%s' "$scheme" "$host" "$rel"
    else
        printf '%s/%s' "${base%/}" "$rel"
    fi
}

# url_encode STRING -> percent-encode
url_encode() {
    local s="$1" out=""
    local i c
    for ((i=0; i<${#s}; i++)); do
        c="${s:i:1}"
        case "$c" in
            [a-zA-Z0-9.~_-]) out+="$c" ;;
            *) printf -v hex '%%%02X' "'$c"
              out+="$hex" ;;
        esac
    done
    printf '%s' "$out"
}

# url_decode STRING -> percent-decode
url_decode() {
    local s="$1"
    printf '%b' "${s//%/\\x}"
}
