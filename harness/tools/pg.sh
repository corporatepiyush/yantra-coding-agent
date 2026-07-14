# tools/pg.sh — PostgreSQL tools (category: pg). Disabled by default.
# Connection comes from $PG_CONN (default postgresql://localhost/postgres).
# All tools gate on `psql`; identifiers are validated to block injection.

_pg() {
    command -v psql &>/dev/null || { printf 'psql missing — install libpq/postgresql and set PG_CONN\n  brew install libpq  |  apt install postgresql-client'; return 127; }
    PGCONNECT_TIMEOUT=5 psql "${PG_CONN:-postgresql://localhost/postgres}" -X -q -P pager=off "$@" 2>&1
}
# _pg_ident NAME -> 0 if NAME is a safe SQL identifier (optionally schema.table).
_pg_ident() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)?$ ]]; }

tool_pg_query() {
    local sql; sql=$(tool_arg sql "$1")
    [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    # Read-only by default: one statement, run in a read-only transaction so
    # DML/DDL (DELETE/UPDATE/DROP, or a data-modifying CTE) is refused by the
    # server. No ';'-chaining, so `SET ...read_only=off; DELETE` can't slip past.
    # Mutations go through the gated pg_exec tool.
    sql_single_stmt "$sql" || { printf 'refused: one statement only (no ;-chaining). Use pg_exec for writes.'; return 1; }
    PGOPTIONS='-c default_transaction_read_only=on' _pg -c "$sql"
}
tool_pg_exec() {
    local sql; sql=$(tool_arg sql "$1")
    [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    confirm_action "Execute WRITE SQL on Postgres (${PG_CONN:-postgresql://localhost/postgres})" "$sql" || { confirm_denied_msg; return 1; }
    _pg -c "$sql"
}
tool_pg_tables() {
    _pg -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC;"
}
tool_pg_describe() {
    local t; t=$(tool_arg table "$1"); [[ -n "$t" ]] || { printf 'table required (.table)'; return 1; }
    _pg_ident "$t" || { printf 'invalid table name: %s' "$t"; return 1; }
    _pg -c "\\d $t"
}
tool_pg_indexes() {
    local t; t=$(tool_arg table "$1")
    if [[ -n "$t" ]]; then
        _pg_ident "$t" || { printf 'invalid table name: %s' "$t"; return 1; }
        _pg -c "SELECT indexname, indexdef FROM pg_indexes WHERE tablename = '$t';"
    else
        _pg -c "SELECT schemaname, tablename, indexname FROM pg_indexes WHERE schemaname NOT IN ('pg_catalog','information_schema') ORDER BY 1,2;"
    fi
}
tool_pg_sizes() {
    _pg -c "SELECT pg_size_pretty(pg_database_size(current_database())) AS db_size;"
    _pg -c "SELECT relname AS table, pg_size_pretty(pg_total_relation_size(relid)) AS total FROM pg_catalog.pg_statio_user_tables ORDER BY pg_total_relation_size(relid) DESC LIMIT 15;"
}
tool_pg_active_queries() {
    _pg -c "SELECT pid, usename, state, wait_event_type, now()-query_start AS duration, left(query,80) AS query FROM pg_stat_activity WHERE state IS DISTINCT FROM 'idle' ORDER BY duration DESC NULLS LAST;"
}
tool_pg_lock_waits() {
    _pg -c "SELECT blocked.pid AS blocked_pid, blocking.pid AS blocking_pid, blocked.query AS blocked_query FROM pg_stat_activity blocked JOIN pg_stat_activity blocking ON blocking.pid = ANY(pg_blocking_pids(blocked.pid)) WHERE cardinality(pg_blocking_pids(blocked.pid)) > 0;"
}
tool_pg_slow_queries() {
    _pg -c "SELECT round(mean_exec_time::numeric,1) AS avg_ms, calls, round(total_exec_time::numeric,0) AS total_ms, left(query,90) AS query FROM pg_stat_statements ORDER BY mean_exec_time DESC LIMIT 15;" \
        || printf '\n(enable the pg_stat_statements extension: CREATE EXTENSION pg_stat_statements;)'
}
tool_pg_table_stats() {
    _pg -c "SELECT relname, n_live_tup, n_dead_tup, last_autovacuum, last_analyze FROM pg_stat_user_tables ORDER BY n_dead_tup DESC LIMIT 20;"
}
tool_pg_explain() {
    local sql; sql=$(tool_arg sql "$1"); [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    # EXPLAIN without ANALYZE doesn't run the plan — but `psql -c` executes every
    # ';'-separated statement, so `EXPLAIN SELECT 1; DROP TABLE x` would run the
    # DROP. Require a single statement AND a read-only transaction.
    sql_single_stmt "$sql" || { printf 'refused: one statement only (no ;-chaining)'; return 1; }
    PGOPTIONS='-c default_transaction_read_only=on' _pg -c "EXPLAIN $sql"
}
tool_pg_roles() {
    _pg -c "SELECT rolname, rolsuper, rolcreatedb, rolcanlogin, rolconnlimit FROM pg_roles ORDER BY rolname;"
}
tool_pg_vacuum() { _pg -c "VACUUM ANALYZE;" && printf 'VACUUM ANALYZE done'; }
tool_pg_backup() {
    command -v pg_dump &>/dev/null || { printf 'pg_dump missing'; return 127; }
    local f; f=$(tool_arg file "${1:-pg_dump_$(now_stamp).sql}")
    path_check_allowed "$f" || { printf 'path not allowed'; return 1; }
    pg_dump "${PG_CONN:-postgresql://localhost/postgres}" -f "$f" 2>&1 && printf 'backup: %s' "$f"
}
tool_pg_doctor() {
    printf 'psql: %s\n' "$(command -v psql || printf MISSING)"
    printf 'pg_dump: %s\n' "$(command -v pg_dump || printf MISSING)"
    printf 'PG_CONN: %s\n' "${PG_CONN:-postgresql://localhost/postgres (default)}"
    _pg -c "SELECT version();" | head -1
}

tool_register "pg_query"    tool_pg_query    '{"type":"object","properties":{"sql":{"type":"string","description":"the SQL statement to execute"}},"required":["sql"]}' safe all pg
tool_register "pg_exec"     tool_pg_exec     '{"type":"object","properties":{"sql":{"type":"string","description":"write SQL (INSERT/UPDATE/DDL) — confirmation-gated"}},"required":["sql"]}' writes all pg
tool_register "pg_tables"   tool_pg_tables   '{"type":"object","properties":{}}' safe all pg
tool_register "pg_describe" tool_pg_describe '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}},"required":["table"]}' safe all pg
tool_register "pg_indexes"  tool_pg_indexes  '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}}}' safe all pg
tool_register "pg_sizes"     tool_pg_sizes     '{"type":"object","properties":{}}' safe all pg
tool_register "pg_active_queries" tool_pg_active_queries '{"type":"object","properties":{}}' safe all pg
tool_register "pg_lock_waits"    tool_pg_lock_waits    '{"type":"object","properties":{}}' safe all pg
tool_register "pg_slow_queries"     tool_pg_slow_queries     '{"type":"object","properties":{}}' safe all pg
tool_register "pg_table_stats"    tool_pg_table_stats    '{"type":"object","properties":{}}' safe all pg
tool_register "pg_explain"  tool_pg_explain  '{"type":"object","properties":{"sql":{"type":"string","description":"the SQL statement to execute"}},"required":["sql"]}' safe all pg
tool_register "pg_roles"    tool_pg_roles    '{"type":"object","properties":{}}' safe all pg
tool_register "pg_vacuum"   tool_pg_vacuum   '{"type":"object","properties":{}}' writes all pg
tool_register "pg_backup"   tool_pg_backup   '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' writes all pg
tool_register "pg_doctor"   tool_pg_doctor   '{"type":"object","properties":{}}' safe all pg
