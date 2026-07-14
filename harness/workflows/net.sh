# workflows/net.sh — Composed network diagnosis.
# "Is it down or is it me?" as one call: DNS → TCP port → TLS cert → HTTP
# headers, each step reusing the registered net_* tool via tool_invoke (the
# category gate is bypassed — the workflow, not the user's toggles, decides).

wf_net_diagnose() {
    local url="${INPUT_url:-}" host="${INPUT_host:-}" port="${INPUT_port:-}"
    local scheme=""
    if [[ -n "$url" ]]; then
        url=$(sanitize_url "$url") || { emit_error "422" "INPUT_url must be a plain http(s) URL"; return 1; }
        scheme="${url%%://*}"
        host="${url#*://}"; host="${host%%/*}"; host="${host%%\?*}"
        # host[:port] — split an explicit port off before defaulting by scheme.
        if [[ "$host" == *:* ]]; then port="${host##*:}"; host="${host%%:*}"; fi
        [[ -z "$port" ]] && { [[ "$scheme" == "https" ]] && port=443 || port=80; }
    fi
    [[ -z "$host" ]] && { emit_error "422" "INPUT_url or INPUT_host required"; return 1; }
    host=$(shell_arg_safe "$host") || { emit_error "422" "invalid host"; return 1; }
    port=$(int_guard "$port" 443)

    local out dns_ok=false port_ok=false tls_ok=false http_ok=false tls_ran=false http_ran=false

    emit_progress "dns" "resolving $host" 15
    logmsg "$(c_info "── DNS: $host ──")"
    if [[ "$host" =~ ^[0-9.]+$ || "$host" == *:*:* ]]; then
        dns_ok=true
        logmsg "  (literal IP — resolution skipped)"
    else
        out=$(tool_invoke net_dns_lookup "$(jq -n --arg d "$host" '{domain:$d}')") && [[ -n "$out" ]] && dns_ok=true
        logmsg "${out:-  no answer}"
    fi

    emit_progress "port" "tcp $host:$port" 40
    logmsg "$(c_info "── TCP: $host:$port ──")"
    out=$(tool_invoke net_port_check "$(jq -n --arg h "$host" --argjson p "$port" '{host:$h,port:$p}')") && port_ok=true
    logmsg "  $out"

    if [[ "$port" == "443" || "$scheme" == "https" ]]; then
        tls_ran=true
        emit_progress "tls" "certificate check" 65
        logmsg "$(c_info "── TLS: $host:$port ──")"
        out=$(tool_invoke net_tls_cert "$(jq -n --arg h "$host" --argjson p "$port" '{host:$h,port:$p}')") && tls_ok=true
        logmsg "$out"
    fi

    if [[ -n "$url" ]]; then
        http_ran=true
        emit_progress "http" "headers" 85
        logmsg "$(c_info "── HTTP: $url ──")"
        out=$(tool_invoke net_http_headers "$(jq -n --arg u "$url" '{url:$u}')") && http_ok=true
        logmsg "$out"
    fi

    local checks=2 passed=0
    [[ "$dns_ok" == "true" ]] && ((passed++))
    [[ "$port_ok" == "true" ]] && ((passed++))
    [[ "$tls_ran" == "true" ]] && { ((checks++)); [[ "$tls_ok" == "true" ]] && ((passed++)); }
    [[ "$http_ran" == "true" ]] && { ((checks++)); [[ "$http_ok" == "true" ]] && ((passed++)); }

    emit result "$(jq -n --arg h "$host" --argjson p "$port" \
        --argjson dns "$dns_ok" --argjson tcp "$port_ok" \
        --argjson tls "$([[ "$tls_ran" == "true" ]] && printf '%s' "$tls_ok" || printf 'null')" \
        --argjson http "$([[ "$http_ran" == "true" ]] && printf '%s' "$http_ok" || printf 'null')" \
        --argjson passed "$passed" --argjson checks "$checks" \
        '{ok:($passed==$checks),summary:("net.diagnose "+$h+":"+($p|tostring)+" — "+($passed|tostring)+"/"+($checks|tostring)+" checks passed"),
          data:{host:$h,port:$p,dns:$dns,tcp:$tcp,tls:$tls,http:$http}}')"
    [[ "$passed" == "$checks" ]]
}

# net.watch — "tell me when this page changes." Fetches the page through the
# SSRF-guarded `browse` tool (readable text, not raw HTML — stable across the
# session tokens/timestamps that would make every check look changed), hashes it,
# and compares against the last snapshot kept in the scratch SQLite db. First run
# saves a baseline; later runs report "no change" or "CHANGED" with a bounded
# line diff. curl + sqlite3. Writes (it stores a snapshot).
wf_net_watch() {
    command -v sqlite3 &>/dev/null || { emit_fail "sqlite3 required"; return 1; }
    local raw="${INPUT_url:-}"; val_required "$raw" "INPUT_url" || { emit_fail "INPUT_url required"; return 1; }
    local url; url=$(sanitize_url "$raw") || { emit_fail "INPUT_url must be a plain http(s) URL"; return 1; }

    emit_progress "fetch" "fetching $url" 40
    local content; content=$(tool_invoke browse "$(jq -n --arg u "$url" '{url:$u}')")
    case "$content" in
        'refusing to fetch'*|'invalid or unsafe url'*|'curl required'*|'')
            emit_fail "could not fetch $url: ${content:-empty response}"; return 1 ;;
    esac
    # Normalize trailing whitespace so a cosmetic reflow isn't reported as a change.
    local norm; norm=$(printf '%s' "$content" | sed 's/[[:space:]]*$//')
    local hash; hash=$(printf '%s' "$norm" | { command -v sha256sum &>/dev/null && sha256sum || shasum -a 256; } | cut -d' ' -f1)

    scratchdb_exec "CREATE TABLE IF NOT EXISTS net_watch(url TEXT, ts TEXT, hash TEXT, content TEXT);" >/dev/null 2>&1 \
        || { emit_fail "scratch db unavailable"; return 1; }
    local prevhash prevcontent
    prevhash=$(scratchdb_exec    "SELECT hash    FROM net_watch WHERE url=$(sql_quote "$url") ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
    prevcontent=$(scratchdb_exec "SELECT content FROM net_watch WHERE url=$(sql_quote "$url") ORDER BY ts DESC LIMIT 1;" 2>/dev/null)
    # Cap stored content so a huge page can't bloat the scratch db unbounded.
    local capped="${norm:0:200000}"
    scratchdb_exec "INSERT INTO net_watch(url,ts,hash,content) VALUES ($(sql_quote "$url"), $(sql_quote "$(date_now)"), $(sql_quote "$hash"), $(sql_quote "$capped"));" >/dev/null 2>&1

    if [[ -z "$prevhash" ]]; then
        emit_ok "baseline saved for $url ($(printf '%s' "$norm" | grep -c '' ) lines) — re-run later to detect changes"
        return 0
    fi
    if [[ "$prevhash" == "$hash" ]]; then
        emit_ok "no change since last check: $url"
        return 0
    fi
    logmsg "$(c_warn "$SYM_WARN CHANGED: $url")"
    local pf cf; pf=$(path_temp_file yca-watch-old); cf=$(path_temp_file yca-watch-new)
    printf '%s\n' "$prevcontent" > "$pf"; printf '%s\n' "$norm" > "$cf"
    logmsg "$(c_info '── diff (− previous, + now; max 60 lines) ──')"
    diff "$pf" "$cf" 2>/dev/null | grep -E '^[<>]' | head -60 | sed 's/^</  − /; s/^>/  + /' >&2
    rm -f "$pf" "$cf"
    emit_ok "CHANGED: $url (snapshot updated)"
}

wf_register "net.diagnose" wf_net_diagnose 1 safe   "curl" "DNS→TCP→TLS→HTTP diagnosis for a URL or host"
wf_register "net.watch"    wf_net_watch    1 writes "curl" "Snapshot a page and report when it changes (line diff)"
