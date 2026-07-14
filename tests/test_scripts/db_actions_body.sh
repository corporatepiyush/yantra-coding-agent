#!/usr/bin/env bash
# tests/test_scripts/db_actions_body.sh — the Database act-half:
#   • data_export — fenced, gated, no-clobber; read-only-query enforced by
#     _data_sql_readonly AND a sandbox EXPLAIN oracle that blocks a direct
#     FROM '<path>'/'<url>' exfil the regex can't see.
#   • xlsx reader — schema/head/query accept .xlsx via _data_reader (read_xlsx).
# The data_export/xlsx assertions use the real duckdb when it is present.
# Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1" YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json; YCA_CAT_ENABLED[data]=1
fail(){ echo "FAIL: $1"; exit 1; }

W="$2/work"; mkdir -p "$W"

# ── Registration danger tokens ───────────────────────────────────────────────
# Every write MUST carry a gated token so the machine-mode consent gate catches
# it. Registry entry = fn|danger|agents|cat|cx ; workflow = fn|tier|danger|…
info="${YCA_TOOL_REGISTRY[data_export]:-}"; [[ -n "$info" ]] || fail "data_export not registered"
IFS='|' read -r _fn dg _rest <<< "$info"; [[ "$dg" == "writes" ]] || fail "data_export danger='$dg' (want writes)"

# ── data_export (needs duckdb; _data_guard gates on it) ──────────────────────
CSV="$W/t.csv"; printf 'id,name\n1,alice\n2,bob\n' > "$CSV"
if command -v duckdb >/dev/null 2>&1; then
    # 1) OUT-path fence: an out OUTSIDE YCA_SAFETY_PATHS (=$2) is refused, no write.
    esc="/tmp/yca_db_escape_$$"
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$esc.csv\",\"format\":\"csv\"}" 2>&1 || true)
    echo "$out" | grep -qi 'not allowed' || fail "data_export allowed an out outside the fence ($out)"
    [[ ! -e "$esc.csv" ]] || { rm -f "$esc.csv"; fail "data_export wrote outside the fence"; }

    # 2) read-only-query enforcement: a read_*() file function is refused BEFORE export.
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/ro.csv\",\"format\":\"csv\",\"query\":\"SELECT * FROM read_csv_auto('/etc/passwd')\"}" 2>&1 || true)
    echo "$out" | grep -qi 'refused' || fail "data_export allowed a non-read-only query ($out)"
    [[ ! -e "$W/ro.csv" ]] || fail "data_export wrote despite a refused query"

    # 3) sandbox-oracle exfil block: a direct FROM '<path>' (invisible to the regex)
    #    is refused by the EXPLAIN-under-no-external-access oracle; nothing written.
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/exfil.csv\",\"format\":\"csv\",\"query\":\"SELECT * FROM '/etc/passwd'\"}" 2>&1 || true)
    echo "$out" | grep -qi 'refused' || fail "data_export sandbox oracle let a direct FROM path through ($out)"
    [[ ! -e "$W/exfil.csv" ]] || fail "data_export wrote an exfil file"

    # 4) bogus format rejected.
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/x.zzz\",\"format\":\"zzz\"}" 2>&1 || true)
    echo "$out" | grep -qi 'format must be' || fail "data_export accepted a bogus format ($out)"

    # 5) HAPPY PATH: fenced parquet export through a read-only transform succeeds.
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/out.parquet\",\"format\":\"parquet\",\"query\":\"SELECT name FROM this WHERE id=1\"}" 2>&1 || true)
    [[ -f "$W/out.parquet" ]] || fail "data_export did not write the parquet ($out)"
    duckdb -noheader -list -c "SELECT name FROM read_parquet('$W/out.parquet');" 2>/dev/null | grep -qx 'alice' \
        || fail "exported parquet has wrong contents ($out)"

    # 6) no-clobber: overwriting an existing out needs confirmation, which json mode
    #    without auto_confirm auto-denies — the existing file is left intact.
    printf 'KEEP' > "$W/keep.csv"; YCA_AUTO_CONFIRM=false
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/keep.csv\",\"format\":\"csv\"}" 2>&1 || true)
    echo "$out" | grep -qiE 'cancel|confirm' || fail "data_export clobbered without confirmation ($out)"
    [[ "$(<"$W/keep.csv")" == "KEEP" ]] || fail "data_export overwrote a file on a denied no-clobber"
    # …with explicit consent it may overwrite.
    YCA_AUTO_CONFIRM=true
    out=$(tool_invoke data_export "{\"file\":\"$CSV\",\"out\":\"$W/keep.csv\",\"format\":\"csv\"}" 2>&1 || true)
    [[ "$(<"$W/keep.csv")" != "KEEP" ]] || fail "data_export did not overwrite with auto_confirm ($out)"
    YCA_AUTO_CONFIRM=false

    # ── xlsx reader support (schema/head/query accept .xlsx) ─────────────────
    # Build a real .xlsx fixture: COPY TO xlsx needs the excel extension LOADed;
    # reading via read_xlsx autoloads it. Assert on DATA, not header naming, so the
    # test is robust to excel header quirks.
    if duckdb -c "INSTALL excel; LOAD excel; COPY (SELECT 1 AS id, 'alice' AS name UNION ALL SELECT 2, 'bob') TO '$W/t.xlsx' (FORMAT xlsx, HEADER true);" >/dev/null 2>&1 && [[ -f "$W/t.xlsx" ]]; then
        out=$(tool_invoke data_schema "{\"file\":\"$W/t.xlsx\"}" 2>&1 || true)
        { echo "$out" | grep -qi 'column_type' && ! echo "$out" | grep -qi 'error'; } || fail "data_schema did not read xlsx ($out)"
        out=$(tool_invoke data_preview "{\"file\":\"$W/t.xlsx\"}" 2>&1 || true)
        echo "$out" | grep -qi 'alice' || fail "data_preview did not read xlsx rows ($out)"
        out=$(tool_invoke data_query "{\"file\":\"$W/t.xlsx\",\"query\":\"SELECT COUNT(*) AS n FROM this\"}" 2>&1 || true)
        echo "$out" | grep -q '2' || fail "data_query did not run over xlsx ($out)"
    fi
fi

echo "db_actions_body OK"
