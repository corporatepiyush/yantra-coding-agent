#!/usr/bin/env bash
# Test: local-AI un-cripple — real .usage-based cost accounting, usage capture,
# full-vector embed, response_format (structured output) plumbing, ollama_extract.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/ai_actions_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "ai_actions_body OK" || { echo "$OUT"; exit 1; }
echo "ai_actions OK"
exit 0
