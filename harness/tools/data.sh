# tools/data.sh — Data analysis tools (duckdb-backed) + LLM insights.
# Turns "I have a CSV/Parquet and don't know what's in it" into senior-grade
# analysis: schema inference, profiling, SQL, joins, and plain-English insights.
# All read-only unless converting. Falls back gracefully when duckdb is absent.

_data_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_data_have()    { command -v duckdb &>/dev/null; }

# Excel reader selection. DuckDB 1.5+ ships a NATIVE read_xlsx (it autoloads the
# `excel` extension on first use — no network/LOAD needed). Older builds only
# expose the spatial extension's st_read. Probe ONCE (memoized in _data_xlsx_fn)
# with a FIXED non-existent filename so no caller input ever reaches this SQL: if
# read_xlsx resolves we get a file/IO error; if the function is unknown we get a
# Catalog/"does not exist" error — the signal to fall back to st_read.
_data_xlsx_fn=""
_data_excel_reader() {
    if [[ -z "$_data_xlsx_fn" ]]; then
        local probe
        probe=$(duckdb -c "SELECT 1 FROM read_xlsx('__yca_xlsx_probe__.xlsx') LIMIT 0;" 2>&1)
        case "$probe" in
            *"does not exist"*|*"not in the catalog"*|*"Catalog Error"*) _data_xlsx_fn="st_read" ;;
            *) _data_xlsx_fn="read_xlsx" ;;
        esac
    fi
    printf "%s('%s')" "$_data_xlsx_fn" "$1"
}

# Pick the right duckdb reader for a file by extension.
_data_reader() {
    local file="$1"
    case "$(path_ext "$file")" in
        csv|tsv|txt)     printf "read_csv_auto('%s')" "$file" ;;
        parquet)         printf "read_parquet('%s')" "$file" ;;
        json|ndjson)     printf "read_json_auto('%s')" "$file" ;;
        arrow|feather)   printf "read_parquet('%s')" "$file" ;;
        xlsx|xls)        _data_excel_reader "$file" ;;
        *)               return 1 ;;
    esac
}

_data_guard() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    _data_have || { _data_missing duckdb "brew install duckdb"; return 1; }
}

# _data_sql_readonly SQL -> 0 if SQL is a single statement free of the duckdb
# verbs/functions that reach the filesystem or network. Combined with
# `SET enable_external_access=false` (applied AFTER the input file is materialized
# into `this`), a "query" can only read the already-loaded table — no COPY..TO a
# path, no ATTACH, no read_*('/etc/passwd'), no httpfs exfil. Proven-exploitable
# before this guard existed.
_data_sql_readonly() {
    local s="$1"
    [[ -z "$s" ]] && return 1
    sql_single_stmt "$s" || return 1
    printf '%s' "$s" | grep -qiE '(read_[a-z_]+[[:space:]]*\(|\b(attach|detach|copy|install|load|export|pragma|set|glob)\b)' && return 1
    return 0
}

# schema — infer column names, types, nullability.
tool_data_schema() {
    local file="$1"; _data_guard "$file" || return 1
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported format: %s' "$file"; return 1; }
    duckdb -box -c "DESCRIBE SELECT * FROM $reader;" 2>&1
}

# profile — row count, per-column null counts, distinct counts, min/max.
tool_data_profile() {
    local file="$1"; _data_guard "$file" || return 1
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported format: %s' "$file"; return 1; }
    duckdb -box -c "SUMMARIZE SELECT * FROM $reader;" 2>&1
}

# head — preview first N rows (default 10).
tool_data_preview() {
    local file="$1" n; n=$(tool_arg lines 10); _data_guard "$file" || return 1
    [[ "$n" =~ ^[0-9]+$ ]] || n=10
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported format: %s' "$file"; return 1; }
    duckdb -box -c "SELECT * FROM $reader LIMIT $n;" 2>&1
}

# query — run arbitrary SQL. Reference the file as the table 'this' (a view).
# NOTE: read `file` via tool_arg — the generic positional dispatch maps both
# `file` and `query` to arg1 and `query` would otherwise win.
tool_data_query() {
    local file; file=$(tool_arg file "$1"); _data_guard "$file" || return 1
    local sql; sql=$(tool_arg query "$(tool_arg sql 'SELECT * FROM this LIMIT 10')")
    _data_sql_readonly "$sql" || { printf 'refused: the query must be a single read-only statement — no ; chaining, and no COPY/ATTACH/INSTALL/LOAD/PRAGMA/SET or read_*() file functions. Use data_export/data_convert to write a file.'; return 1; }
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported format: %s' "$file"; return 1; }
    # Materialize the (path-checked) input into `this` FIRST, then disable
    # external filesystem/network access before running the user SQL — so the
    # query can only touch `this`, never COPY..TO a path, read /etc/passwd via
    # read_text(), or exfiltrate via httpfs.
    duckdb -box -c "CREATE TABLE this AS SELECT * FROM $reader; SET enable_external_access=false; $sql;" 2>&1
}

# join — join two files on a shared column, preview the result.
tool_data_join() {
    local left="$1" right; right=$(tool_arg right)
    local on; on=$(tool_arg on)
    _data_guard "$left" || return 1
    [[ -n "$right" && -n "$on" ]] || { printf 'right and on required'; return 1; }
    path_check_allowed "$right" 2>/dev/null || { printf 'path not allowed: %s' "$right"; return 1; }
    local lr rr; lr=$(_data_reader "$left") && rr=$(_data_reader "$right") || { printf 'unsupported format'; return 1; }
    duckdb -box -c "SELECT * FROM $lr l JOIN $rr r ON l.\"$on\" = r.\"$on\" LIMIT 100;" 2>&1
}

# convert — csv <-> parquet <-> json. Writes alongside the source.
tool_data_convert() {
    local file="$1"; _data_guard "$file" || return 1
    local fmt; fmt=$(str_lower "$(tool_arg format parquet)")
    local out="${file%.*}.$fmt" reader
    path_check_allowed "$out" || { printf 'output path not allowed: %s' "$out"; return 1; }
    if [[ -e "$out" && "$out" != "$file" ]]; then
        confirm_action "Overwrite existing file $out" "duckdb COPY -> $out" || { confirm_denied_msg; return 1; }
    fi
    reader=$(_data_reader "$file") || { printf 'unsupported source format'; return 1; }
    case "$fmt" in
        parquet) duckdb -c "COPY (SELECT * FROM $reader) TO '$out' (FORMAT PARQUET);" 2>&1 ;;
        csv)     duckdb -c "COPY (SELECT * FROM $reader) TO '$out' (FORMAT CSV, HEADER);" 2>&1 ;;
        json)    duckdb -c "COPY (SELECT * FROM $reader) TO '$out' (FORMAT JSON);" 2>&1 ;;
        *)       printf 'target format must be parquet|csv|json'; return 1 ;;
    esac
    printf 'converted %s -> %s' "$file" "$out"
}

# export — write a file (csv|parquet|json) from a data file, optionally through a
# read-only transform query. This is the FENCED, GATED replacement for the raw
# `COPY ... TO <path>` that the query tool used to allow (an arbitrary-write hole).
# The OUT path is path-checked (must live inside the fence) and never silently
# clobbered. An optional `query` is (1) validated read-only by _data_sql_readonly
# and (2) proven — by a sandboxed EXPLAIN with external filesystem/network access
# DISABLED — to touch nothing but the input's `this` table, so it can't
# `FROM '/etc/passwd'`/`FROM 'https://…'` (a direct-file source _data_sql_readonly
# can't see) to exfiltrate an out-of-fence file into the writable output.
tool_data_export() {
    local file; file=$(tool_arg file "${1:-}"); _data_guard "$file" || return 1
    local out; out=$(tool_arg out)
    [[ -n "$out" ]] || { printf 'out (destination path) required'; return 1; }
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed: %s' "$out"; return 1; }
    local fmt; fmt=$(str_lower "$(tool_arg format csv)")
    local copyfmt
    case "$fmt" in
        csv)     copyfmt='FORMAT CSV, HEADER' ;;
        parquet) copyfmt='FORMAT PARQUET' ;;
        json)    copyfmt='FORMAT JSON' ;;
        *)       printf 'format must be csv|parquet|json'; return 1 ;;
    esac
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported source format: %s' "$file"; return 1; }
    # Optional transform query — a single read-only statement over `this`.
    local query; query=$(tool_arg query '')
    local inner="SELECT * FROM $reader"
    if [[ -n "$query" ]]; then
        _data_sql_readonly "$query" || { printf 'refused: the query must be a single read-only statement — no ; chaining, and no COPY/ATTACH/INSTALL/LOAD/PRAGMA/SET or read_*() file functions.'; return 1; }
        # rstrip + drop one trailing ';' so it embeds inside COPY( … ).
        query="${query%"${query##*[![:space:]]}"}"; query="${query%;}"
        query="${query%"${query##*[![:space:]]}"}"
        # Sandbox oracle: BIND (EXPLAIN, no data moved) the query against a schema-
        # only `this` with external access OFF. A direct FROM '<path>'/'<url>' hits a
        # Permission Error here and is refused; a query that reads only `this` binds.
        if ! duckdb -c "CREATE TABLE this AS SELECT * FROM $reader LIMIT 0; SET enable_external_access=false; EXPLAIN $query;" >/dev/null 2>&1; then
            printf 'refused: the query must read ONLY the input (the table `this`) — it references an external file/URL, or is otherwise invalid.'
            return 1
        fi
        inner="$query"
    fi
    # No silent clobber.
    if [[ -e "$out" ]]; then
        confirm_action "Overwrite existing file $out" "duckdb COPY -> $out" || { confirm_denied_msg; return 1; }
    fi
    local copysql
    if [[ -n "$query" ]]; then
        copysql="CREATE TABLE this AS SELECT * FROM $reader; COPY ($inner) TO $(sql_quote "$out") ($copyfmt);"
    else
        copysql="COPY ($inner) TO $(sql_quote "$out") ($copyfmt);"
    fi
    duckdb -c "$copysql" 2>&1 && printf 'exported %s -> %s (%s)' "$file" "$out" "$fmt"
}

# llm_insights — profile the data, then ask the LLM for plain-English findings.
# Sends only the schema + summary stats (never the raw rows) to keep tokens low.
tool_data_llm_insights() {
    local file="$1"; _data_guard "$file" || return 1
    local reader; reader=$(_data_reader "$file") || { printf 'unsupported format'; return 1; }
    local schema summary sample
    schema=$(duckdb -c "DESCRIBE SELECT * FROM $reader;" 2>&1)
    summary=$(duckdb -c "SUMMARIZE SELECT * FROM $reader;" 2>&1)
    sample=$(duckdb -c "SELECT * FROM $reader LIMIT 5;" 2>&1)
    local combined
    combined=$(printf '=== SCHEMA ===\n%s\n\n=== SUMMARY STATS ===\n%s\n\n=== SAMPLE (5 rows) ===\n%s' \
        "$schema" "$summary" "$sample")
    local system_prompt='You are a senior data analyst. Given a dataset schema, summary statistics, and a small sample, report: (1) what this dataset appears to represent, (2) data quality issues (nulls, outliers, suspicious types, duplicates hints), (3) 3-5 concrete analysis questions worth asking, each with the DuckDB SQL to answer it. Be concise. Only use facts present in the stats — do not invent columns or values.'
    llm_analyze "$system_prompt" "$combined"
}

tool_data_doctor() {
    local out=""
    out+="duckdb: $(command -v duckdb &>/dev/null && duckdb --version 2>&1 | head -1 || printf 'MISSING (brew install duckdb)')\n"
    out+="jq: $(command -v jq &>/dev/null && printf 'ok' || printf 'MISSING')\n"
    out+="csvkit: $(command -v csvstat &>/dev/null && printf 'ok' || printf 'not installed (pip install csvkit)')\n"
    out+="sqlite3: $(command -v sqlite3 &>/dev/null && printf 'ok' || printf 'MISSING')\n"
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "data_schema"       tool_data_schema       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all data
tool_register "data_profile"      tool_data_profile      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all data
tool_register "data_preview"         tool_data_preview         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"lines":{"type":"integer","description":"number of lines to return"}},"required":["file"]}' safe all data
tool_register "data_query"        tool_data_query        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"query":{"type":"string","description":"SQL; reference the file as table this"}},"required":["file","query"]}' safe all data
tool_register "data_join"         tool_data_join         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"right":{"type":"string","description":"the right"},"on":{"type":"string","description":"the on"}},"required":["file","right","on"]}' safe all data
tool_register "data_convert"      tool_data_convert      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"format":{"type":"string","enum":["parquet","csv","json"],"description":"the output format"}},"required":["file","format"]}' writes all data
tool_register "data_export"       tool_data_export       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"out":{"type":"string","description":"destination path (must be inside the safety fence)"},"format":{"type":"string","enum":["csv","parquet","json"],"description":"the output format"},"query":{"type":"string","description":"optional read-only transform over the input table `this`"}},"required":["file","out","format"]}' writes all data
tool_register "data_llm_insights" tool_data_llm_insights '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all data mid
tool_register "data_doctor"       tool_data_doctor       '{"type":"object","properties":{}}' safe all data
