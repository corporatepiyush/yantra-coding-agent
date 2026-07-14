# workflows/data.sh — Data workflows (DuckDB query/convert/profile/join/summary).
# These are thin, format-agnostic wrappers over the hardened data_* tools: every
# path is fence-checked and every reader is chosen by extension INSIDE the tool
# (csv/tsv/parquet/json/arrow/xlsx), so the workflows stay correct for all formats
# and can't drift from the tool's security model. Delegating also fixed three real
# bugs the old hand-rolled duckdb calls had:
#   • query   — ran the SQL BEFORE the table it referenced was defined
#   • profile — a null-column cross-join that produced a broken/empty profile
#   • join    — was CSV-only (read_csv_auto on both sides), silently wrong for others

# _wf_data_run TOOL PAYLOAD SUMMARY — invoke a data_* tool, surface its output to
# the human stream, and translate the exit code into the workflow result frame.
_wf_data_run() {
    local tool="$1" payload="$2" summary="$3" out rc
    out=$(tool_invoke "$tool" "$payload"); rc=$?
    printf '%s\n' "$out"                                  # human-facing (→ stderr in run_workflow)
    if (( rc == 0 )); then emit_ok "$summary"; else emit_fail "${out:0:400}"; return 1; fi
}

wf_data_query() {
    local file="${INPUT_file:-}" sql="${INPUT_query:-${INPUT_sql:-SELECT * FROM this LIMIT 10}}"
    val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    _wf_data_run data_query "$(jq -n --arg f "$file" --arg q "$sql" '{file:$f,query:$q}')" "query done"
}

wf_data_summary() {
    local file="${INPUT_file:-}"
    val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    _wf_data_run data_schema "$(jq -n --arg f "$file" '{file:$f}')" "summary done"
}

wf_data_convert() {
    local file="${INPUT_file:-}" fmt="${INPUT_format:-parquet}"
    val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    _wf_data_run data_convert "$(jq -n --arg f "$file" --arg t "$fmt" '{file:$f,format:$t}')" "converted $file"
}

wf_data_profile() {
    local file="${INPUT_file:-}"
    val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    _wf_data_run data_profile "$(jq -n --arg f "$file" '{file:$f}')" "profile complete"
}

wf_data_join() {
    local left="${INPUT_left:-}" right="${INPUT_right:-}" on="${INPUT_on:-}"
    val_required "$left" "INPUT_left"   || { emit_fail "INPUT_left required"; return 1; }
    val_required "$right" "INPUT_right" || { emit_fail "INPUT_right required"; return 1; }
    val_required "$on" "INPUT_on"       || { emit_fail "INPUT_on required"; return 1; }
    path_check_allowed "$left"  || { emit_fail "path not allowed: $left"; return 1; }
    path_check_allowed "$right" || { emit_fail "path not allowed: $right"; return 1; }
    _wf_data_run data_join "$(jq -n --arg l "$left" --arg r "$right" --arg o "$on" '{file:$l,right:$r,on:$o}')" "join complete"
}

# data.diff — "what changed between these two exports?" A schema diff (added /
# removed columns), row counts, set-difference counts both directions with up to
# 10 sample differing rows, and — when a .key column is given — added / removed /
# changed key counts. Format-agnostic via the hardened _data_reader (csv, tsv,
# parquet, json, arrow, xlsx). The only user-controlled SQL token is the key,
# which is validated to a bare column identifier; everything else is fixed.
wf_data_diff() {
    _data_have || { emit_fail "duckdb required — brew install duckdb"; return 1; }
    local left="${INPUT_left:-${INPUT_file:-}}" right="${INPUT_right:-}"
    val_required "$left" "INPUT_left"   || { emit_fail "INPUT_left required"; return 1; }
    val_required "$right" "INPUT_right" || { emit_fail "INPUT_right required"; return 1; }
    path_check_allowed "$left"  || { emit_fail "path not allowed: $left"; return 1; }
    path_check_allowed "$right" || { emit_fail "path not allowed: $right"; return 1; }
    [[ -f "$left"  ]] || { emit_fail "file not found: $left"; return 1; }
    [[ -f "$right" ]] || { emit_fail "file not found: $right"; return 1; }
    local lr rr
    lr=$(_data_reader "$left")  || { emit_fail "unsupported format: $left"; return 1; }
    rr=$(_data_reader "$right") || { emit_fail "unsupported format: $right"; return 1; }
    local key="${INPUT_key:-}"
    if [[ -n "$key" ]]; then
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || { emit_fail "key must be a bare column name (letters/digits/_)"; return 1; }
    fi

    emit_progress "diff" "comparing $left ↔ $right" 40
    logmsg "$(c_info '── columns (only-in-one) ──')"
    duckdb -box -c "
      WITH l AS (SELECT column_name FROM (DESCRIBE SELECT * FROM $lr)),
           r AS (SELECT column_name FROM (DESCRIBE SELECT * FROM $rr))
      SELECT 'only in left'  AS side, column_name FROM l WHERE column_name NOT IN (SELECT column_name FROM r)
      UNION ALL
      SELECT 'only in right' AS side, column_name FROM r WHERE column_name NOT IN (SELECT column_name FROM l);" 2>&1 \
      | { grep -q . && sed 's/^/  /' || printf '  (identical column sets)\n'; } >&2

    logmsg "$(c_info '── row counts ──')"
    duckdb -box -c "
      SELECT (SELECT count(*) FROM $lr) AS left_rows,
             (SELECT count(*) FROM $rr) AS right_rows,
             (SELECT count(*) FROM (SELECT * FROM $lr EXCEPT SELECT * FROM $rr)) AS only_in_left,
             (SELECT count(*) FROM (SELECT * FROM $rr EXCEPT SELECT * FROM $lr)) AS only_in_right;" 2>&1 | sed 's/^/  /' >&2

    logmsg "$(c_info '── sample rows only in LEFT (max 10) ──')"
    duckdb -box -c "SELECT * FROM $lr EXCEPT SELECT * FROM $rr LIMIT 10;" 2>&1 | sed 's/^/  /' >&2
    logmsg "$(c_info '── sample rows only in RIGHT (max 10) ──')"
    duckdb -box -c "SELECT * FROM $rr EXCEPT SELECT * FROM $lr LIMIT 10;" 2>&1 | sed 's/^/  /' >&2

    if [[ -n "$key" ]]; then
        logmsg "$(c_info "── keyed changes on \"$key\" ──")"
        duckdb -box -c "
          WITH lonly AS (SELECT * FROM $lr EXCEPT SELECT * FROM $rr),
               ronly AS (SELECT * FROM $rr EXCEPT SELECT * FROM $lr)
          SELECT
            (SELECT count(*) FROM (SELECT \"$key\" FROM $rr EXCEPT SELECT \"$key\" FROM $lr))            AS added_keys,
            (SELECT count(*) FROM (SELECT \"$key\" FROM $lr EXCEPT SELECT \"$key\" FROM $rr))            AS removed_keys,
            (SELECT count(*) FROM (
               SELECT \"$key\" FROM lonly WHERE \"$key\" IN (SELECT \"$key\" FROM $rr)
               INTERSECT
               SELECT \"$key\" FROM ronly WHERE \"$key\" IN (SELECT \"$key\" FROM $lr)))                AS changed_keys;" 2>&1 | sed 's/^/  /' >&2
    fi
    emit_ok "data.diff complete: $left ↔ $right"
}

wf_register "data.query"    wf_data_query    1 safe   "duckdb" "Query a data file (SQL over the table 'this')"
wf_register "data.diff"     wf_data_diff     1 safe   "duckdb" "Diff two data files: schema, row counts, sample + keyed changes"
wf_register "data.summary"  wf_data_summary  1 safe   "duckdb" "Summarize a data file (schema)"
wf_register "data.convert"  wf_data_convert  1 writes "duckdb" "Convert data format (csv/parquet/json)"
wf_register "data.profile"  wf_data_profile  1 safe   "duckdb" "Profile data (stats, nulls, types)"
wf_register "data.join"     wf_data_join     1 safe   "duckdb" "Join two data files on a shared column"
