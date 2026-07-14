#!/usr/bin/env bash
# Test: the `localdb` scratch-SQLite category — a full CRUD cycle over MCP,
# STRICT isolation from the internal .harness.db, and concurrent writers landing
# their rows (the busy_timeout seam).
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"
export MCP_FLAGS="--enable localdb"
Y() { local t="$1" a="${2:-}" auto="${3:-}"; mcp_call "$HARNESS" "localdb_$t" "$a" "$auto"; }

# create → insert (single + bulk) → query.
Y create '{"table":"people","columns":"id INTEGER, name TEXT"}' y | grep -qi "created" || { echo "create failed"; exit 1; }
Y insert '{"table":"people","rows":"{\"id\":1,\"name\":\"alice\"}"}' y | grep -qi "inserted" || { echo "single insert failed"; exit 1; }
Y insert '{"table":"people","rows":"[{\"id\":2,\"name\":\"bob\"},{\"id\":3,\"name\":\"cara\"}]"}' y | grep -qi "inserted" || { echo "bulk insert failed"; exit 1; }
OUT=$(Y query '{"sql":"SELECT name FROM people ORDER BY id"}')
echo "$OUT" | grep -q "alice" && echo "$OUT" | grep -q "cara" || { echo "query missing rows: $OUT"; exit 1; }

# tables + schema.
Y tables | grep -q "people" || { echo "tables did not list people"; exit 1; }
Y schema '{"table":"people"}' | grep -qi "name" || { echo "schema missing column"; exit 1; }

# query is read-only: a write via query must be rejected.
GUARD=$(Y query '{"sql":"DELETE FROM people"}') || true
echo "$GUARD" | grep -qiE "only SELECT|readonly|not allowed|denied" || { echo "query allowed a write: $GUARD"; exit 1; }

# update / delete report and take effect (with consent).
Y update '{"sql":"UPDATE people SET name='"'"'ALICE'"'"' WHERE id=1"}' y >/dev/null
Y query '{"sql":"SELECT name FROM people WHERE id=1"}' | grep -q "ALICE" || { echo "update did not apply"; exit 1; }
Y delete '{"sql":"DELETE FROM people WHERE id=3"}' y >/dev/null
Y query '{"sql":"SELECT COUNT(*) FROM people"}' | grep -q "2" || { echo "delete did not apply"; exit 1; }

# ISOLATION: the scratch db exists; no 'people' table in .harness.db.
[[ -f .yantra-scratch.db ]] || { echo "scratch db not created"; exit 1; }
if [[ -f .harness.db ]]; then
    sqlite3 .harness.db "SELECT name FROM sqlite_master WHERE name='people';" 2>/dev/null | grep -q people \
        && { echo "ISOLATION BREACH: people table leaked into .harness.db"; exit 1; }
fi

# CONCURRENCY: parallel MCP writers all land their rows (busy_timeout seam).
Y create '{"table":"nums","columns":"v INTEGER"}' y >/dev/null
w() { local i; for i in $(seq 1 15); do Y insert "{\"table\":\"nums\",\"rows\":\"{\\\"v\\\":$1}\"}" y >/dev/null 2>&1; done; }
w 1 & w 2 & w 3 & wait
CNT=$(Y query '{"sql":"SELECT COUNT(*) FROM nums"}' | tr -dc '0-9')
[[ "${CNT:-0}" -ge 45 ]] || { echo "concurrent writers lost rows (got $CNT, want >=45)"; exit 1; }

# reset drops the scratch file.
Y reset '{}' y >/dev/null
[[ -f .yantra-scratch.db ]] && { echo "reset did not remove scratch db"; exit 1; }

echo "localdb OK"
exit 0
