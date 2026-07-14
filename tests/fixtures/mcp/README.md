# MCP protocol fixtures

`stub_session.golden` — verbatim frame capture of the T4 client driving
`tests/mcp_client/stub_server.sh` (handshake + tools/list + echo + elicitation
accept + sampling + resources/read). Never hand-edit it (hand-typed fixtures
encode the author's assumptions and test nothing).

Regenerate ONLY deliberately, and review the diff like code:

    bash tests/mcp_client/client.sh \
        --server "bash tests/mcp_client/stub_server.sh" \
        --log tests/fixtures/mcp/stub_session.golden \
        --script <(printf '%s\n' \
          '{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}' \
          '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"echo","arguments":{"text":"hello"}}}' \
          '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"danger_tool","arguments":{}}}' \
          '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"llm_tool","arguments":{}}}' \
          '{"jsonrpc":"2.0","id":5,"method":"resources/read","params":{"uri":"plan://current"}}') \
        --caps sampling,elicitation --elicit accept --sampling-text "canned completion"

`fuzz_corpus.txt` — malformed/truncated/hostile frames replayed against the
REAL server by test_mcp_server.sh via `client.sh --fuzz`. Add a line for every
reader bug found; a bug is not fixed until its reproduction lives here (II.0.2
rule b).
