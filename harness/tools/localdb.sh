# tools/localdb.sh — a scratch SQLite workspace the user or the LLM can use for
# quick heuristic work: create tables, run DML, query. Kept STRICTLY SEPARATE
# from the harness's internal .harness.db — every statement here targets the
# scratch file via scratchdb_exec/query/readonly, never YCA_DB_PATH. Category:
# localdb (off by default; enable with `cmd:tools enable localdb` or just
# `yantra localdb <call>`).

# ── Scratch-DB seam (the isolation guarantee lives here) ─────────────────────
# The scratch db is a separate file, overridable via HARNESS_SCRATCH_DB. It is
# NEVER YCA_DB_PATH, so nothing here can touch harness internals.
_localdb_path() { printf '%s' "${HARNESS_SCRATCH_DB:-$YCA_PROJECT_DIR/.yantra-scratch.db}"; }

# One-time WAL enablement (WAL is persisted in the file, so it survives across the
# per-command processes of parallel sub-agents; the per-connection busy_timeout
# that makes concurrent writers wait comes from the shared lib/sql.sh `_sqlite`).
_localdb_ready=0
_localdb_init() {
    [[ "$_localdb_ready" == 1 ]] && return 0
    path_ensure_dir "$(dirname "$(_localdb_path)")" 2>/dev/null || true
    _sqlite "$(_localdb_path)" "PRAGMA journal_mode=WAL;" >/dev/null 2>&1 || { printf 'scratch db unavailable'; return 1; }
    _localdb_ready=1
}

# scratchdb_exec SQL...      — run SQL on the SCRATCH db (read/write).
# scratchdb_query SQL...     — same, but -json output.
# scratchdb_readonly SQL...  — open the connection read-only (SELECT-only guard).
# All three route through the shared _sqlite wrapper (busy_timeout) and ONLY ever
# reference _localdb_path — this is what keeps the scratch db isolated.
scratchdb_exec()     { _localdb_init || return 1; _sqlite            "$(_localdb_path)" "$@"; }
scratchdb_query()    { _localdb_init || return 1; _sqlite -json      "$(_localdb_path)" "$@"; }
scratchdb_readonly() { _localdb_init || return 1; _sqlite -readonly  "$(_localdb_path)" "$@"; }

# _localdb_ident NAME — accept a safe SQL identifier (starts with letter/_, then
# letters/digits/_). Prints it on success; fails (empty) on anything else, so a
# table/column name can never carry injection.
_localdb_ident() {
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] && { printf '%s' "$1"; return 0; }
    return 1
}

# _localdb_bulk_insert TABLE ROWS_JSON — insert an array of row objects in ONE
# transaction with a SINGLE sqlite invocation. The naive path forked a jq per
# value (O(rows×cols) processes — thousands on a bulk load); this makes ONE jq
# pass and lets SQLite parse the payload itself via json_each()/json_extract()
# (JSON1 — built into every SQLite since 3.9, 2015; default-on since 3.38).
# Rows are grouped by their column set so heterogeneous rows still insert with
# the right columns (an absent key stays absent, so a column DEFAULT applies).
# Injection-safe: the whole payload is ONE sql_quote'd string literal — no value
# is ever concatenated into SQL — and every column name is identifier-validated
# before it reaches the statement. json_extract preserves JSON types (a number
# inserts as a number, null as NULL) instead of stringifying everything.
_localdb_bulk_insert() {
    local table="$1" rows_json="$2"
    local -a stmts=()
    local line cols rows c proj collist
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        cols="${line%%$'\x01'*}"           # "col1,col2"
        rows="${line#*$'\x01'}"            # compact JSON array for this group
        local -a colarr=(); IFS=',' read -ra colarr <<< "$cols"
        proj=""; collist=""
        for c in "${colarr[@]}"; do
            _localdb_ident "$c" >/dev/null || { printf 'invalid column name: %s' "$c"; return 1; }
            [[ -n "$collist" ]] && collist+=", "; collist+="$c"
            [[ -n "$proj" ]] && proj+=", "; proj+="json_extract(value, '\$.$c')"
        done
        stmts+=("INSERT INTO $table ($collist) SELECT $proj FROM json_each($(sql_quote "$rows"));")
    done < <(printf '%s' "$rows_json" | jq -rc '
        group_by(keys_unsorted | sort)[]
        | ((.[0] | keys_unsorted | join(",")) + "\u0001" + tojson)' 2>/dev/null)
    (( ${#stmts[@]} == 0 )) && { printf 'no insertable rows'; return 1; }
    scratchdb_exec "BEGIN IMMEDIATE; ${stmts[*]} COMMIT;" 2>&1
}

# ── Tool functions ───────────────────────────────────────────────────────────
# (implemented against the seam above; each reads its inputs via tool_arg)

# tables — list tables in the scratch db.
tool_localdb_tables() {
    local out; out=$(scratchdb_exec "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name;" 2>&1) || { printf '%s' "$out"; return 1; }
    [[ -n "$out" ]] && printf '%s' "$out" || printf '(no tables in scratch db)'
}

# schema — CREATE statement + column info for one table.
tool_localdb_schema() {
    local table; table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
    scratchdb_exec "SELECT sql FROM sqlite_master WHERE type='table' AND name=$(sql_quote "$table"); PRAGMA table_info($table);" 2>&1
}

# create — CREATE TABLE from a full .sql statement, or from .table + .columns.
tool_localdb_create() {
    local sql; sql=$(tool_arg sql '')
    if [[ -n "$sql" ]]; then
        [[ "$sql" =~ ^[[:space:]]*[Cc][Rr][Ee][Aa][Tt][Ee] ]] || { printf 'sql must be a CREATE statement'; return 1; }
        scratchdb_exec "$sql" 2>&1 && printf 'created'
    else
        local table cols
        table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
        cols=$(tool_arg columns)
        [[ -n "$cols" ]] || { printf 'columns required (or pass a full .sql)'; return 1; }
        [[ "$cols" == *";"* ]] && { printf 'columns must not contain ";"'; return 1; }
        scratchdb_exec "CREATE TABLE IF NOT EXISTS $table ($cols);" 2>&1 && printf 'created table %s' "$table"
    fi
}

# drop — drop a table (confirm).
tool_localdb_drop() {
    local table; table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
    confirm_action "Drop table $table from the scratch db" "DROP TABLE $table" || { confirm_denied_msg; return 1; }
    scratchdb_exec "DROP TABLE IF EXISTS $table;" 2>&1 && printf 'dropped %s' "$table"
}

# insert — one row (JSON object) or bulk (JSON array of objects), one transaction.
tool_localdb_insert() {
    local table json rows n out
    table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
    json=$(tool_arg rows); [[ -n "$json" ]] || { printf 'rows (a JSON object or array) required'; return 1; }
    rows=$(printf '%s' "$json" | jq -c 'if type=="array" then . else [.] end' 2>/dev/null) || { printf 'invalid JSON'; return 1; }
    n=$(printf '%s' "$rows" | jq 'length' 2>/dev/null)
    [[ "$n" =~ ^[0-9]+$ ]] || { printf 'invalid JSON'; return 1; }
    (( n == 0 )) && { printf 'no rows to insert'; return 0; }
    out=$(_localdb_bulk_insert "$table" "$rows") || { printf '%s' "$out"; return 1; }
    [[ -n "$out" ]] && printf '%s\n' "$out"
    printf 'inserted %s row(s) into %s' "$n" "$table"
}

# query — read-only SELECT/WITH/PRAGMA (the -readonly connection blocks writes).
tool_localdb_query() {
    local sql; sql=$(tool_arg sql); [[ -n "$sql" ]] || { printf 'sql (a SELECT) required'; return 1; }
    [[ "$sql" =~ ^[[:space:]]*([Ss][Ee][Ll][Ee][Cc][Tt]|[Ww][Ii][Tt][Hh]|[Pp][Rr][Aa][Gg][Mm][Aa]) ]] \
        || { printf 'only SELECT/WITH/PRAGMA is allowed here (use localdb_exec for writes)'; return 1; }
    scratchdb_readonly "$sql" 2>&1
}

# update — a full UPDATE statement (confirm); reports rows affected.
tool_localdb_update() {
    local sql; sql=$(tool_arg sql)
    [[ "$sql" =~ ^[[:space:]]*[Uu][Pp][Dd][Aa][Tt][Ee] ]] || { printf 'sql must be an UPDATE statement'; return 1; }
    confirm_action "Run UPDATE on the scratch db" "$sql" || { confirm_denied_msg; return 1; }
    scratchdb_exec "${sql%;}; SELECT changes() AS rows_affected;" 2>&1
}

# delete — a full DELETE statement (confirm); reports rows affected.
tool_localdb_delete() {
    local sql; sql=$(tool_arg sql)
    [[ "$sql" =~ ^[[:space:]]*[Dd][Ee][Ll][Ee][Tt][Ee] ]] || { printf 'sql must be a DELETE statement'; return 1; }
    confirm_action "Run DELETE on the scratch db" "$sql" || { confirm_denied_msg; return 1; }
    scratchdb_exec "${sql%;}; SELECT changes() AS rows_affected;" 2>&1
}

# import — load a .csv or .json file into a table.
tool_localdb_import() {
    local file table
    file=$(tool_arg file); table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed'; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    case "$file" in
        *.csv)
            # The path is interpolated into a sqlite `.import "…"` dot-command; a
            # filename containing a double quote (or newline/backslash) would break
            # out of that argument and inject further dot-commands. path_check_allowed
            # confines WHERE the file lives, not its byte content — so reject those
            # bytes here. `.import --csv` (SQLite ≥ 3.32, 2020) also skips the
            # separate `.mode csv` and imports straight from the vetted path.
            case "$file" in
                *'"'*|*'\'*|*$'\n'*) printf 'refused: import path must not contain quotes, backslashes, or newlines'; return 1 ;;
            esac
            scratchdb_exec ".import --csv \"$file\" $table" 2>&1 && printf 'imported CSV into %s' "$table" ;;
        *.json)
            local rows n out
            rows=$(jq -c 'if type=="array" then . else [.] end' "$file" 2>/dev/null) || { printf 'invalid JSON file'; return 1; }
            n=$(printf '%s' "$rows" | jq 'length' 2>/dev/null)
            [[ "$n" =~ ^[0-9]+$ ]] || { printf 'invalid JSON file'; return 1; }
            (( n == 0 )) && { printf 'no rows to import'; return 0; }
            out=$(_localdb_bulk_insert "$table" "$rows") || { printf '%s' "$out"; return 1; }
            [[ -n "$out" ]] && printf '%s\n' "$out"
            printf 'imported %s JSON row(s) into %s' "$n" "$table" ;;
        *) printf 'unsupported file type (use .csv or .json)'; return 1 ;;
    esac
}

# export — dump a table as csv (default) or json.
tool_localdb_export() {
    local table fmt
    table=$(_localdb_ident "$(tool_arg table)") || { printf 'invalid or missing table name'; return 1; }
    fmt=$(tool_arg format csv)
    case "$fmt" in
        json) scratchdb_query "SELECT * FROM $table;" 2>&1 ;;
        *)    scratchdb_exec ".mode csv" ".headers on" "SELECT * FROM $table;" 2>&1 ;;
    esac
}

# exec — arbitrary SQL escape hatch (confirm).
tool_localdb_exec() {
    local sql; sql=$(tool_arg sql); [[ -n "$sql" ]] || { printf 'sql required'; return 1; }
    # Keep the scratch db isolated (its whole promise): ATTACH could reach
    # .harness.db or any host SQLite file, and readfile/writefile/load_extension
    # run at the sqlite-CLI level and escape the sandbox entirely — they ignore
    # -readonly. Refuse them; ordinary DDL/DML on the scratch db is still allowed.
    if printf '%s' "$sql" | grep -qiE '\b(attach|detach|readfile|writefile|load_extension)\b'; then
        printf 'refused: ATTACH/DETACH and readfile/writefile/load_extension are not allowed on the scratch db (they escape its isolation).'
        return 1
    fi
    confirm_action "Run arbitrary SQL on the scratch db" "$sql" || { confirm_denied_msg; return 1; }
    scratchdb_exec "$sql" 2>&1
}

# vacuum — compact the scratch db.
tool_localdb_vacuum() {
    scratchdb_exec "VACUUM;" 2>&1 && printf 'vacuumed scratch db'
}

# reset — delete the entire scratch db file (confirm).
tool_localdb_reset() {
    local db; db=$(_localdb_path)
    confirm_action "DELETE the entire scratch db ($db)" "rm $db" || { confirm_denied_msg; return 1; }
    rm -f "$db" "$db-wal" "$db-shm" 2>/dev/null
    _localdb_ready=0
    printf 'scratch db reset (%s removed)' "$db"
}

# ── Register (category: localdb; all complexity=low, static — no LLM) ────────
tool_register "localdb_tables"  tool_localdb_tables  '{"type":"object","properties":{}}' safe all localdb
tool_register "localdb_schema"  tool_localdb_schema  '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}},"required":["table"]}' safe all localdb
tool_register "localdb_create"  tool_localdb_create  '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"},"columns":{"type":"string","description":"col defs e.g. \"id INTEGER PRIMARY KEY, name TEXT\""},"sql":{"type":"string","description":"a full CREATE TABLE statement (alternative to table+columns)"}},"required":["table","columns"]}' writes all localdb
tool_register "localdb_drop"    tool_localdb_drop    '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"}},"required":["table"]}' writes all localdb
tool_register "localdb_insert"  tool_localdb_insert  '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"},"rows":{"type":"string","description":"a JSON object (one row) or array of objects (bulk)"}},"required":["table","rows"]}' writes all localdb
tool_register "localdb_query"   tool_localdb_query   '{"type":"object","properties":{"sql":{"type":"string","description":"a SELECT statement"}},"required":["sql"]}' safe all localdb
tool_register "localdb_update"  tool_localdb_update  '{"type":"object","properties":{"sql":{"type":"string","description":"a full UPDATE statement"}},"required":["sql"]}' writes all localdb
tool_register "localdb_delete"  tool_localdb_delete  '{"type":"object","properties":{"sql":{"type":"string","description":"a full DELETE statement"}},"required":["sql"]}' writes all localdb
tool_register "localdb_import"  tool_localdb_import  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"table":{"type":"string","description":"the database table name"}},"required":["file","table"]}' writes all localdb
tool_register "localdb_export"  tool_localdb_export  '{"type":"object","properties":{"table":{"type":"string","description":"the database table name"},"format":{"type":"string","description":"csv|json (default csv)"}},"required":["table"]}' safe all localdb
tool_register "localdb_exec"    tool_localdb_exec    '{"type":"object","properties":{"sql":{"type":"string","description":"arbitrary SQL (guarded/confirmed)"}},"required":["sql"]}' writes all localdb
tool_register "localdb_vacuum"  tool_localdb_vacuum  '{"type":"object","properties":{}}' safe all localdb
tool_register "localdb_reset"   tool_localdb_reset   '{"type":"object","properties":{}}' writes all localdb
