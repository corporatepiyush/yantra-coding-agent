#!/usr/bin/env bash
# T4: the MCP test client is a real instrument — it drives a server, answers
# elicitation and sampling from fixtures, and logs every frame both ways.
# Tested here against the deterministic stub server; the real server is driven
# by test_mcp_server.sh.
set -Euo pipefail
HARNESS="$1"; TMP="$2"

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
CLIENT="$PROJ_ROOT/tests/mcp_client/client.sh"
STUB="$PROJ_ROOT/tests/mcp_client/stub_server.sh"
GOLDEN="$PROJ_ROOT/tests/fixtures/mcp/stub_session.golden"
cd "$TMP"

fail() { echo "FAIL: $*"; exit 1; }

# received/sent frame extractors — frames are parsed with jq, never substring-
# grepped on raw JSON (a value can appear in more than one field).
recv_frames() { awk -F'\t' '$1=="<<" {print $2}' "$1"; }
sent_frames() { awk -F'\t' '$1==">>" {print $2}' "$1"; }
resp_for_id() { recv_frames "$1" | jq -c --argjson want "$2" 'select(has("method") | not) | select(.id == $want)'; }

SCRIPT="$TMP/session.script"
cat > "$SCRIPT" <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"danger_tool","arguments":{}}}
{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"llm_tool","arguments":{}}}
{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"plan://current"}}
EOF

# ── 1. Full session: handshake + list + call + elicitation + sampling ────────
LOG1="$TMP/run1.log"
bash "$CLIENT" --server "bash '$STUB'" --log "$LOG1" --script "$SCRIPT" \
    --caps sampling,elicitation --elicit accept --sampling-text "canned completion" \
    || fail "client exited non-zero on the happy path (rc $?)"

# elicitation accept → the gated tool ran
[[ "$(resp_for_id "$LOG1" 3 | jq -r '.result.content[0].text')" == "danger_tool ran" ]] \
    || fail "elicitation-accept did not run danger_tool: $(resp_for_id "$LOG1" 3)"
# sampling → the canned completion round-tripped into the result
[[ "$(resp_for_id "$LOG1" 4 | jq -r '.result.content[0].text')" == "model said: canned completion" ]] \
    || fail "sampling answer did not reach the result: $(resp_for_id "$LOG1" 4)"
# the interleaved notification was received AND did not desync id matching
recv_frames "$LOG1" | jq -e 'select(.method == "notifications/message")' >/dev/null \
    || fail "interleaved notification missing from the frame log"
[[ "$(resp_for_id "$LOG1" 2 | jq -r '.result.content[0].text')" == "Echo: hello" ]] \
    || fail "echo response wrong after interleaved notification: $(resp_for_id "$LOG1" 2)"
[[ "$(resp_for_id "$LOG1" 5 | jq -r '.result.contents[0].text')" == "stub plan" ]] \
    || fail "resources/read did not round-trip"

# ── 2. Byte-stable framing: same script → identical log ──────────────────────
LOG2="$TMP/run2.log"
bash "$CLIENT" --server "bash '$STUB'" --log "$LOG2" --script "$SCRIPT" \
    --caps sampling,elicitation --elicit accept --sampling-text "canned completion" \
    || fail "second run exited non-zero"
cmp -s "$LOG1" "$LOG2" || { diff "$LOG1" "$LOG2" | head -5; fail "frame logs not byte-identical across runs"; }

# golden: the committed capture must still match exactly (regenerate ONLY via
# tests/fixtures/mcp/README.md's command, never by editing)
if [[ -f "$GOLDEN" ]]; then
    cmp -s "$LOG1" "$GOLDEN" || { diff "$GOLDEN" "$LOG1" | head -5; fail "session drifted from the committed golden"; }
else
    fail "golden fixture missing: $GOLDEN"
fi

# ── 3. Capability flags actually change the handshake (both directions) ──────
init_with()   { sent_frames "$1" | jq -c 'select(.method == "initialize")'; }
printf '%s' "$(init_with "$LOG1")" | jq -e '.params.capabilities | has("sampling") and has("elicitation")' >/dev/null \
    || fail "advertised capabilities missing from the handshake"
LOG3="$TMP/run3.log"
bash "$CLIENT" --server "bash '$STUB'" --log "$LOG3" --script /dev/null --caps "" \
    || fail "no-caps run exited non-zero"
printf '%s' "$(init_with "$LOG3")" | jq -e '.params.capabilities | (has("sampling") or has("elicitation") or has("roots")) | not' >/dev/null \
    || fail "handshake advertises capabilities that were not requested (absence check)"

# ── 4. Elicitation decline → deny, tool does NOT run ─────────────────────────
LOG4="$TMP/run4.log"
printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"danger_tool","arguments":{}}}' > "$TMP/deny.script"
bash "$CLIENT" --server "bash '$STUB'" --log "$LOG4" --script "$TMP/deny.script" \
    --caps elicitation --elicit decline || fail "decline run exited non-zero"
resp_for_id "$LOG4" 3 | jq -e '.result.isError == true' >/dev/null \
    || fail "declined elicitation did not produce an error result"
[[ "$(resp_for_id "$LOG4" 3 | jq -r '.result.content[0].text')" == "denied: consent was not given" ]] \
    || fail "deny message wrong: $(resp_for_id "$LOG4" 3)"

# ── 5. Protocol-version mismatch fails loudly ────────────────────────────────
LOG5="$TMP/run5.log"
rc=0
bash "$CLIENT" --server "STUB_PROTO=1999-01-01 bash '$STUB'" \
    --log "$LOG5" --script /dev/null >/dev/null 2>&1 || rc=$?
[[ "$rc" -eq 2 ]] || fail "expected exit 2 on protocol mismatch, got $rc"

echo "test_mcp_client OK"
exit 0
