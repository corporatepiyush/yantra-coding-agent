# tools/monitor.sh — Read-only monitoring tools for agent activity history
# Disabled by default. Enable with: tools enable monitor

# All queries use query_only PRAGMA to prevent writes.

_monitor_query() {
    local sql="$1"
    _sqlite -readonly "$YCA_DB_PATH" "$sql" 2>/dev/null
}

_monitor_query_json() {
    local sql="$1"
    _sqlite -json -readonly "$YCA_DB_PATH" "$sql" 2>/dev/null || printf '[]'
}

# _mon_limit VALUE -> integer LIMIT (default 50, hard-capped 1000). Never lets a
# non-numeric value reach the SQL.
_mon_limit() { local n; n=$(int_guard "$1" 50); (( n > 1000 )) && n=1000; printf '%s' "$n"; }

# _mon_where BASE [USER_WHERE] -> "BASE" or "BASE AND (fragment)". The user
# fragment passes through sql_safe_fragment (single readonly SELECT only —
# no ';', comments, or schema/DML verbs). Returns 1 if the fragment is unsafe.
_mon_where() {
    local base="$1" uw="$2"
    [[ -z "$uw" ]] && { printf '%s' "$base"; return 0; }
    local safe; safe=$(sql_safe_fragment "$uw") || return 1
    printf '%s AND (%s)' "$base" "$safe"
}

# _mon_since VALUE [DEFAULT] -> a validated SQLite datetime modifier (e.g.
# '-24 hours'), never raw user text interpolated into datetime('now', …).
_mon_since() {
    local s="$1" re='^[+-]?[0-9]+ (second|minute|hour|day|week|month|year)s?$'
    [[ "$s" =~ $re ]] && { printf '%s' "$s"; return 0; }
    printf '%s' "${2:--24 hours}"
}

# tool_monitor_events -> query events (filter by agent/kind/level + optional WHERE)
tool_monitor_events() {
    local agent kind level where limit w
    agent=$(tool_arg agent); kind=$(tool_arg kind); level=$(tool_arg level)
    where=$(tool_arg where); limit=$(_mon_limit "$(tool_arg limit 50)")
    w="1=1"
    [[ -n "$agent" ]] && w+=" AND agent=$(sql_quote "$agent")"
    [[ -n "$kind" ]]  && w+=" AND kind=$(sql_quote "$kind")"
    [[ -n "$level" ]] && w+=" AND level=$(sql_quote "$level")"
    w=$(_mon_where "$w" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM events WHERE $w ORDER BY ts DESC LIMIT $limit;"
}

# tool_monitor_tasks -> query tasks (filter by status + optional WHERE)
tool_monitor_tasks() {
    local status where limit w
    status=$(tool_arg status); where=$(tool_arg where); limit=$(_mon_limit "$(tool_arg limit 50)")
    w="1=1"
    [[ -n "$status" ]] && w+=" AND status=$(sql_quote "$status")"
    w=$(_mon_where "$w" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM tasks WHERE $w ORDER BY created_ts DESC LIMIT $limit;"
}

# tool_monitor_changes -> query changes ledger (optional WHERE)
tool_monitor_changes() {
    local where limit w; where=$(tool_arg where); limit=$(_mon_limit "$(tool_arg limit 50)")
    w=$(_mon_where "1=1" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM changes WHERE $w ORDER BY ts DESC LIMIT $limit;"
}

# tool_monitor_messages -> query inter-agent bus (optional WHERE)
tool_monitor_messages() {
    local where limit w; where=$(tool_arg where); limit=$(_mon_limit "$(tool_arg limit 50)")
    w=$(_mon_where "1=1" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM messages WHERE $w ORDER BY ts DESC LIMIT $limit;"
}

# tool_monitor_heartbeats -> current agent liveness
tool_monitor_heartbeats() {
    _monitor_query_json "SELECT agent, pid, MAX(ts) as last_beat, status, cpu, mem FROM heartbeats WHERE ts > datetime('now','-10 minutes') GROUP BY agent, pid ORDER BY last_beat DESC;"
}

# tool_monitor_versions -> harness version history
tool_monitor_versions() {
    _monitor_query_json "SELECT * FROM versions ORDER BY id DESC LIMIT 20;"
}

# tool_monitor_search -> FTS5 full-text search over events
tool_monitor_search() {
    local query="${1:?search query required}"
    _monitor_query_json "SELECT e.id, e.agent, e.ts, e.level, e.kind, e.message FROM search_fts f JOIN events e ON f.rowid = e.id WHERE search_fts MATCH $(sql_quote "$query") ORDER BY e.ts DESC LIMIT 50;"
}

# tool_monitor_stats -> aggregate activity stats over a validated time window.
tool_monitor_stats() {
    local since; since=$(_mon_since "$(tool_arg since '-24 hours')" '-24 hours')
    _monitor_query_json "
        SELECT 'events' as metric, COUNT(*) as count FROM events WHERE ts > datetime('now','$since')
        UNION ALL
        SELECT 'tool_calls', COUNT(*) FROM events WHERE kind='tool.call' AND ts > datetime('now','$since')
        UNION ALL
        SELECT 'workflow_runs', COUNT(*) FROM events WHERE kind='workflow.start' AND ts > datetime('now','$since')
        UNION ALL
        SELECT 'changes', COUNT(*) FROM changes WHERE ts > datetime('now','$since')
        UNION ALL
        SELECT 'messages', COUNT(*) FROM messages WHERE ts > datetime('now','$since')
        UNION ALL
        SELECT 'errors', COUNT(*) FROM events WHERE level='error' AND ts > datetime('now','$since')
    ;"
}

# tool_monitor_kg_nodes -> query knowledge graph nodes (populated by kg_build)
tool_monitor_kg_nodes() {
    local limit where w; limit=$(_mon_limit "$(tool_arg limit 50)"); where=$(tool_arg where)
    db_table_exists "kg_nodes" || { printf '[]'; return 0; }
    w=$(_mon_where "1=1" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM kg_nodes WHERE $w LIMIT $limit;"
}

# tool_monitor_kg_edges -> query knowledge graph edges (populated by kg_build)
tool_monitor_kg_edges() {
    local limit where w; limit=$(_mon_limit "$(tool_arg limit 50)"); where=$(tool_arg where)
    db_table_exists "kg_edges" || { printf '[]'; return 0; }
    w=$(_mon_where "1=1" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query_json "SELECT * FROM kg_edges WHERE $w LIMIT $limit;"
}

# tool_monitor_config -> show harness config (read-only)
tool_monitor_config() {
    _monitor_query_json "SELECT key, value FROM config ORDER BY key;"
}

# tool_monitor_timeline -> chronological event timeline (compact)
tool_monitor_timeline() {
    local limit where w; limit=$(_mon_limit "$(tool_arg limit 100)"); where=$(tool_arg where)
    w=$(_mon_where "1=1" "$where") || { printf 'unsafe WHERE clause rejected'; return 1; }
    _monitor_query "SELECT substr(ts,1,19) || ' | ' || agent || ' | ' || level || ' | ' || kind || ' | ' || message FROM events WHERE $w ORDER BY ts DESC LIMIT $limit;" 2>/dev/null | column -t -s'|'
}

tool_register "monitor_events"     tool_monitor_events     '{"type":"object","properties":{"agent":{"type":"string","description":"the agent"},"kind":{"type":"string","description":"the kind"},"level":{"type":"string","description":"the level"},"where":{"type":"string","description":"optional SQL WHERE fragment (single readonly filter, no ; or comments)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_tasks"      tool_monitor_tasks      '{"type":"object","properties":{"status":{"type":"string","description":"the status"},"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_changes"    tool_monitor_changes    '{"type":"object","properties":{"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_messages"   tool_monitor_messages   '{"type":"object","properties":{"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_heartbeats" tool_monitor_heartbeats '{"type":"object","properties":{}}' safe all monitor
tool_register "monitor_versions"   tool_monitor_versions   '{"type":"object","properties":{}}' safe all monitor
tool_register "monitor_search"     tool_monitor_search     '{"type":"object","properties":{"query":{"type":"string","description":"the search or lookup query"}},"required":["query"]}' safe all monitor
tool_register "monitor_stats"      tool_monitor_stats      '{"type":"object","properties":{"since":{"type":"string","description":"SQLite modifier e.g. -24 hours, -7 days"}}}' safe all monitor
tool_register "monitor_kg_nodes"   tool_monitor_kg_nodes   '{"type":"object","properties":{"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_kg_edges"   tool_monitor_kg_edges   '{"type":"object","properties":{"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
tool_register "monitor_config"     tool_monitor_config     '{"type":"object","properties":{}}' safe all monitor
tool_register "monitor_timeline"   tool_monitor_timeline   '{"type":"object","properties":{"where":{"type":"string","description":"a SQL WHERE clause (without the WHERE keyword)"},"limit":{"type":"integer","description":"maximum number of rows to return"}}}' safe all monitor
