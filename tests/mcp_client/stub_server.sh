#!/usr/bin/env bash
# Deterministic MCP stub server for T4 client tests. Speaks JSON-RPC over its
# own stdin/stdout (coproc-friendly). Every response is fixed text — no
# timestamps, no randomness — so a captured session is a valid golden.
#
# Behaviors the client's auto-responder must survive:
#   tools/call echo        → a notification FIRST, then the result (interleave)
#   tools/call danger_tool → elicitation/create round-trip decides the result
#   tools/call llm_tool    → sampling/createMessage round-trip becomes the result
#   STUB_PROTO env         → override the echoed protocolVersion (mismatch test)
set -Euo pipefail

PROTO="${STUB_PROTO:-2025-11-25}"
SRV_ID=100   # deterministic server-request ids: 101, 102, …
exec 3>&1    # the wire — ask() runs inside $() and must bypass the capture

reply()  { printf '{"jsonrpc":"2.0","id":%s,"result":%s}\n' "$1" "$2"; }
error()  { printf '{"jsonrpc":"2.0","id":%s,"error":{"code":%s,"message":"%s"}}\n' "$1" "$2" "$3"; }

# ask CLIENT-METHOD PARAMS -> the client's response frame (or rc 1 on timeout).
# The request goes to fd 3 (the real wire): callers capture our stdout.
ask() {
    local method="$1" params="$2" id=$((++SRV_ID)) line got_id
    printf '{"jsonrpc":"2.0","id":%s,"method":"%s","params":%s}\n' "$id" "$method" "$params" >&3
    while IFS= read -r -t 5 line; do
        [[ -z "$line" ]] && continue
        got_id=$(printf '%s' "$line" | jq -c '.id // null' 2>/dev/null)
        [[ "$got_id" == "$id" ]] && { printf '%s' "$line"; return 0; }
    done
    return 1
}

while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    if ! printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
        printf '{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}\n'
        continue
    fi
    id=$(printf '%s' "$line" | jq -c '.id // null')
    method=$(printf '%s' "$line" | jq -r '.method // empty')
    [[ -z "$method" ]] && continue

    case "$method" in
        initialize)
            reply "$id" "{\"protocolVersion\":\"$PROTO\",\"serverInfo\":{\"name\":\"stub\",\"version\":\"1.0\"},\"capabilities\":{\"tools\":{}}}" ;;
        ping)
            reply "$id" '{}' ;;
        tools/list)
            reply "$id" '{"tools":[{"name":"echo","description":"echo text back","inputSchema":{"type":"object","properties":{"text":{"type":"string","description":"text to echo"}},"required":["text"]}},{"name":"danger_tool","description":"needs consent","inputSchema":{"type":"object","properties":{}}},{"name":"llm_tool","description":"asks the host model","inputSchema":{"type":"object","properties":{}}}]}' ;;
        tools/call)
            name=$(printf '%s' "$line" | jq -r '.params.name // empty')
            case "$name" in
                echo)
                    # interleaved notification BEFORE the response — the client
                    # must not desync on it
                    printf '{"jsonrpc":"2.0","method":"notifications/message","params":{"level":"info","logger":"stub","data":{"message":"about to echo"}}}\n'
                    text=$(printf '%s' "$line" | jq -r '.params.arguments.text // "no text"')
                    reply "$id" "$(jq -cn --arg t "Echo: $text" '{content:[{type:"text",text:$t}],isError:false}')" ;;
                danger_tool)
                    if resp=$(ask elicitation/create '{"message":"stub needs consent: run danger_tool?","requestedSchema":{"type":"object","properties":{"confirm":{"type":"boolean"}},"required":["confirm"]}}') \
                       && printf '%s' "$resp" | jq -e '.result.action == "accept" and (.result.content.confirm != false)' >/dev/null 2>&1; then
                        reply "$id" '{"content":[{"type":"text","text":"danger_tool ran"}],"isError":false}'
                    else
                        reply "$id" '{"content":[{"type":"text","text":"denied: consent was not given"}],"isError":true}'
                    fi ;;
                llm_tool)
                    if resp=$(ask sampling/createMessage '{"messages":[{"role":"user","content":{"type":"text","text":"say something"}}],"maxTokens":32}') \
                       && completion=$(printf '%s' "$resp" | jq -er '.result.content.text' 2>/dev/null); then
                        reply "$id" "$(jq -cn --arg t "model said: $completion" '{content:[{type:"text",text:$t}],isError:false}')"
                    else
                        reply "$id" '{"content":[{"type":"text","text":"sampling unavailable; would fall back to provider"}],"isError":true}'
                    fi ;;
                *)
                    error "$id" -32602 "Unknown tool: $name" ;;
            esac ;;
        resources/read)
            uri=$(printf '%s' "$line" | jq -r '.params.uri // empty')
            if [[ "$uri" == "plan://current" ]]; then
                reply "$id" '{"contents":[{"uri":"plan://current","mimeType":"text/plain","text":"stub plan"}]}'
            else
                error "$id" -32002 "Resource not found"
            fi ;;
        notifications/exit)
            exit 0 ;;
        notifications/*)
            : ;;
        *)
            [[ "$id" != "null" ]] && error "$id" -32601 "Method not found: $method" ;;
    esac
done
exit 0
