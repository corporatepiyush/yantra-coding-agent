#!/usr/bin/env bash
# T8 (build half): the MCP server surface, driven by the T4 client.
# Covers: handshake + list/call round trips, byte-stable tools list, consent
# parity with NDJSON (same deny text, marker absent), elicitation approve/deny,
# annotations per danger level, wf__ name mangling + collision walk, stdout
# purity, spill resource links resolving byte-identical, serial multi-id
# answering, cancellation tolerance, SIGPIPE cleanup, and the fuzz corpus.
#
# NOT covered (not built yet): sampling round-trips,
# prompts/*, roots re-scan. The loop-removal half is evidence-gated on T5.
set -Euo pipefail
HARNESS="$1"; TMP="$2"

HARNESS="$(cd "$(dirname "$HARNESS")" && pwd)/$(basename "$HARNESS")"
PROJ_ROOT="$(dirname "$HARNESS")"
CLIENT="$PROJ_ROOT/tests/mcp_client/client.sh"
CORPUS="$PROJ_ROOT/tests/fixtures/mcp/fuzz_corpus.txt"
cd "$TMP"

fail() { echo "FAIL: $*"; exit 1; }
SERVER="HARNESS_UPDATE_ENABLED=false bash '$HARNESS' --ui mcp"
recv_frames() { awk -F'\t' '$1=="<<" {print $2}' "$1"; }
resp_for_id() { recv_frames "$1" | jq -c --argjson want "$2" 'select(has("method") | not) | select(.id == $want)'; }

printf 'hello mcp\n' > sample.txt

# ── 1. Happy path: handshake → tools/list → read → correct result ────────────
cat > s1.script <<'EOF'
{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
{"jsonrpc":"2.0","id":"str-id","method":"tools/call","params":{"name":"read","arguments":{"path":"sample.txt"}}}
{"jsonrpc":"2.0","id":0,"method":"ping","params":{}}
EOF
bash "$CLIENT" --server "$SERVER" --log s1.log --script s1.script || fail "happy-path session rc $?"
[[ "$(resp_for_id s1.log '"str-id"' | jq -r '.result.content[0].text')" == "hello mcp" ]] \
    || fail "read via MCP wrong (string id): $(resp_for_id s1.log '"str-id"')"
resp_for_id s1.log 0 | jq -e '.result == {}' >/dev/null || fail "id 0 not answered correctly"

# tools/list byte-stable across two connections (prefix-cache property)
bash "$CLIENT" --server "$SERVER" --log s1b.log --script s1.script || fail "second connection rc $?"
l1=$(resp_for_id s1.log 1); l2=$(resp_for_id s1b.log 1)
[[ "$l1" == "$l2" ]] || fail "tools/list not byte-stable across connections"

# ── 2. Annotations per danger level (absence checked, checklist #3) ──────────
tools=$(printf '%s' "$l1" | jq '.result.tools')
printf '%s' "$tools" | jq -e '.[] | select(.name=="read") | .annotations.readOnlyHint == true' >/dev/null \
    || fail "read (safe) lacks readOnlyHint:true"
printf '%s' "$tools" | jq -e '.[] | select(.name=="write") | .annotations | (has("readOnlyHint") | not) and (.destructiveHint == false)' >/dev/null \
    || fail "write (writes) annotations wrong — readOnlyHint must be ABSENT: $(printf '%s' "$tools" | jq -c '.[] | select(.name=="write") | .annotations')"
printf '%s' "$tools" | jq -e '.[] | select(.name=="read") | .inputSchema.properties.path.description | length > 0' >/dev/null \
    || fail "inputSchema lost the T6 descriptions"

# ── 3. Consent: no-elicitation host → canonical instructive deny; marker absent
# (the NDJSON surface this was parity-checked against is removed — the golden
# text below IS confirm_denied_msg's machine-mode message; checklist #5)
canonical_deny='cancelled: this action needs confirmation, which machine mode auto-denies unless the request carries auto_confirm:true. Do NOT retry the same call — continue with read-only tools, or report that confirmation is required.'
printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"write","arguments":{"path":"m2.txt","content":"x"}}}' > s3.script
bash "$CLIENT" --server "$SERVER" --log s3.log --script s3.script || fail "no-elicitation deny session rc $?"
mcp_deny=$(resp_for_id s3.log 2 | jq -r '.result.content[0].text')
resp_for_id s3.log 2 | jq -e '.result.isError == true' >/dev/null || fail "MCP deny not isError"
[[ "$mcp_deny" == "$canonical_deny" ]] || fail "deny text drifted from the instructive golden: '$mcp_deny'"
[[ -f m2.txt ]] && fail "MCP no-elicitation deny still wrote the file (marker present)"

# ── 4. Elicitation: approve runs, decline denies (marker spy both ways) ──────
printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"write","arguments":{"path":"ok.txt","content":"approved"}}}' > s4.script
bash "$CLIENT" --server "$SERVER" --log s4.log --script s4.script --caps elicitation --elicit accept \
    || fail "elicitation-approve session rc $?"
recv_frames s4.log | jq -e 'select(.method == "elicitation/create")' >/dev/null \
    || fail "no elicitation request was sent to a host that advertised the capability"
[[ "$(cat ok.txt 2>/dev/null)" == "approved" ]] || fail "approved write did not run"

printf '%s\n' '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"write","arguments":{"path":"no.txt","content":"denied"}}}' > s5.script
bash "$CLIENT" --server "$SERVER" --log s5.log --script s5.script --caps elicitation --elicit decline \
    || fail "elicitation-decline session rc $?"
resp_for_id s5.log 4 | jq -e '.result.isError == true' >/dev/null || fail "declined call not an error result"
[[ -f no.txt ]] && fail "declined elicitation still wrote the file (marker present)"

# garbage elicitation answer → fail-closed deny, exactly one ask, no retry loop
printf '%s\n' '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"write","arguments":{"path":"g.txt","content":"x"}}}' > s6.script
bash "$CLIENT" --server "$SERVER" --log s6.log --script s6.script --caps elicitation --elicit garbage \
    || fail "garbage-elicitation session rc $?"
[[ -f g.txt ]] && fail "garbage elicitation answer still ran the tool"
[[ "$(recv_frames s6.log | jq -c 'select(.method == "elicitation/create")' | wc -l | tr -d ' ')" == "1" ]] \
    || fail "garbage answer caused a second elicitation (must ask exactly once)"

# ── 5. Nested consent: a batch with a writes call = ONE elicitation ──────────
# Note: batch itself is writes-gated (the repo's bypass fix), so consent is
# whole-batch: one elicitation on approve, and a deny stops the entire batch
# (stricter than PLAN's per-inner-call reading — flagged, not improvised: the
# safer semantic wins until an owner amendment says otherwise).
printf '%s\n' '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"batch","arguments":{"calls":[{"tool":"read","args":{"path":"sample.txt"}},{"tool":"write","args":{"path":"b.txt","content":"from batch"}}]}}}' > s7.script
bash "$CLIENT" --server "$SERVER" --log s7.log --script s7.script --caps elicitation --elicit accept \
    || fail "batch session rc $?"
[[ "$(recv_frames s7.log | jq -c 'select(.method == "elicitation/create")' | wc -l | tr -d ' ')" == "1" ]] \
    || fail "batch fired more than one elicitation"
[[ "$(cat b.txt 2>/dev/null)" == "from batch" ]] || fail "approved batch write did not run"
bash "$CLIENT" --server "$SERVER" --log s7d.log --script s7.script --caps elicitation --elicit decline \
    || fail "batch deny session rc $?"
[[ "$(cat b.txt)" == "from batch" ]] || fail "denied batch clobbered prior state"

# ── 6. wf__ mangling: workflow runs via its MCP name; no collisions ──────────
printf '%s\n' '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"wf__test_run","arguments":{}}}' > s8.script
bash "$CLIENT" --server "$SERVER" --log s8.log --script s8.script || fail "wf__ session rc $?"
resp_for_id s8.log 7 | jq -e '.result.content[0].text | contains("no test command detected")' >/dev/null \
    || fail "wf__test_run did not round-trip to test.run: $(resp_for_id s8.log 7)"
resp_for_id s8.log 7 | jq -e '.result.content[0].text | fromjson | has("seq") or has("ts") | not' >/dev/null \
    || fail "workflow result leaked the NDJSON frame envelope"
# registry walk: no mangled workflow name collides with a tool name
collisions=$(YCA_DIR="$PROJ_ROOT" bash -c '
    set -u; export YCA_DIR; source "$YCA_DIR/harness/main.sh"
    for id in "${!YCA_WF_REGISTRY[@]}"; do
        m="wf__${id//./_}"
        [[ -n "${YCA_TOOL_REGISTRY[$m]:-}" ]] && echo "$m"
    done; true' 2>/dev/null)
[[ -z "$collisions" ]] || fail "mangled workflow names collide with tools: $collisions"

# ── 7. stdout purity: every stdout line is a JSON-RPC object ─────────────────
while IFS= read -r line; do
    printf '%s' "$line" | jq -e '.jsonrpc == "2.0"' >/dev/null 2>&1 \
        || fail "impure stdout line (protocol corruption): ${line:0:120}"
done < <(recv_frames s8.log)

# ── 8. Spill → resource link resolves byte-identical (T10 over MCP) ──────────
head -c 20000 /dev/zero | tr '\0' 'x' > big.txt
cat > s9.script <<'EOF'
{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"read","arguments":{"path":"big.txt"}}}
EOF
bash "$CLIENT" --server "$SERVER" --log s9.log --script s9.script || fail "spill session rc $?"
uri=$(resp_for_id s9.log 8 | jq -r '.result.content[] | select(.type=="resource_link") | .uri')
[[ "$uri" == spill://* ]] || fail "oversized result did not return a resource link: $(resp_for_id s9.log 8 | head -c 200)"
printf '{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"%s"}}\n' "$uri" > s10.script
bash "$CLIENT" --server "$SERVER" --log s10.log --script s10.script || fail "spill read session rc $?"
resp_for_id s10.log 9 | jq -j '.result.contents[0].text' > spilled.out
cmp -s spilled.out big.txt || fail "spilled resource is not byte-identical to the original"

# missing spill → structured not-found, not a crash
printf '%s\n' '{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"spill://r0_0_0.txt"}}' > s11.script
bash "$CLIENT" --server "$SERVER" --log s11.log --script s11.script || fail "missing-spill session rc $?"
resp_for_id s11.log 10 | jq -e '.error.code == -32002' >/dev/null || fail "missing spill did not return a clean not-found"

# ── 9. Serial multi-id: B sent before A is answered; both ids correct ────────
out=$(printf '%s\n' \
    '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":"A","method":"tools/call","params":{"name":"read","arguments":{"path":"sample.txt"}}}' \
    '{"jsonrpc":"2.0","id":7,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","id":106,"method":"notifications/cancelled","params":{"requestId":"A"}}' \
    '{"jsonrpc":"2.0","id":8,"method":"ping","params":{}}' \
    '{"jsonrpc":"2.0","method":"notifications/exit"}' \
    | HARNESS_UPDATE_ENABLED=false timeout 30 bash "$HARNESS" --ui mcp 2>/dev/null)
printf '%s\n' "$out" | jq -es '[.[] | select(has("method") | not) | .id] == [1,"A",7,8]' >/dev/null \
    || fail "serial ids answered wrongly/out of order: $(printf '%s\n' "$out" | jq -c '.id')"

# ── 10. SIGPIPE: client dies mid-stream → cleanup runs, no silent death ──────
set +e
{ printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
  sleep 1
  printf '%s\n' '{"jsonrpc":"2.0","id":3,"method":"ping","params":{}}'
  sleep 1
} | HARNESS_UPDATE_ENABLED=false timeout 30 bash "$HARNESS" --ui mcp 2>sigpipe.err | head -c 20 >/dev/null
rc=("${PIPESTATUS[@]}")
set -e
[[ "${rc[1]}" == "141" ]] || fail "server did not exit via the SIGPIPE trap (rc ${rc[1]})"
grep -q "Cleaning up" sigpipe.err || fail "SIGPIPE exit skipped cleanup (no 'Cleaning up' in stderr)"

# ── 11. Fuzz: the corpus never crashes the reader; stream stays usable ───────
bash "$CLIENT" --server "$SERVER" --log fuzz.log --fuzz "$CORPUS" \
    || fail "fuzz corpus broke the server (client rc $?)"

# ── 14. stdin-drain immunity: no tool or workflow may eat the frame stream ───
# A tool/workflow that runs a stdin-reading command (git shortlog / kubectl
# describe with no explicit range read commit/resource lists from stdin when it
# is not a TTY) must NOT consume the JSON-RPC frames that follow its own call.
# Regression for the black-box finding: quality_churn (tool) and k8s.describe
# (workflow) each silently killed the session by draining stdin. The guard is
# `</dev/null` on the tool exec (core/tools.sh) and the workflow run (mcp.sh).
export MCP_FLAGS="--enable quality --enable kubernetes"
drain_probe() {  # NAME  -> "PASS"/"FAIL": are trailing pings still answered?
    printf '%s\n' \
        '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"d","version":"1"}}}' \
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"$1\",\"arguments\":{}}}" \
        '{"jsonrpc":"2.0","id":701,"method":"ping","params":{}}' \
        '{"jsonrpc":"2.0","id":702,"method":"ping","params":{}}' \
        '{"jsonrpc":"2.0","method":"notifications/exit"}' \
        | HARNESS_UPDATE_ENABLED=false MCP_FLAGS="$MCP_FLAGS" timeout 30 bash "$HARNESS" --enable quality --enable kubernetes 2>/dev/null \
        | jq -rs '[.[] | select(.id==701 or .id==702)] | length'
}
[[ "$(drain_probe quality_churn)" == "2" ]] \
    || fail "quality_churn drained the frame stream (trailing pings lost)"
[[ "$(drain_probe wf__k8s_describe)" == "2" ]] \
    || fail "wf__k8s_describe drained the frame stream (trailing pings lost)"
unset MCP_FLAGS

# ── 12. Consent is PER CALL: one approval never leaks to the next call ───────
# (replaces the removed NDJSON per-frame consent-scope test)
cat > s12.script <<'EOF'
{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"write","arguments":{"path":"scope1.txt","content":"a"}}}
{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"write","arguments":{"path":"scope2.txt","content":"b"}}}
EOF
bash "$CLIENT" --server "$SERVER" --log s12.log --script s12.script --caps elicitation --elicit accept \
    || fail "consent-scope session rc $?"
n_elicit=$(recv_frames s12.log | jq -c 'select(.method == "elicitation/create")' | wc -l | tr -d ' ')
[[ "$n_elicit" == "2" ]] || fail "consent leaked across calls: 2 writes produced $n_elicit elicitations"
[[ -f scope1.txt && -f scope2.txt ]] || fail "approved writes did not both run"

# ── 13. The grounding prompt survives the loop removal (M5) ──────────────────
cat > s13.script <<'EOF'
{"jsonrpc":"2.0","id":30,"method":"prompts/list","params":{}}
{"jsonrpc":"2.0","id":31,"method":"prompts/get","params":{"name":"grounding","arguments":{"goal":"port the tests"}}}
EOF
bash "$CLIENT" --server "$SERVER" --log s13.log --script s13.script || fail "prompts session rc $?"
resp_for_id s13.log 30 | jq -e '.result.prompts[0].name == "grounding"' >/dev/null \
    || fail "grounding prompt not listed"
g=$(resp_for_id s13.log 31 | jq -r '.result.messages[0].content.text')
[[ "$g" == *"Ground every claim"* ]] || fail "grounding prompt lost its anti-drift rules"
[[ "$g" == *"port the tests"* ]] || fail "grounding prompt ignored the goal argument"

echo "test_mcp_server OK"
exit 0
