#!/usr/bin/env bash
# Test: with no LLM provider configured, LLM-backed (mid/high) calls surface a
# clear 412 (never hang/crash), while low-complexity work is unaffected. And a
# configured provider flips availability.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"; rm -f .harness.db; git init -q
echo "MARK_low" > f.txt
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"

# Enable the 'ollama' category via config so an LLM-backed tool is exposed.
cat > yantra.config.json <<'JSON'
{ "version":"1", "providers":{"think":[],"build":[],"tool":[]},
  "tools":{"enabled":["core","ollama"]} }
JSON

# 1) A mid (LLM-backed) tool with no provider → graceful 'unavailable' text,
# never garbage, and never a stray frame inside the JSON-RPC stream.
OUT=$(mcp_call "$HARNESS" ollama_llm_prompt_review '{"content":"Summarize X"}') || true
echo "$OUT" | grep -qi "unavailable" \
    || { echo "LLM tool result not graceful"; echo "$OUT"; exit 1; }

# 2) A low-complexity tool still works fine with zero providers.
OUT=$(mcp_call "$HARNESS" read '{"path":"f.txt"}') \
    || { echo "low tool broke without a provider"; echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "MARK_low" || { echo "read returned wrong content: $OUT"; exit 1; }

# 3+4) provider detection: none configured → unavailable; HARNESS_LLM_URL flips
# it (the cmd:config surface died with the CLI; assert at the detection seam).
DET=$(HARNESS_UPDATE_ENABLED=false YCA_DIR="$PROJ_ROOT" TMP="$TMP" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; cd "$TMP"
  projectconfig_load; providers_load; providers_detect; printf "%s" "$YCA_HAVE_LLM"')
[[ "$DET" == "0" ]] || { echo "config should report llm unavailable (got $DET)"; exit 1; }
DET=$(HARNESS_UPDATE_ENABLED=false HARNESS_LLM_URL="http://mock:9/v1" YCA_DIR="$PROJ_ROOT" TMP="$TMP" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  YCA_PROJECT_DIR="$TMP"; cd "$TMP"
  projectconfig_load; providers_load; providers_detect; printf "%s" "$YCA_HAVE_LLM"')
[[ "$DET" == "1" ]] || { echo "HARNESS_LLM_URL did not enable LLM (got $DET)"; exit 1; }

rm -f yantra.config.json
echo "llm_unavailable OK"
exit 0
