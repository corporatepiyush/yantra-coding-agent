#!/usr/bin/env bash
# Test: yantra.config.json is the single source of truth — auto-create, global+
# project merge with project winning, malformed handling, complexity overrides,
# provider loading, and "never persist runtime changes". (MCP)
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false
GLOBAL="$TMP/global.json"
export HARNESS_CONFIG_GLOBAL="$GLOBAL"
enabled_of() { printf '%s' "$1" | jq -r '.data.categories[]|select(.enabled==1)|.category' | sort | tr '\n' ','; }

# 1) Auto-create: no project file yet → one is written with defaults (boot once).
rm -f yantra.config.json "$GLOBAL"
printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"ping","params":{}}' | mcp_session "$HARNESS" >/dev/null
[[ -f yantra.config.json ]] || { echo "project config not auto-created"; exit 1; }
jq -e '.providers and .tools.enabled' yantra.config.json >/dev/null || { echo "auto-created config malformed"; exit 1; }
rm -f yantra.config.json

# 2) project overrides global (arrays replaced, project wins).
cat > "$GLOBAL" <<'JSON'
{ "version":"1", "tools":{"enabled":["core","ssh"]} }
JSON
cat > yantra.config.json <<'JSON'
{ "version":"1", "tools":{"enabled":["core","docker"]} }
JSON
OUT=$(mcp_wf "$HARNESS" tools.status '{}' y)
EN=$(enabled_of "$OUT")
[[ "$EN" == *"docker"* ]] || { echo "project tools.enabled not applied: $EN"; exit 1; }
[[ "$EN" != *"ssh"* ]]    || { echo "global ssh should be overridden by project: $EN"; exit 1; }
rm -f yantra.config.json "$GLOBAL"

# 3) malformed project file is ignored (not fatal) → defaults still load.
printf '{ this is not valid json ' > yantra.config.json
mcp_wf "$HARNESS" tools.status '{}' y >/dev/null || { echo "malformed config crashed startup"; exit 1; }
rm -f yantra.config.json

# 4) complexity_overrides from config apply (describe_tool replaces the catalog).
cat > yantra.config.json <<'JSON'
{ "version":"1", "tools":{"enabled":["core"],"complexity_overrides":{"read":"high"}} }
JSON
CX=$(mcp_call "$HARNESS" describe_tool '{"name":"read"}' | jq -r '.complexity')
[[ "$CX" == "high" ]] || { echo "complexity override not applied (read=$CX)"; exit 1; }
rm -f yantra.config.json

# 5) providers from the config file → LLM detected at boot (replaces cmd:config).
cat > yantra.config.json <<'JSON'
{ "version":"1", "providers":{"think":[{"url":"http://cfg-think","model":"big"}],
  "build":[], "tool":[{"url":"http://cfg-tool"}]}, "tools":{"enabled":["core"]} }
JSON
LLM=$(HARNESS_UPDATE_ENABLED=false YCA_DIR="$PROJ_ROOT" TMP="$TMP" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; cd "$TMP"
  projectconfig_load; providers_load; providers_detect
  think=$(printf "%s" "$YCA_PROVIDERS_JSON" | jq ".think | length")
  printf "%s %s" "$YCA_HAVE_LLM" "$think"')
[[ "$LLM" == "1 1" ]] || { echo "config providers did not enable LLM (got '$LLM')"; exit 1; }
rm -f yantra.config.json

# 6) runtime enable does NOT write the config file (session-only).
cat > yantra.config.json <<'JSON'
{ "version":"1", "tools":{"enabled":["core"]} }
JSON
BEFORE=$(cat yantra.config.json)
mcp_wf "$HARNESS" tools.enable '{"category":"docker"}' y >/dev/null || true
AFTER=$(cat yantra.config.json)
[[ "$BEFORE" == "$AFTER" ]] || { echo "runtime enable wrote the config file (should be session-only)"; exit 1; }
rm -f yantra.config.json

echo "projectconfig OK"
exit 0
