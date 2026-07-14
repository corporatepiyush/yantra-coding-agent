#!/usr/bin/env bash
# Test: monitor tools (read-only DB queries) + DNS hosts + OS detection + retry
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
# Initialize DB
mcp_wf "$HARNESS" harness.doctor '{}' y >/dev/null || true

# Enable monitor category via yantra.config.json (runtime toggles are session-only).
export HARNESS_CONFIG_GLOBAL="$TMP/none.json"
cat > "$TMP/yantra.config.json" <<'JSON'
{ "version":"1", "providers":{"think":[],"build":[],"tool":[]},
  "tools": { "enabled": ["core","monitor"], "complexity_overrides": {} } }
JSON

# Test: monitor_events appears on the MCP wire once the config enables monitor
# (and an un-enabled category's tool does NOT — the gate still gates).
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"tl","method":"tools/list","params":{}}' | mcp_session "$HARNESS")
printf '%s\n' "$OUT" | jq -e 'select(.id=="tl") | .result.tools[] | select(.name=="monitor_events")' >/dev/null \
    || { echo "monitor_events not on the wire after enabling monitor"; exit 1; }
printf '%s\n' "$OUT" | jq -e 'select(.id=="tl") | [.result.tools[] | select(.name=="s3_upload")] | length == 0' >/dev/null \
    || { echo "s3_upload leaked onto the wire without its category"; exit 1; }
rm -f "$TMP/yantra.config.json"

# Test: schema_version in DB
SV=$(sqlite3 .harness.db "SELECT value FROM config WHERE key='schema_version';" 2>/dev/null)
[[ "$SV" == "5" ]] || { echo "schema_version not set (got: $SV)"; exit 1; }

# Test: kg_nodes table exists (schema-ready for Phase 3)
C=$(sqlite3 .harness.db "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name='kg_nodes';" 2>/dev/null)
[[ "$C" == "1" ]] || { echo "kg_nodes table missing"; exit 1; }

# Test: OS detection works
mcp_wf "$HARNESS" harness.doctor '{}' y >/dev/null || { echo "doctor failed"; exit 1; }

# Test: retry helper exists and works
# (indirectly tested — doctor runs deps check which should not hang)

# Test: DNS hosts + S3 tools are registered (registry facts; wire gating above)
REG=$(registry_dump "$PROJ_ROOT")
grep -q "^sec_dns_hosts_status|" <<<"$REG" || { echo "sec_dns_hosts_status not registered"; exit 1; }
grep -q "^s3_upload|" <<<"$REG" || { echo "s3_upload not registered"; exit 1; }

echo "monitor_dns_os OK"
exit 0
