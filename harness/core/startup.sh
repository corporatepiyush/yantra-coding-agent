# core/startup.sh — LLM-unavailable flow (the startup notices died with the
# NDJSON/REPL surfaces; MCP hosts get diagnostics via logging notifications).

# llm_unavailable_flow — invoked when an LLM-backed (mid/high) call finds no live
# provider. Explains the situation and, in the human REPL, offers to paste a URL
# right now (session-only, never written to the config file). Returns 0 if a URL
# was added (caller can proceed), 1 to continue without LLM.
llm_unavailable_flow() {
    logmsg ""
    logmsg "$(c_warn "$SYM_WARN This action needs an LLM, but no provider URL is configured.")"
    logmsg "$(c_dim '   You can add one under "providers" in yantra.config.json (think/build/tool),')"
    logmsg "$(c_dim '   or set HARNESS_LLM_URL. Tools and workflows without _llm_ in their name work without it.')"
    # Under MCP a tool fn runs inside a capture subshell where fd 9 is still the
    # real stdout — an emitted frame here would land inside the JSON-RPC stream.
    # The stderr log above is the diagnostic; the caller's graceful "unavailable"
    # text becomes the tool result (412 semantics preserved in the message).
    if [[ "$YCA_UI_MODE" == "mcp" ]]; then
        return 1
    fi
    emit_error "412" "No LLM provider configured. Add one to yantra.config.json (providers.think/build/tool) or set HARNESS_LLM_URL. Tools and workflows without _llm_ in their name still work."
    return 1
}
