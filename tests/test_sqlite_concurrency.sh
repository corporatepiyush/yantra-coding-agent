#!/usr/bin/env bash
# Test: the shared _sqlite seam (lib/sql.sh) — every connection gets a
# per-connection busy_timeout so parallel writers wait instead of failing with
# "database is locked", and the timeout is set via the silent `.timeout`
# dot-command (NOT `PRAGMA busy_timeout=N`, which would echo N and corrupt output).
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"

source "$YCA_DIR/harness/lib/constants.sh"
source "$YCA_DIR/harness/lib/sql.sh"
YCA_DB_PATH="$TMP/scratch.db"

# WAL + a table.
db_exec "PRAGMA journal_mode=WAL; CREATE TABLE t(x INTEGER);" >/dev/null

# 1) Regression: db_exec output must NOT carry a leaked pragma value.
db_exec "INSERT INTO t VALUES(42);" >/dev/null
OUT=$(db_exec "SELECT x FROM t WHERE x=42;")
[[ "$OUT" == "42" ]] || { echo "db_exec output corrupted by pragma echo (got: [$OUT])"; exit 1; }

# 2) busy_timeout is actually set on the connection (non-zero).
BT=$(db_exec "PRAGMA busy_timeout;")
[[ "$BT" -ge 1000 ]] || { echo "busy_timeout not applied (got: [$BT])"; exit 1; }

# 3) Concurrent writers (simulating parallel sub-agents) all land their rows.
w() { local n; for n in $(seq 1 40); do db_exec "INSERT INTO t VALUES($1);"; done; }
w 1 & w 2 & w 3 & wait
N=$(db_exec "SELECT COUNT(*) FROM t;")
[[ "$N" -ge 121 ]] || { echo "concurrent writers lost rows (got $N, want >=121)"; exit 1; }

echo "sqlite_concurrency OK"
exit 0
