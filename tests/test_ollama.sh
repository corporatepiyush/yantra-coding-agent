#!/usr/bin/env bash
# Test: the `ollama` tool category — the ai→ollama rename is complete, the new
# basic/advanced/maintenance calls are registered, danger flags are right.
# Deterministic (no live ollama daemon needed); registry facts via sourcing.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"; rm -f .harness.db; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

REG=$(registry_dump "$PROJ_ROOT")
has() { grep -q "^$1|" <<<"$REG"; }

# Kept ollama calls (the pure `ollama <verb>` passthroughs were removed) are registered.
for t in ollama_run ollama_doctor ollama_model_info ollama_notebook \
         ollama_endpoint_test ollama_embed ollama_chat ollama_api_generate \
         ollama_extract ollama_rag_index ollama_rag_query \
         ollama_serve_status ollama_version ollama_disk_usage ollama_logs; do
    has "$t" || { echo "missing $t"; exit 1; }
done
# The removed passthroughs must be gone.
for t in ollama_models ollama_pull ollama_ps ollama_show ollama_rm; do
    has "$t" && { echo "removed passthrough still present: $t"; exit 1; }
done

# The category is now 'ollama' and the old 'ai' category is gone.
grep -q '|ollama|' <<<"$REG" || { echo "no tools in the ollama category"; exit 1; }
grep -q '|ai|' <<<"$REG" && { echo "old 'ai' category still present"; exit 1; }

# Old ai_* tool ids no longer exist.
for t in ai_models ai_pull ai_run; do
    has "$t" && { echo "old id still present: $t"; exit 1; }
done

# The RAG index write carries the writes flag; llm_prompt_review stays mid.
grep -q '^ollama_rag_index|writes|' <<<"$REG" || { echo "ollama_rag_index not marked writes"; exit 1; }
grep -qE '^ollama_llm_prompt_review\|[a-z]+\|[a-z]+\|mid$' <<<"$REG" \
    || { echo "ollama_llm_prompt_review not mid"; exit 1; }

# The category is reachable over MCP once enabled (wire check, both directions).
export MCP_FLAGS="--enable ollama"
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"tl","method":"tools/list","params":{}}' | mcp_session "$HARNESS")
printf '%s\n' "$OUT" | jq -e 'select(.id=="tl") | .result.tools[] | select(.name=="ollama_run")' >/dev/null \
    || { echo "ollama_run not on the wire after --enable ollama"; exit 1; }
unset MCP_FLAGS
OUT=$(printf '%s\n' '{"jsonrpc":"2.0","id":"tl","method":"tools/list","params":{}}' | mcp_session "$HARNESS")
printf '%s\n' "$OUT" | jq -e 'select(.id=="tl") | [.result.tools[] | select(.name=="ollama_run")] | length == 0' >/dev/null \
    || { echo "ollama_run on the wire while the category is disabled"; exit 1; }

echo "ollama OK"
exit 0
