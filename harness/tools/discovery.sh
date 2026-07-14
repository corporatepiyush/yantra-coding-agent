#!/usr/bin/env bash
# tools/discovery.sh — T11 discovery: ONE search/index backend over the registry,
# plus the meta-tools that let a small model REACH the 662 tools without being
# handed all ~80K tokens of schemas. The default wire set stays ~6 core tools +
# these meta-tools; everything else is found on demand.
#
# (Lives under tools/ — not core/ — because it calls tool_register, which core/
# defines only when core/tools.sh is sourced; register.sh sources tools/ after.)
#
# Intent facet: every tool/workflow gets one of four intents, largely derived
# from its danger level, so the model can browse by what it wants to DO:
#   discovery (read/inspect) · verify (test/lint/check) · transform (edit/write)
#   · execute (run/deploy/delete). The danger->intent table is the golden default;
#   a name-based `verify` refinement pulls safe check/test tools out of discovery.

# tool_intent NAME -> the tool's intent (one of the four). Deterministic.
tool_intent() {
    local name="$1" info danger
    info="${YCA_TOOL_REGISTRY[$name]:-}"
    [[ -n "$info" ]] || { printf 'discovery'; return 0; }
    IFS='|' read -r _ danger _ _ _ <<< "$info"
    _intent_from "$name" "$danger"
}

# wf_intent ID -> a workflow's intent (from its danger level + name).
wf_intent() {
    local id="$1" info danger
    info="${YCA_WF_REGISTRY[$id]:-}"
    [[ -n "$info" ]] || { printf 'execute'; return 0; }
    IFS='|' read -r _ _ danger _ <<< "$info"
    _intent_from "$id" "$danger"
}

# _intent_from NAME DANGER -> the derived intent. The golden mapping:
#   safe -> discovery (verify if the name says test/lint/check/…)
#   writes -> transform ; destructive|dangerous -> execute
_intent_from() {
    local name="$1" danger="$2"
    case "$danger" in
        writes)                printf 'transform'; return 0 ;;
        destructive|dangerous) printf 'execute';   return 0 ;;
    esac
    case "$name" in
        *test*|*lint*|*check*|*doctor*|*audit*|*verify*|*scan*|*_race|*diff*|*review*)
            printf 'verify'; return 0 ;;
    esac
    printf 'discovery'
}

# discovery_search QUERY [LIMIT] [INTENT] -> ranked tool ids, newline-separated.
# Ranking (high to low): exact name, name substring, description substring, then
# per-word overlap with a prefix-tolerant pass so a typo/truncation ("dockr",
# "kuberntes") still surfaces the right family.
discovery_search() {
    local q="$1" limit="${2:-8}" want_intent="${3:-}"
    local ql; ql=$(printf '%s' "$q" | tr '[:upper:]' '[:lower:]')
    local name nl dl score schema desc w stem
    local -a scored=()
    for name in "${!YCA_TOOL_REGISTRY[@]}"; do
        # never surface the discovery meta-tools themselves in results
        case "$name" in search_tools|describe_tool|enable_category) continue ;; esac
        if [[ -n "$want_intent" ]]; then
            [[ "$(tool_intent "$name")" == "$want_intent" ]] || continue
        fi
        nl=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')
        schema="${YCA_TOOL_SCHEMAS[$name]:-}"
        desc=$(printf '%s' "$schema" | jq -r '[.description // "", (.properties // {} | to_entries[] | .value.description // "")] | join(" ")' 2>/dev/null | tr '[:upper:]' '[:lower:]')
        score=0
        if [[ -z "$ql" ]]; then
            score=1
        elif [[ "$nl" == "$ql" ]]; then score=100
        elif [[ "$nl" == *"$ql"* ]]; then score=60
        elif [[ "$desc" == *"$ql"* ]]; then score=30
        else
            for w in $ql; do
                [[ ${#w} -ge 3 ]] || continue
                if [[ "$nl" == *"$w"* ]]; then score=$((score+20))
                elif [[ "$desc" == *"$w"* ]]; then score=$((score+10))
                else
                    # prefix-tolerant: drop the last char (trailing typo/truncation)
                    stem="${w%?}"
                    [[ ${#stem} -ge 4 && ( "$nl" == *"$stem"* || "$desc" == *"$stem"* ) ]] && score=$((score+8))
                fi
            done
        fi
        (( score > 0 )) && scored+=("$score $name")
    done
    # score DESC, then name ASC for a stable, predictable order (per-key flags —
    # a global -r would reverse the name tiebreak too).
    printf '%s\n' "${scored[@]+"${scored[@]}"}" | sort -k1,1nr -k2,2 | head -n "$limit" | awk '{print $2}'
}

# ── Meta-tools (read-only; safe to run in the dispatch subshell) ─────────────

# search_tools {query, [limit], [intent]} -> top matches WITH full schemas.
tool_search_tools() {
    local args="${5:-${YCA_TOOL_ARGS_JSON:-}}"
    local q limit intent
    q=$(printf '%s' "$args" | jq -r '.query // ""' 2>/dev/null)
    limit=$(printf '%s' "$args" | jq -r '.limit // 8' 2>/dev/null); [[ "$limit" =~ ^[0-9]+$ ]] || limit=8
    intent=$(printf '%s' "$args" | jq -r '.intent // ""' 2>/dev/null)
    local -a ids=(); mapfile -t ids < <(discovery_search "$q" "$limit" "$intent")
    local id out="[]"
    for id in ${ids[@]+"${ids[@]}"}; do
        IFS='|' read -r _ danger _ category _ <<< "${YCA_TOOL_REGISTRY[$id]}"
        out=$(jq -c --arg n "$id" --arg d "$danger" --arg c "$category" --arg i "$(tool_intent "$id")" \
            --argjson s "${YCA_TOOL_SCHEMAS[$id]:-null}" \
            '. += [{name:$n, danger:$d, category:$c, intent:$i, schema:$s}]' <<< "$out" 2>/dev/null)
    done
    jq -c --arg q "$q" --argjson m "$out" '{query:$q, matches:$m}' <<< '{}'
}

# describe_tool {name} -> the full schema + metadata for one tool.
tool_describe_tool() {
    local args="${5:-${YCA_TOOL_ARGS_JSON:-}}"
    local name; name=$(printf '%s' "$args" | jq -r '.name // ""' 2>/dev/null)
    [[ -n "$name" ]] || { printf '{"ok":false,"error":"name required"}'; return 1; }
    local info="${YCA_TOOL_REGISTRY[$name]:-}"
    [[ -n "$info" ]] || { printf '{"ok":false,"error":"unknown tool: %s"}' "$name"; return 1; }
    local fn danger agents category complexity
    IFS='|' read -r fn danger agents category complexity <<< "$info"
    complexity=$(tool_complexity "$name")   # effective: config override wins
    jq -c --arg n "$name" --arg d "$danger" --arg c "$category" --arg cx "$complexity" \
        --arg i "$(tool_intent "$name")" --argjson s "${YCA_TOOL_SCHEMAS[$name]:-null}" \
        '{ok:true, name:$n, danger:$d, category:$c, complexity:$cx, intent:$i, schema:$s}' <<< '{}'
}

# enable_category {category} -> expose a category's tools for the rest of the
# session. Consent-gated (registered `writes`). Because a tool fn runs in a
# dispatch subshell, the actual YCA_CAT_ENABLED mutation cannot persist from
# here — it is applied by the surface that owns process state (mcp_tools_call
# over MCP; the tools.enable workflow over NDJSON/CLI). This fn validates and
# reports; over MCP the real enable + tools/list_changed happen in-process.
tool_enable_category() {
    local args="${5:-${YCA_TOOL_ARGS_JSON:-}}"
    local cat; cat=$(printf '%s' "$args" | jq -r '.category // ""' 2>/dev/null | tr '[:upper:]' '[:lower:]')
    [[ -n "$cat" ]] || { printf '{"ok":false,"error":"category required"}'; return 1; }
    [[ -n "${YCA_CAT_DEFAULT[$cat]:-}" ]] || { printf '{"ok":false,"error":"unknown category: %s"}' "$cat"; return 1; }
    YCA_CAT_ENABLED[$cat]=1
    tools_invalidate_cache 2>/dev/null || true
    printf '{"ok":true,"category":"%s","enabled":true}' "$cat"
}

tool_register "search_tools"   tool_search_tools   '{"description":"Find tools by query or intent and get their schemas — use this to reach tools beyond the core set","type":"object","properties":{"query":{"type":"string","description":"what you want to do, e.g. list docker containers"},"limit":{"type":"integer","description":"max matches to return (default 8)"},"intent":{"type":"string","description":"restrict to one intent","enum":["discovery","verify","transform","execute"]}},"required":[]}' safe all core
tool_register "describe_tool"  tool_describe_tool  '{"description":"Get the full schema and metadata for one tool by name","type":"object","properties":{"name":{"type":"string","description":"the exact tool name"}},"required":["name"]}' safe all core
tool_register "enable_category" tool_enable_category '{"description":"Expose a tool category for the rest of the session (asks for confirmation)","type":"object","properties":{"category":{"type":"string","description":"the category to enable, e.g. docker"}},"required":["category"]}' writes all core
