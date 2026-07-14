#!/usr/bin/env bash
# Test: db→pg/mysql/redis split and search+files→fs merge, incl. new fs tools.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

REG=$(registry_dump "$PROJ_ROOT")
has()     { grep -q "^$1|" <<<"$REG"; }
missing() { grep -q "^$1|" <<<"$REG" && return 1 || return 0; }

# New split categories exist with their tools.
for t in pg_query pg_indexes mysql_query mysql_processlist redis_info redis_get; do
    has "$t" || { echo "missing $t"; exit 1; }
done
# New fs category + new fs tools.
for t in fs_search fs_tree fs_disk_usage fs_extract_archive fs_archive fs_encrypt fs_decrypt; do
    has "$t" || { echo "missing $t"; exit 1; }
done
# Old ids are gone.
for t in db_pg_query db_mysql_query db_redis_info files_dups search_grep; do
    missing "$t" || { echo "old id still present: $t"; exit 1; }
done

# Category gates: pg/mysql/redis/fs are recognized by tools.enable.
for c in pg mysql redis fs; do
    mcp_wf "$HARNESS" tools.enable "{\"category\":\"$c\"}" y >/dev/null \
        || { echo "tools.enable $c failed"; exit 1; }
done

# fs tools have ~15 and pg ~14 (meaningful expansion).
NPG=$(grep -c '|pg|' <<<"$REG")
NFS=$(grep -c '|fs|' <<<"$REG")
[[ "$NPG" -ge 10 ]] || { echo "pg has only $NPG tools"; exit 1; }
[[ "$NFS" -ge 12 ]] || { echo "fs has only $NFS tools"; exit 1; }

echo "categories_split OK"
exit 0
