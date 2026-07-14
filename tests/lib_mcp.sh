#!/usr/bin/env bash
# tests/lib_mcp.sh — shared MCP-session helpers for suites that used to drive
# the NDJSON surface (removed by the MCP-only amendment). Source this from a
# suite after setting HARNESS.
#
#   mcp_session HARNESS [y] <<'EOF' …frames… EOF
#       run one MCP session: initialize + your frames + exit; prints every
#       response line. Pass "y" to launch the server pre-consented (-y), the
#       replacement for NDJSON auto_confirm:true.
#   mcp_call HARNESS NAME ARGS_JSON [y]
#       one tools/call; prints the result text; rc 1 when isError (deny/fail).
#   mcp_wf HARNESS WORKFLOW_ID INPUTS_JSON [y]
#       one workflow call via its wf__<id> tool name; prints the workflow's
#       result payload JSON ({ok,summary,…}); rc as mcp_call.

mcp_session() {
    local harness="$1" auto="${2:-}"
    local -a flags=()
    [[ "$auto" == "y" ]] && flags+=(-y)
    # extra launch flags (e.g. MCP_FLAGS="--enable git") for gate-dependent suites
    [[ -n "${MCP_FLAGS:-}" ]] && flags+=($MCP_FLAGS)
    { printf '%s\n' '{"jsonrpc":"2.0","id":"_init","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test-suite","version":"1"}}}'
      cat
      printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}'
    } | HARNESS_UPDATE_ENABLED=false timeout 120 bash "$harness" ${flags[@]+"${flags[@]}"} 2>/dev/null
}

mcp_call() {
    # NOTE: never write ${3:-{}} — bash ends the :- word at the FIRST `}`
    # (the historical core-read-breaking bug); default the empty case explicitly.
    local harness="$1" name="$2" args="${3:-}" auto="${4:-}"
    [[ -n "$args" ]] || args='{}' 
    local frame out
    frame=$(jq -cn --arg n "$name" --argjson a "$args" \
        '{jsonrpc:"2.0",id:"_call",method:"tools/call",params:{name:$n,arguments:$a}}')
    out=$(printf '%s\n' "$frame" | mcp_session "$harness" "$auto" | jq -c 'select(.id == "_call")')
    printf '%s' "$out" | jq -r '.result.content[0].text // empty'
    printf '%s' "$out" | jq -e '.result.isError == false' >/dev/null
}

mcp_wf() {
    local harness="$1" wf="$2" inputs="${3:-}" auto="${4:-}"
    [[ -n "$inputs" ]] || inputs='{}' 
    mcp_call "$harness" "wf__${wf//./_}" "$inputs" "$auto"
}

# registry_dump PROJ_ROOT — one "name|danger|category|effective_complexity" line
# per registered tool (replacement for the removed NDJSON catalog view; the
# catalog was only ever a rendering of this registry).
registry_dump() {
    YCA_DIR="$1" bash -c '
      set -u; export YCA_DIR
      source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
      for n in "${!YCA_TOOL_REGISTRY[@]}"; do
        IFS="|" read -r _ d _ c _ <<< "${YCA_TOOL_REGISTRY[$n]}"
        printf "%s|%s|%s|%s\n" "$n" "$d" "$c" "$(tool_complexity "$n")"
      done'
}
