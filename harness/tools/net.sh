# tools/net.sh — Network tools

tool_net_dns_lookup()   { local h; h=$(shell_arg_safe "$(tool_arg domain "${1:-}")") || { printf 'invalid domain'; return 1; }; dig +short "$h" 2>/dev/null || nslookup "$h" 2>/dev/null; }
tool_net_traceroute() { local h; h=$(shell_arg_safe "$(tool_arg target "${1:-}")") || { printf 'invalid target'; return 1; }; command -v mtr &>/dev/null && mtr --report -c 5 "$h" || traceroute "$h"; }
# net_port_scan: validate the target (no metachars/leading-dash → no nmap option
# injection like `-oG/tmp/out`), int-guard the port, and refuse wide targets
# (CIDR/wildcard/list) that would scan hosts you may not own.
tool_net_port_scan() {
    local t p
    t=$(shell_arg_safe "$(tool_arg target "${1:-}")") || { printf 'invalid target (unsafe characters or leading dash)'; return 1; }
    case "$t" in *[/,\*]*) printf 'refused: scan a single explicit host (no CIDR/wildcard/list)'; return 1 ;; esac
    p=$(int_guard "$(tool_arg port 80)" 80)
    command -v nmap &>/dev/null || { printf 'install nmap'; return 1; }
    nmap -p "$p" -- "$t" 2>&1
}
tool_net_listening_ports()  { proc_listening_ports; }
tool_net_free_port(){
    local p
    p=$(proc_find_free_port "${1:-8000}" "${2:-9000}") && printf '%s' "$p" || printf 'no free port'
}

tool_net_http_headers() {
    local u; u=$(sanitize_url "${1:?}") || { printf 'invalid url (http/https only)'; return 1; }
    curl_web -IL --max-time 10 "$u" 2>&1
}

# net_fetch — download a URL to a FENCED file (an image, a video, any binary).
# The gap this fills: `browse` returns text-stripped HTML (256 KiB) and `ytdl` is
# for media SITES — neither fetches an arbitrary file to disk. This is the
# SSRF-safe equivalent of `curl -o`: the host is vetted (sanitize + lexical block
# + resolve-and-vet, reusing browse's trio) and curl is PINNED to the vetted IPs
# (DNS-rebinding TOCTOU closed); the protocol is pinned on request AND redirect;
# the response is size-capped (100 MiB) and confined to an in-tree path (default
# downloads/<name>). Consent-gated (writes), never clobbers silently.
tool_net_fetch() {
    local raw url host out
    raw=$(tool_arg url "${1:-}"); [[ -n "$raw" ]] || { printf 'url required (.url)'; return 1; }
    url=$(sanitize_url "$raw") || { printf 'invalid or unsafe url (http/https only, no shell metacharacters)'; return 1; }
    host=$(_browse_url_host "$url")
    _browse_blocked_host "$host" && { printf 'refusing to fetch an internal/loopback/metadata host'; return 1; }
    local ip; local -a pin=()
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        _browse_ip_internal "$ip" && { printf 'refusing: host resolves to an internal/loopback/metadata address (SSRF)'; return 1; }
        pin+=(--resolve "$host:80:$ip" --resolve "$host:443:$ip")
    done < <(_browse_resolve "$host")
    out=$(tool_arg out '')
    if [[ -z "$out" ]]; then
        local base="${url##*/}"; base="${base%%\?*}"; base="${base%%#*}"
        base=$(printf '%s' "$base" | tr -c 'A-Za-z0-9._-' '_')
        [[ -z "$base" || "$base" != *.* ]] && base="download_$(now_stamp)"
        out="${YCA_PROJECT_DIR}/downloads/$base"
    fi
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed (must be inside the project): %s' "$out"; return 1; }
    # Ensure the PARENT dir only when out actually has one — path_dirname (`${1%/*}`)
    # returns a bare filename UNCHANGED, so ensuring it would create the target
    # itself as a directory and curl -o would then fail to write the file.
    local odir; odir=$(path_dirname "$out")
    [[ -n "$odir" && "$odir" != "$out" ]] && path_ensure_dir "$odir" 2>/dev/null
    [[ -e "$out" ]] && { confirm_action "Overwrite existing file: $out" "overwrite $out" || { printf 'refusing to overwrite (pass a different .out): %s' "$out"; return 1; }; }
    confirm_action "Download $url -> $out" "curl -> $out (<=100MiB)" || { confirm_denied_msg; return 1; }
    if curl_web --max-time 60 -L --max-filesize 104857600 ${pin[@]+"${pin[@]}"} -o "$out" "$url" 2>/dev/null && [[ -s "$out" ]]; then
        printf 'downloaded: %s (%s bytes)' "$out" "$(path_size "$out")"
    else
        rm -f "$out" 2>/dev/null
        printf 'download failed (unreachable, larger than 100 MiB, or empty response): %s' "$url"; return 1
    fi
}
tool_net_tls_cert() {
    command -v openssl &>/dev/null || { printf 'openssl missing'; return 127; }
    local h p cert
    h=$(shell_arg_safe "${1:?}") || { printf 'invalid host'; return 1; }
    p=$(int_guard "${2:-443}" 443)
    cert=$(printf '' | timeout 10 openssl s_client -connect "$h:$p" -servername "$h" 2>/dev/null | openssl x509 2>/dev/null)
    [[ -z "$cert" ]] && { printf 'no certificate from %s:%s' "$h" "$p"; return 1; }
    printf '%s' "$cert" | openssl x509 -noout -subject -issuer -dates -fingerprint -sha256 2>&1
    if printf '%s' "$cert" | openssl x509 -noout -checkend 2592000 &>/dev/null; then
        printf 'expiry: OK (>30 days left)\n'
    else
        printf 'expiry: WARNING — expires within 30 days (or already expired)\n'
    fi
}
tool_net_port_check() {
    local h p
    h=$(shell_arg_safe "${1:?}") || { printf 'invalid host'; return 1; }
    p=$(int_guard "${2:-80}" 80)
    if command -v nc &>/dev/null; then
        nc -z -w 5 "$h" "$p" 2>&1 && printf '%s:%s open' "$h" "$p" || { printf '%s:%s closed/unreachable' "$h" "$p"; return 1; }
    else
        timeout 5 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null && printf '%s:%s open' "$h" "$p" || { printf '%s:%s closed/unreachable' "$h" "$p"; return 1; }
    fi
}
tool_register "net_dns_lookup"       tool_net_dns_lookup       '{"type":"object","properties":{"domain":{"type":"string","description":"the domain"}},"required":["domain"]}' safe all net
tool_register "net_traceroute"     tool_net_traceroute     '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all net
tool_register "net_port_scan"      tool_net_port_scan      '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"port":{"type":"integer","description":"port number"}},"required":["target"]}' safe all net
tool_register "net_listening_ports"   tool_net_listening_ports   '{"type":"object","properties":{}}' safe all net
tool_register "net_free_port" tool_net_free_port '{"type":"object","properties":{"start":{"type":"integer","description":"the start position or time"},"end":{"type":"integer","description":"the end"}}}' safe all net
tool_register "net_http_headers" tool_net_http_headers '{"type":"object","properties":{"url":{"type":"string","description":"the URL to fetch"}},"required":["url"]}' safe all net
tool_register "net_fetch"        tool_net_fetch        '{"description":"Download a URL to a fenced file (SSRF-vetted, size-capped) — an image, video, or any binary","type":"object","properties":{"url":{"type":"string","description":"the http(s) URL to download"},"out":{"type":"string","description":"in-tree output path (default: downloads/<name>)"}},"required":["url"]}' writes all net
tool_register "net_tls_cert"   tool_net_tls_cert   '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"port":{"type":"integer","description":"port number"}},"required":["host"]}' safe all net
tool_register "net_port_check" tool_net_port_check '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"port":{"type":"integer","description":"port number"}},"required":["host"]}' safe all net
