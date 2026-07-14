#!/usr/bin/env bash
# Test T1: Protocol & docs honesty — MCP edition (the NDJSON ready frame died
# with the surface; the same defect-a guard now walks the MCP handshake).
# (1) initialize advertises no capability without a handler, both directions;
# (2) README tool/workflow counts equal the REGISTRY counts, computed by SOURCING
#     the harness (never by grepping source text — PLAN.md T1 assertion #3);
# (3) dead function _k8s_run is gone (and siblings kept).
set -Euo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"; rm -f .harness.db
fail(){ echo "FAIL: $1"; exit 1; }

# ── (1a) handshake capabilities: phantom guard (defect a, MCP edition) ───────
CAPS=$(printf '%s\n%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
    '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | HARNESS_UPDATE_ENABLED=false bash "$HARNESS" 2>/dev/null \
    | jq -c 'select(.id == 1) | .result.capabilities')
[[ -n "$CAPS" ]] || fail "no initialize response / capabilities object"

# stream/cancel-class phantoms: nothing outside the known set may be advertised
printf '%s' "$CAPS" | jq -e 'keys - ["tools","resources","prompts","logging"] == []' >/dev/null \
    || fail "phantom capability advertised: $CAPS"

# FORWARD: every advertised capability resolves to a real handler function.
declare -A CAP_ANCHOR=(
  [tools]="mcp_tools_list" [resources]="mcp_resources_read"
  [prompts]="mcp_prompts_get" [logging]="_mcp_emit_stderr")
for cap in $(printf '%s' "$CAPS" | jq -r 'keys[]'); do
  anchor="${CAP_ANCHOR[$cap]:-}"
  [[ -n "$anchor" ]] || fail "advertised capability '$cap' has no known handler mapping"
  grep -rqE "(^|[^a-zA-Z_])${anchor}[[:space:]]*\(\)" "$PROJ_ROOT/harness/" \
    || fail "capability '$cap' maps to '$anchor' but no such function is defined"
done

# REVERSE: every routed method family is advertised — no undocumented surface.
MCP="$PROJ_ROOT/harness/commands/mcp.sh"
declare -A METHOD_CAP=([tools/list]="tools" [tools/call]="tools" \
  [resources/list]="resources" [resources/read]="resources" \
  [prompts/list]="prompts" [prompts/get]="prompts")
for m in "${!METHOD_CAP[@]}"; do
  grep -qE "^[[:space:]]+${m}\)" "$MCP" || fail "method '$m' has no case arm in mcp.sh"
  printf '%s' "$CAPS" | jq -e --arg c "${METHOD_CAP[$m]}" 'has($c)' >/dev/null \
    || fail "method '$m' routed but its capability '${METHOD_CAP[$m]}' is not advertised"
done

# tools/list_changed is emitted (enable_category), so listChanged must be true
printf '%s' "$CAPS" | jq -e '.tools.listChanged == true' >/dev/null \
    || fail "tools.listChanged not advertised but enable_category emits the notification"

# ── (2) counts: SOURCE the registry, compare to README ───────────────────────
COUNTS=$(HARNESS_UPDATE_ENABLED=false YCA_DIR="$PROJ_ROOT" bash -c '
  source "'"$PROJ_ROOT"'/harness/main.sh" </dev/null 2>/dev/null
  n=0; for k in "${!YCA_TOOL_REGISTRY[@]}"; do [[ "$k" == *_llm_* || "$k" == llm_* ]] && ((n++)); done
  printf "%s %s %s\n" "${#YCA_TOOL_REGISTRY[@]}" "${#YCA_WF_REGISTRY[@]}" "$n"')
read -r REG_TOOLS REG_WF REG_LLM <<< "$COUNTS"
[[ "$REG_TOOLS" =~ ^[0-9]+$ && "$REG_TOOLS" -gt 0 ]] || fail "could not source tool registry (got '$COUNTS')"

README="$PROJ_ROOT/README.md"
grep -q "$REG_TOOLS built-in tools" "$README" \
  || fail "README headline tool count != registry ($REG_TOOLS). Regenerate README counts."
grep -qE "$REG_WF (deterministic )?workflows" "$README" \
  || fail "README workflow count != registry ($REG_WF)."
DET=$((REG_TOOLS - REG_LLM))
grep -q "$DET deterministic tools (out of $REG_TOOLS)" "$README" \
  || fail "README deterministic breakdown != registry ($DET of $REG_TOOLS)."

# ── (3) dead code removed, siblings kept ─────────────────────────────────────
! grep -rq "_k8s_run" "$PROJ_ROOT/harness/" || fail "_k8s_run still present (should be deleted)"
grep -q "_k8s_missing" "$PROJ_ROOT/harness/tools/kubernetes.sh" || fail "_k8s_missing over-deleted"
# the removed surfaces must STAY removed (MCP-only amendment)
for gone in stdio_loop interactive_loop cli_run_subcommand dispatch_input agent_run_llm_loop; do
  ! grep -rqE "(^|[^a-zA-Z_])${gone}[[:space:]]*\(\)[[:space:]]*\{" "$PROJ_ROOT/harness/" \
    || fail "removed surface function '$gone' has crept back in"
done

echo "test_protocol_honesty OK"
exit 0
