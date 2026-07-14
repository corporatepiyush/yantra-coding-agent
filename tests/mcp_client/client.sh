#!/usr/bin/env bash
# tests/mcp_client — the T4 MCP test client. A test INSTRUMENT, not a product:
# it drives an MCP server exactly as scripted and records every frame, so CI
# failures are unambiguous and never depend on a third-party host.
#
# Usage:
#   client.sh --server CMD --log FILE [--script FILE] [--fuzz FILE]
#             [--caps LIST] [--elicit accept|decline|garbage|none]
#             [--sampling-text TEXT] [--timeout SECS]
#
#   --server CMD        command line that starts the server (spoken to over
#                       stdin/stdout via coproc)
#   --log FILE          frame log; every line is ">>\t<frame>" (sent) or
#                       "<<\t<frame>" (received) in exact wire order
#   --script FILE       frames to send, one JSON object per line (# and blank
#                       lines skipped). A frame WITH an id waits for the
#                       matching response before the next line; notifications
#                       are fire-and-forget.
#   --caps LIST         comma list of client capabilities to advertise in the
#                       auto-handshake: sampling,elicitation,roots (default none)
#   --elicit MODE       scripted answer for every elicitation/create request:
#                       accept | decline | garbage (malformed reply) | none
#                       (never answer — forces the server's timeout path)
#   --sampling-text T   canned completion for every sampling/createMessage
#   --fuzz FILE         fuzz mode: after the handshake, send each corpus line
#                       verbatim; assert the server survives every one, then
#                       prove stream integrity with a final ping
#   --timeout SECS      per-response wait (default 10)
#
# Exit codes: 0 ok · 1 usage/spawn failure · 2 protocol-version mismatch ·
# 3 response timeout · 4 fuzz failure (server died or final ping unanswered)
set -Euo pipefail

SERVER_CMD="" LOG_FILE="" SCRIPT_FILE="" FUZZ_FILE=""
CAPS="" ELICIT="accept" SAMPLING_TEXT="canned completion" TIMEOUT=10
PROTOCOL_VERSION="2025-11-25"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --server)        SERVER_CMD="$2"; shift 2 ;;
        --log)           LOG_FILE="$2"; shift 2 ;;
        --script)        SCRIPT_FILE="$2"; shift 2 ;;
        --fuzz)          FUZZ_FILE="$2"; shift 2 ;;
        --caps)          CAPS="$2"; shift 2 ;;
        --elicit)        ELICIT="$2"; shift 2 ;;
        --sampling-text) SAMPLING_TEXT="$2"; shift 2 ;;
        --timeout)       TIMEOUT="$2"; shift 2 ;;
        *) echo "unknown option: $1" >&2; exit 1 ;;
    esac
done
[[ -n "$SERVER_CMD" && -n "$LOG_FILE" ]] || { echo "need --server and --log" >&2; exit 1; }
: > "$LOG_FILE"

log()  { printf '%s\t%s\n' "$1" "$2" >> "$LOG_FILE"; }

coproc SRV { bash -c "$SERVER_CMD" 2>>"${LOG_FILE%.log}.server_err"; }
SRV_IN="${SRV[1]}" SRV_OUT="${SRV[0]}" srv_pid="$SRV_PID"

send() { printf '%s\n' "$1" >&"$SRV_IN"; log '>>' "$1"; }

# recv -> one frame from the server (logged), rc 1 on timeout/EOF.
recv() {
    local line
    IFS= read -r -t "$TIMEOUT" line <&"$SRV_OUT" || return 1
    log '<<' "$line"
    printf '%s' "$line"
}

# _answer_server_request FRAME — the scripted auto-responder: elicitation
# answers come from the --elicit fixture, sampling answers are the canned
# completion. This is what makes consent and sampling testable in CI.
_answer_server_request() {
    local frame="$1" id method
    id=$(printf '%s' "$frame" | jq -c '.id')
    method=$(printf '%s' "$frame" | jq -r '.method')
    case "$method" in
        elicitation/create)
            case "$ELICIT" in
                accept)  send "$(jq -cn --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{action:"accept",content:{confirm:true}}}')" ;;
                decline) send "$(jq -cn --argjson id "$id" '{jsonrpc:"2.0",id:$id,result:{action:"decline"}}')" ;;
                garbage) send "{\"jsonrpc\":\"2.0\",\"id\":$id,\"result\":\"what\"}" ;;
                none)    : ;;
            esac ;;
        sampling/createMessage)
            send "$(jq -cn --argjson id "$id" --arg t "$SAMPLING_TEXT" \
                '{jsonrpc:"2.0",id:$id,result:{role:"assistant",content:{type:"text",text:$t},model:"canned",stopReason:"endTurn"}}')" ;;
    esac
}

# await_response WANT_ID_JSON — read frames until the response with this id
# arrives; server requests are answered per fixture, notifications just logged.
await_response() {
    local want="$1" frame id method
    local deadline=$(( SECONDS + TIMEOUT ))
    while (( SECONDS < deadline )); do
        frame=$(recv) || return 1
        [[ -z "$frame" ]] && continue
        method=$(printf '%s' "$frame" | jq -r '.method // empty' 2>/dev/null)
        id=$(printf '%s' "$frame" | jq -c '.id // null' 2>/dev/null)
        if [[ -z "$method" ]]; then
            [[ "$id" == "$want" ]] && { printf '%s' "$frame"; return 0; }
            continue    # a response we did not wait for — logged, skipped
        fi
        [[ "$method" == notifications/* ]] && continue
        _answer_server_request "$frame"
    done
    return 1
}

# ── Handshake (always first; capability flags actually change the frame) ────
caps_json='{}'
for cap in ${CAPS//,/ }; do
    caps_json=$(jq -cn --argjson c "$caps_json" --arg k "$cap" '$c + {($k):{}}')
done
init=$(jq -cn --arg p "$PROTOCOL_VERSION" --argjson c "$caps_json" \
    '{jsonrpc:"2.0",id:"init",method:"initialize",params:{protocolVersion:$p,capabilities:$c,clientInfo:{name:"mcp_test_client",version:"2.0"}}}')
send "$init"
resp=$(await_response '"init"') || { echo "FAIL: no initialize response" >&2; exit 3; }
echoed=$(printf '%s' "$resp" | jq -r '.result.protocolVersion // empty')
if [[ "$echoed" != "$PROTOCOL_VERSION" ]]; then
    echo "FAIL: protocol version mismatch: sent $PROTOCOL_VERSION, server says '$echoed'" >&2
    exit 2
fi

# ── Fuzz mode ────────────────────────────────────────────────────────────────
if [[ -n "$FUZZ_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" ]] && continue
        send "$line"
        sleep 0.05
        kill -0 "$srv_pid" 2>/dev/null || { echo "FAIL: server died on corpus line: $line" >&2; exit 4; }
        # drain whatever the server said (error responses are a PASS; the
        # assertion is only: never crash, never go silent for good)
        while IFS= read -r -t 0.2 drained <&"$SRV_OUT"; do log '<<' "$drained"; done
    done < "$FUZZ_FILE"
    send '{"jsonrpc":"2.0","id":"fuzz-final","method":"ping","params":{}}'
    await_response '"fuzz-final"' >/dev/null \
        || { echo "FAIL: server unresponsive after fuzz corpus" >&2; exit 4; }
fi

# ── Scripted frames ──────────────────────────────────────────────────────────
if [[ -n "$SCRIPT_FILE" ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -z "$line" || "$line" == \#* ]] && continue
        send "$line"
        req_id=$(printf '%s' "$line" | jq -c '.id // empty' 2>/dev/null)
        if [[ -n "$req_id" ]]; then
            await_response "$req_id" >/dev/null \
                || { echo "FAIL: no response for id $req_id" >&2; exit 3; }
        fi
    done < "$SCRIPT_FILE"
fi

# ── Shutdown ─────────────────────────────────────────────────────────────────
send '{"jsonrpc":"2.0","method":"notifications/exit"}'
exec {SRV_IN}>&- 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$srv_pid" 2>/dev/null || break
    sleep 0.2
done
kill "$srv_pid" 2>/dev/null || true
exit 0
