# tools/redis.sh — Redis tools (category: redis). Disabled by default.
# Connection via $REDIS_URL (e.g. redis://localhost:6379/0) if set, else the
# redis-cli defaults. All tools gate on `redis-cli`.

_redis() {
    command -v redis-cli &>/dev/null || { printf 'redis-cli missing — install redis\n  brew install redis  |  apt install redis-tools'; return 127; }
    if [[ -n "${REDIS_URL:-}" ]]; then redis-cli -u "$REDIS_URL" "$@" 2>&1; else redis-cli "$@" 2>&1; fi
}
# Redis keys are opaque; reject only shell-dangerous bytes, not glob chars.
_redis_key_ok() { case "$1" in *[\`\$\;\|\<\>\'\"\\]*|*$'\n'*) return 1 ;; *) return 0 ;; esac; }

tool_redis_info()    { local s; s=$(tool_arg section "$1"); _redis info ${s:+"$s"}; }
tool_redis_ping()    { _redis ping; }
tool_redis_key_count()  { _redis dbsize; }
tool_redis_scan() {
    local p; p=$(tool_arg pattern "${1:-*}"); local count; count=$(int_guard "$(tool_arg count 200)" 200)
    _redis_key_ok "$p" || { printf 'invalid pattern'; return 1; }
    _redis --scan --pattern "$p" --count "$count" | head -"$count"
}
tool_redis_get() {
    local k; k=$(tool_arg key "$1"); [[ -n "$k" ]] || { printf 'key required (.key)'; return 1; }
    _redis_key_ok "$k" || { printf 'invalid key'; return 1; }
    # Type-aware read so lists/hashes/sets don't return WRONGTYPE.
    local t; t=$(_redis type "$k")
    case "$t" in
        string) _redis get "$k" ;;
        list)   _redis lrange "$k" 0 100 ;;
        set)    _redis smembers "$k" ;;
        zset)   _redis zrange "$k" 0 100 withscores ;;
        hash)   _redis hgetall "$k" ;;
        none)   printf '(nil — key does not exist)' ;;
        *)      printf 'type: %s' "$t" ;;
    esac
}
tool_redis_type()   { local k; k=$(tool_arg key "$1"); [[ -n "$k" ]] || { printf 'key required'; return 1; }; _redis_key_ok "$k" || { printf 'invalid key'; return 1; }; _redis type "$k"; }
tool_redis_ttl()    { local k; k=$(tool_arg key "$1"); [[ -n "$k" ]] || { printf 'key required'; return 1; }; _redis_key_ok "$k" || { printf 'invalid key'; return 1; }; _redis ttl "$k"; }
tool_redis_slowlog() { _redis slowlog get 20; }
tool_redis_list_clients() { _redis client list; }
tool_redis_config() {
    local p; p=$(tool_arg param "${1:-maxmemory}"); _redis_key_ok "$p" || { printf 'invalid param'; return 1; }
    # Refuse params that leak credentials (requirepass/masterauth) or dump the
    # whole config via a glob (which includes those secrets). Query a specific
    # non-secret param instead.
    case "$(str_lower "$p")" in
        requirepass|masterauth|*'*'*|*'?'*|*'['*)
            printf 'refused: "%s" would expose credentials or the full config; query a specific non-secret param' "$p"; return 1 ;;
    esac
    _redis config get "$p"
}
tool_redis_doctor() {
    printf 'redis-cli: %s\n' "$(command -v redis-cli || printf MISSING)"
    printf 'REDIS_URL: %s\n' "${REDIS_URL:-(default localhost:6379)}"
    _redis ping
}

# ── Write / act verbs (gated) ────────────────────────────────────────────────
# Single-key mutations (set/del/expire/persist/rename/incr) were removed — each
# was a 1:1 `redis-cli <VERB> <key>` the always-on `bash` tool runs directly
# (still consent-gated there). flushdb stays: its destructive gate + explicit
# "delete ALL keys" preview is safer than a bare `redis-cli flushall`.
tool_redis_flushdb() {
    confirm_action "FLUSHDB — delete ALL keys in the current Redis database (irreversible)" "redis FLUSHDB" || { confirm_denied_msg; return 1; }
    _redis flushdb
}

tool_register "redis_info"    tool_redis_info    '{"type":"object","properties":{"section":{"type":"string","description":"the section name"}}}' safe all redis
tool_register "redis_ping"    tool_redis_ping    '{"type":"object","properties":{}}' safe all redis
tool_register "redis_key_count"  tool_redis_key_count  '{"type":"object","properties":{}}' safe all redis
tool_register "redis_scan"    tool_redis_scan    '{"type":"object","properties":{"pattern":{"type":"string","description":"the search pattern (text or regex)"},"count":{"type":"integer","description":"maximum number of results to return"}}}' safe all redis
tool_register "redis_get"     tool_redis_get     '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"}},"required":["key"]}' safe all redis
tool_register "redis_type"    tool_redis_type    '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"}},"required":["key"]}' safe all redis
tool_register "redis_ttl"     tool_redis_ttl     '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"}},"required":["key"]}' safe all redis
tool_register "redis_slowlog" tool_redis_slowlog '{"type":"object","properties":{}}' safe all redis
tool_register "redis_list_clients" tool_redis_list_clients '{"type":"object","properties":{}}' safe all redis
tool_register "redis_config"  tool_redis_config  '{"type":"object","properties":{"param":{"type":"string","description":"the parameter name"}}}' safe all redis
tool_register "redis_doctor"  tool_redis_doctor  '{"type":"object","properties":{}}' safe all redis
tool_register "redis_flushdb" tool_redis_flushdb '{"description":"Delete ALL keys in the current db — gated","type":"object","properties":{}}' destructive all redis
