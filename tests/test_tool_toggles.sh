#!/usr/bin/env bash
# Test: tool category toggles. Runtime enable/disable is SESSION-ONLY (never
# persisted); yantra.config.json (tools.enabled) is the way to persist. (MCP)
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1

export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

status_payload() { mcp_wf "$HARNESS" tools.status '{}' y; }
enabled_of() { printf '%s' "$1" | jq -r '.data.categories[] | select(.enabled==1) | .category' | sort | tr '\n' ','; }

# Default (no config providers, no enabled cats beyond core): only core on.
OUT=$(status_payload) || { echo "tools.status failed"; exit 1; }
ENABLED=$(enabled_of "$OUT")
[[ "$ENABLED" == "core," ]] || { echo "default toggles wrong: got '$ENABLED' expected 'core,'"; exit 1; }

# Enable pg + verify WITHIN the same session (two calls, one server process).
OUT=$(mcp_session "$HARNESS" y <<'EOF'
{"jsonrpc":"2.0","id":"e1","method":"tools/call","params":{"name":"wf__tools_enable","arguments":{"category":"pg"}}}
{"jsonrpc":"2.0","id":"s2","method":"tools/call","params":{"name":"wf__tools_status","arguments":{}}}
EOF
)
printf '%s\n' "$OUT" | jq -e 'select(.id=="e1") | .result.isError == false' >/dev/null || { echo "enable pg failed"; exit 1; }
printf '%s\n' "$OUT" | jq -e 'select(.id=="s2") | .result.content[0].text | fromjson | .data.categories[] | select(.category=="pg" and .enabled==1)' >/dev/null \
    || { echo "pg not enabled in-session after tools.enable"; exit 1; }

# Session-only: a FRESH process must NOT see pg enabled.
OUT=$(status_payload)
printf '%s' "$OUT" | jq -e '.data.categories[] | select(.category=="pg" and .enabled==1)' >/dev/null \
    && { echo "pg toggle leaked across sessions (should be session-only)"; exit 1; }

# yantra.config.json is the persistence mechanism.
cat > "$TMP/yantra.config.json" <<'JSON'
{ "version":"1", "providers":{"think":[],"build":[],"tool":[]},
  "tools": { "enabled": ["core","pg"], "complexity_overrides": {} } }
JSON
OUT=$(status_payload)
printf '%s' "$OUT" | jq -e '.data.categories[] | select(.category=="pg" and .enabled==1)' >/dev/null \
    || { echo "config-file tools.enabled did not enable pg"; exit 1; }
rm -f "$TMP/yantra.config.json"

# Unknown category -> fail.
mcp_wf "$HARNESS" tools.enable '{"category":"nonexistent"}' y >/dev/null && { echo "unknown category should fail"; exit 1; }

# Cannot disable core.
mcp_wf "$HARNESS" tools.disable '{"category":"core"}' y >/dev/null && { echo "should not disable core"; exit 1; }

echo "tool_toggles OK"
exit 0
