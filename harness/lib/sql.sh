# lib/08-sql.sh — SQL/SQLite utilities
# All SQL strings escaped with sql_quote. Never paste values into SQL.

# sql_quote VALUE -> prints SQL string literal: 'value' (with internal ' escaped as '')
sql_quote() {
    printf "'%s'" "${1//\'/\'\'}"
}

# sql_quote_if_string VALUE -> if looks like number, no quotes; else sql_quote
sql_quote_auto() {
    if math_is_int "$1"; then
        printf '%s' "$1"
    else
        sql_quote "$1"
    fi
}

# _sqlite ARGS... — the single choke point every SQLite connection goes through,
# so it ALWAYS gets a per-connection busy_timeout. busy_timeout is NOT persisted
# in the db file (only journal_mode=WAL is), so an ad-hoc `sqlite3` call would
# otherwise default to 0ms and fail immediately when a parallel sub-agent holds
# the write lock. Pass the db path plus any flags, e.g.
#   _sqlite "$db" "$sql"              _sqlite -json -readonly "$db" "$sql"
# We use the `.timeout` dot-command (not `PRAGMA busy_timeout=N`, which echoes its
# value to stdout and would corrupt query output); it sets busy_timeout silently.
_sqlite() {
    sqlite3 -cmd ".timeout ${YCA_SQLITE_BUSY_TIMEOUT:-10000}" "$@"
}

# db_exec SQL... -> runs SQL on YCA_DB_PATH
db_exec() {
    [[ -z "$YCA_DB_PATH" ]] && { printf 'db not initialized\n' >&2; return 1; }
    _sqlite "$YCA_DB_PATH" "$@"
}

# db_exec_json SQL... -> runs SQL, returns JSON
db_exec_json() {
    [[ -z "$YCA_DB_PATH" ]] && return 1
    _sqlite -json "$YCA_DB_PATH" "$@"
}

# db_query SQL -> prints result (table format)
db_query() {
    db_exec "$1"
}

# db_query_json SQL -> prints JSON array of rows
db_query_json() {
    db_exec_json "$1"
}

# db_insert TABLE KEY1 VAL1 KEY2 VAL2 ... -> inserts a row
db_insert() {
    local table="$1"; shift
    local cols="" vals="" k v
    while [[ $# -ge 2 ]]; do
        k="$1"; v="$2"; shift 2
        [[ -n "$cols" ]] && cols+=","
        cols+="$k"
        [[ -n "$vals" ]] && vals+=","
        vals+="$(sql_quote "$v")"
    done
    db_exec "INSERT INTO $table($cols) VALUES($vals);"
}

# db_count TABLE [WHERE_CLAUSE]
db_count() {
    local table="$1" where="${2:-}"
    local sql="SELECT COUNT(*) FROM $table"
    [[ -n "$where" ]] && sql+=" WHERE $where"
    db_exec "$sql;" 2>/dev/null || printf '0'
}

# db_escape_identifier NAME -> wraps in double quotes for SQL identifier
db_escape_ident() {
    printf '"%s"' "${1//\"/\"\"}"
}

# db_transaction SQL... -> wraps multiple statements in a transaction.
# BEGIN IMMEDIATE grabs the write lock up front so, combined with busy_timeout,
# a concurrent writer waits here rather than failing mid-transaction on first write.
db_transaction() {
    db_exec "BEGIN IMMEDIATE; $*; COMMIT;" 2>/dev/null || db_exec "ROLLBACK;" 2>/dev/null
}

# db_table_exists TABLE -> 0 if table exists
db_table_exists() {
    local c
    c=$(db_exec "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name=$(sql_quote "$1");" 2>/dev/null || printf '0')
    [[ "$c" == "1" ]]
}

# db_last_insert_id -> prints last autoincrement id
db_last_insert_id() {
    db_exec "SELECT last_insert_rowid();" 2>/dev/null
}
