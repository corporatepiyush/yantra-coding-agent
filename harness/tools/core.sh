# tools/core.sh — The default tool calls (always enabled)
# read, write, edit, bash, browse + batch. These are the ONLY tools enabled by
# default; all others are opt-in via `tools enable <category>`.

# tool_read PATH -> prints file contents
tool_read() {
    local path="$1"
    [[ -z "$path" ]] && { printf 'path required'; return 1; }
    # Confine reads to the project directory, like write/edit/bash. Without this,
    # the LLM (or a tl: call) could read any file on the host, e.g. /etc/passwd.
    path_check_allowed "$path" || { printf 'path not allowed: %s' "$path"; return 1; }
    [[ -f "$path" ]] || { printf 'file not found: %s' "$path"; return 1; }
    if io_is_binary "$path"; then
        printf 'binary file: %s (%s bytes)' "$path" "$(path_size "$path")"
    else
        cat "$path"
    fi
}

# tool_write PATH CONTENT
tool_write() {
    local path="$1" content="$2"
    path_check_allowed "$path" || { printf 'path not allowed'; return 1; }
    confirm_action "Write file: $path" "printf '%%s' '<content>' > '$path'" || { confirm_denied_msg; return 1; }
    path_ensure_dir "$(dirname "$path")"
    printf '%s' "$content" > "$path"
    db_exec "INSERT INTO changes(file_path, change_type, summary) VALUES ($(sql_quote "$path"), 'write', 'created file');" 2>/dev/null || true
    printf 'wrote %s' "$path"
}

# tool_edit PATH NEW_STRING OLD_STRING [REPLACE_ALL]
# Literal (non-regex) string replacement. Default replaces the FIRST occurrence
# only; replace_all=true replaces every occurrence. Done in-memory with bash
# parameter expansion so both semantics are correct and the match/replacement are
# treated literally (the old sd/sed path replaced ALL even when first-only was
# asked, and needed brittle regex escaping).
tool_edit() {
    local path="$1" new_str="$2" old_str="$3" replace_all
    # replace_all must be read from the raw args JSON: the generic positional
    # dispatcher gives .old_string priority over .replace_all in the same slot,
    # so a positional $4 never carries it (it would always be false otherwise).
    replace_all=$(tool_arg replace_all "${4:-false}")
    path_check_allowed "$path" || { printf 'path not allowed'; return 1; }
    [[ -f "$path" ]] || { printf 'file not found'; return 1; }
    grep -qF -- "$old_str" "$path" 2>/dev/null || { printf 'old_string not found'; return 1; }
    confirm_action "Edit file: $path" "replace in $path" || { confirm_denied_msg; return 1; }
    # Read the whole file exactly, trailing newlines included. `read -d ''` reads
    # up to a NUL (absent in text) so it captures everything; a plain $(<file)
    # would strip trailing newlines. It returns non-zero at EOF — expected.
    local content
    IFS= read -r -d '' content < "$path" || true
    # Quoting the search string makes bash treat it literally (no glob/pattern
    # interpretation); a single `/` replaces the first match, `//` replaces all.
    if [[ "$replace_all" == "true" ]]; then
        content="${content//"$old_str"/"$new_str"}"
    else
        content="${content/"$old_str"/"$new_str"}"
    fi
    printf '%s' "$content" > "$path"
    db_exec "INSERT INTO changes(file_path, change_type, summary) VALUES ($(sql_quote "$path"), 'edit', 'edited');" 2>/dev/null || true
    printf 'edited %s' "$path"
}

# tool_bash COMMAND [TIMEOUT]
tool_bash() {
    local command="$1" timeout="${2:-$YCA_LLM_TIMEOUT}"
    [[ -z "$command" ]] && { printf 'command required'; return 1; }
    path_check_allowed "$PWD" || { printf 'cwd not allowed'; return 1; }
    confirm_action "Run bash" "$command" || { confirm_denied_msg; return 1; }
    local out rc
    out=$(timeout "$timeout" bash -c "$command" 2>&1) && rc=0 || rc=$?
    log_bash_exec "$command" "$rc"
    printf '%s' "$out"
}

# _browse_url_host URL -> the host portion (no scheme/userinfo/port/path), or empty.
_browse_url_host() {
    local u="$1"
    u="${u#*://}"        # strip scheme
    u="${u%%/*}"         # strip path
    u="${u%%\?*}"        # strip query (when there is no path)
    u="${u##*@}"         # strip userinfo
    if [[ "$u" == \[*\]* ]]; then u="${u#\[}"; u="${u%%\]*}"   # IPv6 literal
    else u="${u%%:*}"; fi                                       # strip :port
    printf '%s' "$u"
}

# _browse_blocked_host HOST -> 0 if HOST is loopback / link-local / private / a
# cloud metadata endpoint. Blocks the common SSRF targets so `browse` can't be
# turned into a request forger against internal services (169.254.169.254, etc).
_browse_blocked_host() {
    local h; h=$(str_lower "$1")
    case "$h" in
        ""|localhost|localhost.*|*.localhost) return 0 ;;
        0.0.0.0|127.*|::1|fe80:*|fc00:*|fd00:*) return 0 ;;
        10.*|192.168.*|169.254.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        metadata|metadata.google.internal) return 0 ;;
    esac
    return 1
}

# _browse_resolve HOST -> print HOST's resolved IPs, one per line (IPv4-mapped
# IPv6 unwrapped). Empty when no resolver is available or resolution fails.
_browse_resolve() {
    local host="$1"
    if command -v python3 &>/dev/null; then
        python3 - "$host" <<'PY' 2>/dev/null
import socket, sys
seen = set()
try:
    for r in socket.getaddrinfo(sys.argv[1], None):
        ip = r[4][0]
        if ip not in seen:
            seen.add(ip); print(ip)
except Exception:
    pass
PY
    elif command -v dig &>/dev/null; then
        { dig +short "$host" A 2>/dev/null; dig +short "$host" AAAA 2>/dev/null; }
    fi | sed 's/^::ffff://'
}

# _browse_ip_internal IP -> 0 if IP is loopback / private / link-local / metadata.
# The single place both the pre-flight check AND the pinned connect agree on, so
# a public-looking name that resolves to 169.254.169.254 is blocked either way.
_browse_ip_internal() {
    case "${1#::ffff:}" in
        ""|127.*|0.0.0.0|::1|::|fe80:*|fc00:*|fd00:*|metadata*) return 0 ;;
        10.*|192.168.*|169.254.*) return 0 ;;
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
    esac
    return 1
}

# _html_to_text — HTML on stdin -> readable text. Prefer pandoc (properly drops
# <script>/<style>, decodes entities); otherwise fall back to dropping obvious
# script/style blocks line-wise, then a slurp-mode tag strip (multi-line safe)
# and common-entity decode. Much cleaner than a bare tag strip, which leaves
# inline JS/CSS that swamps small models trying to summarize a page.
_html_to_text() {
    if command -v pandoc &>/dev/null; then
        pandoc -f html -t plain --wrap=none 2>/dev/null
    else
        sed -E '/<script/,/<\/script>/d; /<style/,/<\/style>/d' \
        | sed ':a;N;$!ba; s/<[^>]*>//g' \
        | sed 's/&nbsp;/ /g; s/&amp;/\&/g; s/&lt;/</g; s/&gt;/>/g; s/&quot;/"/g; s/&#0*39;/'"'"'/g'
    fi
}

# _browse_fetch URL [ACCEPT] — the SSRF-vetted, protocol-pinned, size-capped HTTP
# fetch CORE shared by the `browse` tool (strips tags to text) and the
# doc.save_article workflow (wants the raw HTML for pandoc). On success it prints
# the raw response body (capped at 256 KiB) and returns 0; on a guard failure it
# prints the refusal message and returns 1 — so a caller distinguishes the two by
# exit code (a refusal must NOT be piped through an HTML converter).
_browse_fetch() {
    local url="$1" accept="${2:-text/html,text/plain}"
    command -v curl &>/dev/null || { printf 'curl required'; return 1; }
    url=$(sanitize_url "$url") || { printf 'invalid or unsafe url (http(s) only)'; return 1; }
    local _bhost; _bhost=$(_browse_url_host "$url")
    _browse_blocked_host "$_bhost" \
        && { printf 'refusing to fetch internal/loopback/metadata address'; return 1; }
    # Resolve ONCE, vet every address, then PIN curl to the vetted IPs via
    # --resolve. Without pinning, curl re-resolves the name independently, so a
    # DNS-rebinding server can answer the check with a public IP and answer
    # curl's lookup a moment later with 169.254.169.254 (SSRF TOCTOU). Pinning
    # forces curl to connect only to the addresses we validated. No resolver
    # (returns nothing) → the lexical block above stays the floor.
    local -a _ips=() _pin=(); local _ip
    mapfile -t _ips < <(_browse_resolve "$_bhost")
    for _ip in ${_ips[@]+"${_ips[@]}"}; do
        [[ -z "$_ip" ]] && continue
        _browse_ip_internal "$_ip" \
            && { printf 'refusing to fetch: host resolves to an internal/loopback/metadata address (SSRF)'; return 1; }
        _pin+=(--resolve "$_bhost:80:$_ip" --resolve "$_bhost:443:$_ip")
    done
    # curl_web pins the protocol on the initial request AND on any redirect and
    # caps redirects, so a 3xx can't downgrade to file://gopher:// or chase
    # forever; --compressed + a real UA get past CDNs that reject bare curl.
    # head -c bounds the bytes held in the pipe, so a pathological single-line
    # page can't balloon memory past ~256 KiB.
    curl_web --max-time 15 -L --max-filesize 5242880 \
        ${_pin[@]+"${_pin[@]}"} \
        -H "Accept: $accept" "$url" 2>/dev/null | head -c 262144
}

# tool_browse URL — fetch a public http(s) page and extract readable text.
tool_browse() {
    local body; body=$(_browse_fetch "$1") || { printf '%s' "$body"; return 1; }
    printf '%s' "$body" | _html_to_text | grep -vE '^[[:space:]]*$' | head -200
}

# tool_batch — run several tool calls in one turn.
# Input: {"calls":[{"tool":"read","args":{"path":"a"}}, {"tool":"bash","args":{...}}]}
# It is a thin sequential loop over tool_dispatch — no new execution machinery, so
# every per-tool safety gate (category enablement, confirm_action, arg parsing)
# still applies exactly as for a single call. Errors don't abort the batch; each
# result is annotated with its index/tool/rc so the caller can tell them apart.
# Nested batch is rejected to keep it flat and non-recursive. At most 100 calls
# per batch — larger fan-outs are refused rather than truncated.
tool_batch() {
    local calls; calls=$(tool_arg calls)
    [[ -z "$calls" || "$calls" == "null" ]] && { printf 'batch requires .calls (array of {tool,args})'; return 1; }
    local n; n=$(printf '%s' "$calls" | jq 'length' 2>/dev/null || printf 'x')
    [[ "$n" =~ ^[0-9]+$ ]] || { printf 'batch: .calls must be a JSON array'; return 1; }
    (( n == 0 )) && { printf 'batch: no calls'; return 0; }
    (( n > 100 )) && { printf 'batch: too many calls (%d > 100, the batch limit)' "$n"; return 1; }
    local i tool args out rc overall=0
    for (( i=0; i<n; i++ )); do
        tool=$(printf '%s' "$calls" | jq -r ".[$i].tool // empty" 2>/dev/null)
        args=$(printf '%s' "$calls" | jq -c ".[$i].args // {}" 2>/dev/null)
        if [[ -z "$tool" ]]; then printf '[%d] error: missing .tool\n' "$i"; overall=1; continue; fi
        if [[ "$tool" == "batch" ]]; then printf '[%d] error: nested batch not allowed\n' "$i"; overall=1; continue; fi
        out=$(tool_dispatch "$tool" "$args"); rc=$?
        printf '[%d] %s (rc=%d):\n%s\n' "$i" "$tool" "$rc" "$out"
        (( rc != 0 )) && overall=1
    done
    return $overall
}

# Register the core tools (always enabled)
# A top-level "description" in the schema is hoisted to function.description on
# the wire (build_tools_json) — local models pick tools by name alone otherwise.
tool_register "read"   tool_read   '{"description":"Read a file and return its contents","type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}},"required":["path"]}' safe all core
tool_register "write"  tool_write  '{"description":"Create or overwrite a file with the given content (confirmation-gated)","type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"content":{"type":"string","description":"the file content to write"}},"required":["path","content"]}' writes all core
tool_register "edit"   tool_edit   '{"description":"Replace old_string with new_string in a file — first occurrence unless replace_all (confirmation-gated)","type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"},"new_string":{"type":"string","description":"the replacement text"},"old_string":{"type":"string","description":"the exact text to find and replace"},"replace_all":{"type":"boolean","description":"replace every occurrence instead of just the first"}},"required":["path","new_string","old_string"]}' writes all core
tool_register "bash"   tool_bash   '{"description":"Run a shell command in the project directory and return its output (confirmation-gated)","type":"object","properties":{"command":{"type":"string","description":"the shell command to run"},"timeout":{"type":"integer","description":"timeout in seconds"}},"required":["command"]}' writes all core
tool_register "browse" tool_browse '{"description":"Fetch a URL and return the page text","type":"object","properties":{"url":{"type":"string","description":"the URL to fetch"}},"required":["url"]}' safe all core
tool_register "batch"  tool_batch  '{"description":"Run several tool calls in one request: pass calls as [{tool,args},...]","type":"object","properties":{"calls":{"type":"array","items":{"type":"object","properties":{"tool":{"type":"string"},"args":{"type":"object"}},"required":["tool"]},"description":"the calls"}},"required":["calls"]}' writes all core
