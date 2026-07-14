#!/usr/bin/env bash
# Test: DB lifecycle — init, WAL mode, tables, cleanup
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
# Init DB via a workflow
mcp_wf "$HARNESS" harness.doctor '{}' y >/dev/null || true

[[ -f .harness.db ]] || { echo "DB not created"; exit 1; }

# WAL mode
MODE=$(sqlite3 .harness.db "PRAGMA journal_mode;" 2>/dev/null)
[[ "$MODE" == "wal" ]] || { echo "WAL not enabled (got $MODE)"; exit 1; }

# All expected tables
for t in config skills events heartbeats tasks messages changes versions search_fts; do
    C=$(sqlite3 .harness.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='$t';" 2>/dev/null || echo 0)
    [[ "$C" == "1" ]] || { echo "table missing: $t"; exit 1; }
done

# Version recorded
C=$(sqlite3 .harness.db "SELECT COUNT(*) FROM versions;" 2>/dev/null || echo 0)
[[ "$C" -ge 1 ]] || { echo "no version recorded"; exit 1; }

# Second invocation (no lock contention)
mcp_wf "$HARNESS" harness.doctor '{}' y >/dev/null \
    || { echo "second invocation failed (lock?)"; exit 1; }

echo "db OK"
exit 0
