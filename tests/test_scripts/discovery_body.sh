#!/usr/bin/env bash
# tests/test_scripts/discovery_body.sh — T11 discovery, REAL test.
# Intent facet + golden danger->intent mapping, the search backend (ranking +
# typo tolerance), the search_tools/describe_tool meta-tools, the default wire
# cap (D6), and enable_category consent + tools/list_changed over MCP. Args: $1 $2
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null </dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=plain; YCA_AUTO_CONFIRM=true
YCA_CAT_ENABLED[core]=1
fail(){ echo "FAIL: $1"; exit 1; }

# ── 1. Intent facet: every tool has one of the four; golden danger mapping ────
valid='^(discovery|verify|transform|execute)$'
bad=""
for t in "${!YCA_TOOL_REGISTRY[@]}"; do
    it=$(tool_intent "$t")
    [[ "$it" =~ $valid ]] || { bad="$t=$it"; break; }
done
[[ -z "$bad" ]] || fail "a tool has an out-of-set intent: $bad"
for w in "${!YCA_WF_REGISTRY[@]}"; do
    it=$(wf_intent "$w")
    [[ "$it" =~ $valid ]] || fail "workflow $w has an out-of-set intent: $it"
done
# golden danger -> intent defaults (representative)
[[ "$(_intent_from x safe)" == "discovery" ]]        || fail "safe should map to discovery"
[[ "$(_intent_from x writes)" == "transform" ]]      || fail "writes should map to transform"
[[ "$(_intent_from x destructive)" == "execute" ]]   || fail "destructive should map to execute"
[[ "$(_intent_from x dangerous)" == "execute" ]]     || fail "dangerous should map to execute"
[[ "$(_intent_from go_test safe)" == "verify" ]]     || fail "a safe test/lint tool should map to verify"
# concrete tools
[[ "$(tool_intent read)" == "discovery" ]]  || fail "read intent wrong"
[[ "$(tool_intent write)" == "transform" ]] || fail "write intent wrong"

# ── 2. Search backend: ranking + typo tolerance (golden-ish) ──────────────────
res=$(discovery_search "docker containers" 8)
echo "$res" | grep -q '^docker_' || fail "docker query surfaced no docker_ tool: $res"
# the meta-tools never appear in their own results
echo "$res" | grep -qx 'search_tools' && fail "search_tools leaked into results"
# typo: dropped/!exact still surfaces the family
typo=$(discovery_search "dockr" 8)
echo "$typo" | grep -q '^docker_' || fail "typo 'dockr' surfaced no docker_ tool: $typo"
# intent filter (menu mode): only 'verify'-intent tools come back
menu=$(discovery_search "" 5 verify)
for m in $menu; do [[ "$(tool_intent "$m")" == "verify" ]] || fail "menu(verify) returned a non-verify tool: $m"; done

# ── 3. Meta-tools return usable schemas through dispatch ─────────────────────
st=$(tool_dispatch search_tools '{"query":"docker","limit":3}')
[[ "$(printf '%s' "$st" | jq '.matches|length')" -ge 1 ]] || fail "search_tools returned no matches: $st"
printf '%s' "$st" | jq -e '.matches[0].schema and .matches[0].intent and .matches[0].name' >/dev/null \
    || fail "search_tools match missing schema/intent/name: $st"
dt=$(tool_dispatch describe_tool '{"name":"docker_list_containers"}')
[[ "$(printf '%s' "$dt" | jq -r '.name')" == "docker_list_containers" ]] || fail "describe_tool wrong name: $dt"
printf '%s' "$dt" | jq -e '.schema.properties.target.enum' >/dev/null || fail "describe_tool lost the enum: $dt"
# unknown tool -> clean error
printf '%s' "$(tool_dispatch describe_tool '{"name":"nope_xyz"}')" | jq -e '.ok==false' >/dev/null || fail "describe_tool of unknown should be ok:false"

# ── 4. Default wire set stays small (core + meta-tools) — D6 cap ──────────────
YCA_CAT_ENABLED=(); YCA_CAT_ENABLED[core]=1; tools_invalidate_cache
bytes=$(build_tools_json | wc -c | tr -d ' ')
[[ "$bytes" -le 6000 ]] || fail "default wire set is $bytes bytes (> 6000 cap, D6)"
# the meta-tools ARE in the default set
build_tools_json | jq -e '[.[].function.name] | index("search_tools") and index("describe_tool") and index("enable_category")' >/dev/null \
    || fail "meta-tools missing from the default wire set"

# ── 5. enable_category over MCP: consent gate + tools/list_changed ───────────
# Redirect to a file (not $()) so mcp_enable_category runs in THIS shell and its
# YCA_CAT_ENABLED mutation persists — the whole point of handling it in-process.
YCA_UI_MODE=mcp
OF="$2/mcp_ec.out"
lc(){ grep -c 'notifications/tools/list_changed' "$OF"; }
r1(){ sed -n '1p' "$OF" | jq -r '.result.isError'; }
# WITHOUT consent -> deny, NO notification, category NOT enabled
YCA_AUTO_CONFIRM=false; YCA_CAT_ENABLED[docker]=0
mcp_enable_category 5 '{"category":"docker"}' > "$OF"
[[ "$(r1)" == "true" ]]  || fail "enable_category without consent was not denied: $(cat "$OF")"
[[ "$(lc)" == "0" ]]     || fail "a denied enable emitted a list_changed notification"
[[ "${YCA_CAT_ENABLED[docker]:-0}" != "1" ]] || fail "a denied enable still enabled the category"
# WITH consent -> enabled + exactly one notification
YCA_AUTO_CONFIRM=true
mcp_enable_category 6 '{"category":"docker"}' > "$OF"
[[ "$(r1)" == "false" ]] || fail "a consented enable errored: $(cat "$OF")"
[[ "$(lc)" == "1" ]]     || fail "enable did not emit tools/list_changed"
[[ "${YCA_CAT_ENABLED[docker]:-0}" == "1" ]] || fail "enable did not actually enable the category"
# unknown category -> error, NO notification (false-positive guard)
mcp_enable_category 7 '{"category":"nosuchcat"}' > "$OF"
[[ "$(r1)" == "true" ]]  || fail "unknown category was not rejected"
[[ "$(lc)" == "0" ]]     || fail "unknown category emitted a notification"
YCA_UI_MODE=plain

echo "discovery_body OK"
exit 0
