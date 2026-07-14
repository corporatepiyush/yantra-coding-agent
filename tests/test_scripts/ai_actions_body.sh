#!/usr/bin/env bash
# tests/test_scripts/ai_actions_body.sh — local-AI un-cripple: REAL cost accounting
# from .usage, usage capture, full-vector embed transform, format plumbing,
# ollama_extract registration. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
# Set DB path AFTER sourcing — constants.sh resets it during the source.
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_DB_PATH="$2/ai_test.db"; YCA_UI_MODE=json; YCA_OUT_FD=1
fail(){ echo "FAIL: $1"; exit 1; }
db_init >/dev/null 2>&1 || true

# ── real cost accounting: sums .usage tokens (NOT row counts) ──
db_exec "INSERT INTO events(kind,data_json) VALUES ('llm.usage','{\"tier\":\"think\",\"prompt_tokens\":100,\"completion_tokens\":50}');" >/dev/null 2>&1
db_exec "INSERT INTO events(kind,data_json) VALUES ('llm.usage','{\"tier\":\"build\",\"prompt_tokens\":30,\"completion_tokens\":20}');" >/dev/null 2>&1
out=$(wf_harness_cost 2>&1 || true)
echo "$out" | grep -q '"prompt_tokens":130' || fail "wf_harness_cost wrong prompt total ($out)"
echo "$out" | grep -q '"completion_tokens":70' || fail "wf_harness_cost wrong completion total ($out)"

# ── _llm_log_usage records a usage event parsed from a response body ──
_llm_log_usage gpt-x think '{"usage":{"prompt_tokens":7,"completion_tokens":3}}'
c=$(db_count "events" "kind='llm.usage'" 2>/dev/null)
[[ "$c" == "3" ]] || fail "_llm_log_usage did not record usage (count=$c)"
# a response with no usage records nothing
_llm_log_usage gpt-x think '{"choices":[{"message":{"content":"hi"}}]}'
c2=$(db_count "events" "kind='llm.usage'" 2>/dev/null)
[[ "$c2" == "3" ]] || fail "_llm_log_usage logged an empty-usage response (count=$c2)"

# ── embed transform emits the FULL vector (mirrors tool_ollama_embed's jq) ──
emb=$(printf '{"embedding":[0.1,0.2,0.3,0.4]}' | jq -c --arg m nomic 'if .embedding then {model:$m,dim:(.embedding|length),embedding:.embedding} else . end')
echo "$emb" | grep -q '"dim":4' || fail "embed transform lost the dim ($emb)"
echo "$emb" | grep -q '0.4' || fail "embed transform dropped the vector ($emb)"

# ── format plumbing: json / schema set response_format on the request body ──
# (mirrors the llm_analyze injection, verified in isolation since it needs no LLM)
b='{"model":"","messages":[]}'
bj=$(printf '%s' "$b" | jq -c '.response_format={type:"json_object"}')
echo "$bj" | grep -q '"response_format":{"type":"json_object"}' || fail "format=json did not set response_format ($bj)"
bs=$(printf '%s' "$b" | jq -c --argjson sch '{"type":"object"}' '.response_format={type:"json_schema",json_schema:{name:"out",strict:true,schema:$sch}}')
echo "$bs" | grep -q '"json_schema"' || fail "schema format did not set json_schema ($bs)"

# ── ollama_extract is registered (LLM-backed, mid) ──
info="${YCA_TOOL_REGISTRY[ollama_extract]:-}"; [[ -n "$info" ]] || fail "ollama_extract not registered"
IFS='|' read -r _fn _dg _ag _cat cx <<< "$info"
[[ "$cx" == "mid" ]] || fail "ollama_extract should be complexity=mid (got $cx)"

# ── RAG: DuckDB vector store + cosine similarity (fixed vectors, no embed model) ──
if command -v duckdb >/dev/null 2>&1; then
    ragdb="$2/rag_test.duckdb"; rm -f "$ragdb"
    duckdb "$ragdb" "CREATE TABLE chunks(source VARCHAR, idx INTEGER, text VARCHAR, embedding DOUBLE[]); INSERT INTO chunks VALUES ('a',0,'apple fruit red',[1.0,0.0,0.0]), ('b',1,'banana fruit yellow',[0.0,1.0,0.0]), ('c',2,'car vehicle fast',[0.0,0.0,1.0]);" >/dev/null 2>&1
    res=$(_rag_search "$ragdb" "[0.9,0.1,0.0]" 1 2>&1 || true)
    echo "$res" | grep -q 'apple' || fail "_rag_search did not return the nearest chunk for axis 1 ($res)"
    res=$(_rag_search "$ragdb" "[0.0,0.0,0.9]" 1 2>&1 || true)
    echo "$res" | grep -q 'car' || fail "_rag_search wrong nearest for axis 3 ($res)"
fi
for t in ollama_rag_index ollama_rag_query; do
    info="${YCA_TOOL_REGISTRY[$t]:-}"; [[ -n "$info" ]] || fail "$t not registered"
done

echo "ai_actions_body OK"
