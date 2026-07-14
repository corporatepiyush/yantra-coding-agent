#!/usr/bin/env bash
# Test: complexity taxonomy + tool/workflow complexity lookups (unit body), and
# the REAL registrations — every *_llm_* tool must be mid, static tools low.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$YCA_DIR/tests/lib_mcp.sh"
cd "$TMP"; git init -q
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

# 1) Unit body (normalize/tier/needs_llm + registry lookups + overrides).
OUT=$(bash "$YCA_DIR/tests/test_scripts/complexity_body.sh" "$YCA_DIR" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "complexity_body OK" || { echo "$OUT"; exit 1; }

# 2) Real registrations via the sourced registry (the catalog view is gone).
REG=$(registry_dump "$YCA_DIR")

# Every LLM-backed tool (name contains _llm_) is registered mid.
BAD=$(awk -F'|' '$1 ~ /_llm_/ && $4 != "mid" {print $1}' <<<"$REG")
[[ -z "$BAD" ]] || { echo "these _llm_ tools are not mid: $BAD"; exit 1; }

# There should be a healthy number of them.
NLLM=$(awk -F'|' '$1 ~ /_llm_/' <<<"$REG" | wc -l | tr -d ' ')
[[ "$NLLM" -ge 15 ]] || { echo "expected >=15 llm tools, got $NLLM"; exit 1; }

# A static core tool is low.
LOW=$(awk -F'|' '$1 == "read" {print $4}' <<<"$REG")
[[ "$LOW" == "low" ]] || { echo "read should be low, got $LOW"; exit 1; }

echo "complexity_routing OK"
exit 0
