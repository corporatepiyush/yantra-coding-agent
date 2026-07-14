# tools/mysql.sh — MySQL/MariaDB tools (category: mysql). Disabled by default.
# Uses your local mysql client config (~/.my.cnf) or MYSQL_* env; $MYSQL_DB is
# the default schema. All tools gate on `mysql`; identifiers are validated.

_mysql() {
    command -v mysql &>/dev/null || { printf 'mysql client missing — install it and configure ~/.my.cnf or MYSQL_* env\n  brew install mysql-client  |  apt install default-mysql-client'; return 127; }
    mysql --connect-timeout=5 ${MYSQL_DB:+"$MYSQL_DB"} -t -e "$1" 2>&1
}
_mysql_ident() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; }
# Read-only variant: SET SESSION TRANSACTION READ ONLY as an init-command so a
# DML statement is refused by the server. Used by the read query/explain tools.
_mysql_ro() {
    command -v mysql &>/dev/null || { printf 'mysql client missing'; return 127; }
    mysql --connect-timeout=5 --init-command='SET SESSION TRANSACTION READ ONLY' ${MYSQL_DB:+"$MYSQL_DB"} -t -e "$1" 2>&1
}

tool_mysql_query() {
    local sql; sql=$(tool_arg sql "$1"); [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    # Read-only by default, single statement — DML is refused by the server and
    # `SET ...; DELETE` can't be chained. Mutations go through gated mysql_exec.
    sql_single_stmt "$sql" || { printf 'refused: one statement only (no ;-chaining). Use mysql_exec for writes.'; return 1; }
    _mysql_ro "$sql"
}
tool_mysql_exec() {
    local sql; sql=$(tool_arg sql "$1"); [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    confirm_action "Execute WRITE SQL on MySQL (${MYSQL_DB:-default})" "$sql" || { confirm_denied_msg; return 1; }
    _mysql "$sql"
}
tool_mysql_databases() { _mysql "SHOW DATABASES;"; }
tool_mysql_tables() {
    _mysql "SELECT TABLE_NAME, TABLE_ROWS, ROUND((DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) AS mb FROM information_schema.TABLES WHERE TABLE_SCHEMA NOT IN ('mysql','information_schema','performance_schema','sys') ORDER BY DATA_LENGTH+INDEX_LENGTH DESC LIMIT 30;"
}
tool_mysql_describe() {
    local t; t=$(tool_arg table "$1"); [[ -n "$t" ]] || { printf 'table required (.table)'; return 1; }
    _mysql_ident "$t" || { printf 'invalid table name: %s' "$t"; return 1; }
    _mysql "DESCRIBE \`$t\`;"
}
tool_mysql_indexes() {
    local t; t=$(tool_arg table "$1"); [[ -n "$t" ]] || { printf 'table required (.table)'; return 1; }
    _mysql_ident "$t" || { printf 'invalid table name: %s' "$t"; return 1; }
    _mysql "SHOW INDEX FROM \`$t\`;"
}
tool_mysql_server_status()      { _mysql "SHOW GLOBAL STATUS WHERE Variable_name IN ('Threads_connected','Threads_running','Uptime','Queries','Slow_queries','Aborted_connects');"; }
tool_mysql_processlist() { _mysql "SHOW FULL PROCESSLIST;"; }
tool_mysql_server_variables() {
    local like; like=$(tool_arg like "$1")
    if [[ -n "$like" ]]; then
        _mysql_ident "${like//%/}" || { printf 'invalid pattern'; return 1; }
        _mysql "SHOW VARIABLES LIKE '$like';"
    else
        _mysql "SHOW VARIABLES;"
    fi
}
tool_mysql_sizes() {
    _mysql "SELECT TABLE_SCHEMA, ROUND(SUM(DATA_LENGTH+INDEX_LENGTH)/1024/1024,1) AS mb FROM information_schema.TABLES GROUP BY TABLE_SCHEMA ORDER BY mb DESC;"
}
tool_mysql_slow_queries() {
    _mysql "SELECT Variable_name, Variable_value FROM performance_schema.global_status WHERE Variable_name IN ('Slow_queries','Select_full_join','Select_scan');" \
        || _mysql "SHOW GLOBAL STATUS LIKE 'Slow_queries';"
}
tool_mysql_explain() {
    local sql; sql=$(tool_arg sql "$1"); [[ -n "$sql" ]] || { printf 'sql required (.sql)'; return 1; }
    sql_single_stmt "$sql" || { printf 'refused: one statement only (no ;-chaining)'; return 1; }
    _mysql_ro "EXPLAIN $sql"
}
tool_mysql_backup() {
    command -v mysqldump &>/dev/null || { printf 'mysqldump missing'; return 127; }
    local f; f=$(tool_arg file "${1:-mysql_$(now_stamp).sql}")
    path_check_allowed "$f" || { printf 'path not allowed'; return 1; }
    # Consistent dump (InnoDB) + routines/triggers, and surface errors instead of
    # swallowing them (the old `2>/dev/null && printf backup` reported success on
    # an empty/failed dump).
    local err rc
    err=$(mysqldump --single-transaction --routines --triggers ${MYSQL_DB:+"$MYSQL_DB"} 2>&1 >"$f"); rc=$?
    (( rc == 0 )) && printf 'backup: %s' "$f" || { printf 'backup FAILED: %s' "$err"; return 1; }
}
tool_mysql_doctor() {
    printf 'mysql: %s\n' "$(command -v mysql || printf MISSING)"
    printf 'mysqldump: %s\n' "$(command -v mysqldump || printf MISSING)"
    printf 'MYSQL_DB: %s\n' "${MYSQL_DB:-(none)}"
    _mysql "SELECT VERSION();"
}

tool_register "mysql_query"       tool_mysql_query       '{"type":"object","properties":{"sql":{"type":"string","description":"the SQL statement to execute"}},"required":["sql"]}' safe all mysql
tool_register "mysql_exec"        tool_mysql_exec        '{"type":"object","properties":{"sql":{"type":"string","description":"write SQL — confirmation-gated"}},"required":["sql"]}' writes all mysql
tool_register "mysql_databases"   tool_mysql_databases   '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_tables"      tool_mysql_tables      '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_describe"    tool_mysql_describe    '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}},"required":["table"]}' safe all mysql
tool_register "mysql_indexes"     tool_mysql_indexes     '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}},"required":["table"]}' safe all mysql
tool_register "mysql_server_status"      tool_mysql_server_status      '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_processlist" tool_mysql_processlist '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_server_variables"   tool_mysql_server_variables   '{"type":"object","properties":{"like":{"type":"string","description":"the like"}}}' safe all mysql
tool_register "mysql_sizes"        tool_mysql_sizes        '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_slow_queries"        tool_mysql_slow_queries        '{"type":"object","properties":{}}' safe all mysql
tool_register "mysql_explain"     tool_mysql_explain     '{"type":"object","properties":{"sql":{"type":"string","description":"the SQL statement to execute"}},"required":["sql"]}' safe all mysql
tool_register "mysql_backup"      tool_mysql_backup      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}}}' writes all mysql
tool_register "mysql_doctor"      tool_mysql_doctor      '{"type":"object","properties":{}}' safe all mysql
