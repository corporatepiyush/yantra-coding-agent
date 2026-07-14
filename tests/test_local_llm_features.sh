#!/usr/bin/env bash
# Test: local-LLM interaction hardening added for Ollama/llama.cpp use —
#   * build_tools_json nests schemas under function.parameters (OpenAI spec),
#     hoists a schema description, and emits core tools first (position bias);
#   * ollama tunable-param builder / output sanitizer / API-error detector /
#     model-dir path guard;
#   * browse HTML->text extraction;
#   * confirm_denied_msg instructive machine-mode denial;
#   * doc_llm_web_summarize registered and ollama_chat advertises tunables.
# Deterministic: sources the harness, calls the functions directly. No network.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"

cat > "$TMP/body.sh" <<'SCRIPT'
set -Euo pipefail
YCA_DIR="$1"; TMP="$2"; export YCA_DIR
YCA_PROJECT_DIR="$TMP"; export YCA_PROJECT_DIR
source "$YCA_DIR/harness/main.sh"
YCA_UI_MODE="json"
YCA_CAT_ENABLED[core]=1; YCA_CAT_ENABLED[doc]=1; YCA_CAT_ENABLED[ollama]=1
YCA_SAFETY_PATHS="$TMP"
tools_invalidate_cache 2>/dev/null || true

fail() { echo "FAIL: $1"; exit 1; }

# ── 1. build_tools_json: OpenAI-spec parameters nesting + description hoist ──
TJ=$(build_tools_json all)
printf '%s' "$TJ" | jq -e '.' >/dev/null 2>&1 || fail "tools json is not valid JSON"
# the read tool must carry its schema under function.parameters, not flattened
printf '%s' "$TJ" | jq -e '.[]|select(.function.name=="read")|.function.parameters.type=="object"' >/dev/null \
    || fail "read tool schema not nested under function.parameters"
printf '%s' "$TJ" | jq -e '.[]|select(.function.name=="read")|.function.parameters.properties.path' >/dev/null \
    || fail "read tool parameters missing .path property"
# a top-level schema description is hoisted to function.description
printf '%s' "$TJ" | jq -e '.[]|select(.function.name=="read")|.function.description|test("Read a file")' >/dev/null \
    || fail "read tool description not hoisted to function.description"
# parameterless tools omit parameters (kept compact)
printf '%s' "$TJ" | jq -e '.[]|select(.function.name=="ollama_serve_status")|has("parameters")|not' >/dev/null \
    || fail "parameterless tool should omit parameters"

# ── 2. core-first ordering (small models pick from the head of the list) ──
NAMES=$(printf '%s' "$TJ" | jq -r '.[].function.name')
# core-category tools = the 6 originals + the always-on plan tools (T12) + the
# discovery meta-tools (T11), all of which register under category `core` and so
# also lead the list.
core_re='^(read|write|edit|bash|browse|batch|plan_[a-z_]+|search_tools|describe_tool|enable_category)$'
first=$(printf '%s\n' "$NAMES" | head -1)
[[ "$first" =~ $core_re ]] || fail "first tool '$first' is not a core tool"
# every core tool must appear before the first non-core tool
idx_first_noncore=$(printf '%s\n' "$NAMES" | grep -nvE "$core_re" | head -1 | cut -d: -f1)
idx_last_core=$(printf '%s\n' "$NAMES" | grep -nE "$core_re" | tail -1 | cut -d: -f1)
(( idx_last_core < idx_first_noncore )) || fail "core tools not all before non-core (lastcore=$idx_last_core firstnoncore=$idx_first_noncore)"

# ── 3. _ollama_gen_extra: tunable options/format builder ──
ge() { YCA_TOOL_ARGS_JSON="$1" _ollama_gen_extra; }
[[ "$(ge '{"target":"m","content":"hi"}')" == "{}" ]] || fail "gen_extra: no tunables should yield {}"
echo "$(ge '{"temperature":0.2,"num_ctx":8192}')" | jq -e '.options.temperature==0.2 and .options.num_ctx==8192' >/dev/null \
    || fail "gen_extra: shortcut scalars not placed in options"
echo "$(ge '{"temperature":0.7,"options":{"min_p":0.05}}')" | jq -e '.options.min_p==0.05 and .options.temperature==0.7' >/dev/null \
    || fail "gen_extra: options object + shortcut not merged"
echo "$(ge '{"format":"json"}')" | jq -e '.format=="json"' >/dev/null \
    || fail "gen_extra: format not passed through"

# ── 4. _ollama_strip: remove CLI spinner (ANSI + braille) but keep text ──
raw=$(printf '\x1b[?25l\xe2\xa0\x8b\x1b[1GDONE\x1b[K\r')
[[ "$(printf '%s' "$raw" | _ollama_strip)" == "DONE" ]] || fail "_ollama_strip did not clean spinner output"

# ── 5. _ollama_api_err: detect {"error":...} bodies ──
[[ "$(_ollama_api_err '{"error":"model not found"}')" == "model not found" ]] || fail "_ollama_api_err missed .error"
[[ -z "$(_ollama_api_err '{"response":"ok"}')" ]] || fail "_ollama_api_err false-positive on good body"
[[ -z "$(_ollama_api_err 'not json')" ]] || fail "_ollama_api_err should be quiet on non-JSON"

# ── 6. _ollama_read_ok: allow project + model dirs, deny elsewhere ──
_ollama_read_ok "$HOME/.ollama/models/x.gguf" || fail "_ollama_read_ok should allow ~/.ollama"
_ollama_read_ok "$HOME/models/x.gguf" || fail "_ollama_read_ok should allow ~/models"
_ollama_read_ok "/etc/passwd" && fail "_ollama_read_ok must deny /etc/passwd"

# ── 7. _html_to_text: strip tags/script noise ──
html='<html><head><style>.a{color:red}</style></head><body><script>var x=1;</script><h1>Hi</h1><p>Body &amp; text</p></body></html>'
txt=$(printf '%s' "$html" | _html_to_text)
printf '%s' "$txt" | grep -q 'Hi' || fail "_html_to_text dropped real content"
printf '%s' "$txt" | grep -qiE 'var x=1|color:red|<script|<h1' && fail "_html_to_text left script/style/tags"

# ── 8. confirm_denied_msg: instructive in machine mode w/o auto_confirm ──
YCA_AUTO_CONFIRM=false
msg=$(confirm_denied_msg)
printf '%s' "$msg" | grep -qi 'auto_confirm' || fail "confirm_denied_msg not instructive in json mode"
printf '%s' "$msg" | grep -qi 'do NOT retry\|not retry' || fail "confirm_denied_msg should tell the model not to retry"

# ── 9. registration: web summarizer + ollama tunable schema advertised ──
[[ -n "${YCA_TOOL_REGISTRY[doc_llm_web_summarize]:-}" ]] || fail "doc_llm_web_summarize not registered"
printf '%s' "${YCA_TOOL_SCHEMAS[ollama_chat]:-}" | jq -e '.properties.temperature and .properties.options and .properties.format' >/dev/null \
    || fail "ollama_chat schema missing tunable params (temperature/options/format)"

echo "local_llm_features OK"
SCRIPT

bash "$TMP/body.sh" "$(cd "$(dirname "$HARNESS")" && pwd)" "$TMP" || exit 1

# ── 10. MCP default-deny: without session consent a writes tool never runs ──
# (the per-frame NDJSON scoping test moved to test_mcp_server's per-call
# elicitation-scope assertion; this is the surviving fail-closed half)
rm -f "$TMP/.harness.db"; git -C "$TMP" init -q 2>/dev/null
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
OUT=$(mcp_call "$HARNESS" bash '{"command":"echo leaked > pwned.txt"}') \
    && { echo "FAIL: writes tool ran without consent"; exit 1; }
echo "$OUT" | grep -qE "confirmation|cancelled" \
    || { echo "FAIL: deny message not instructive: $OUT"; exit 1; }
[[ -f "$TMP/pwned.txt" ]] && { echo "FAIL: bash ran despite denial"; exit 1; }

echo "local_llm_features + mcp-default-deny OK"
