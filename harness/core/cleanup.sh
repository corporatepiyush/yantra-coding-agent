# core/cleanup.sh — Trap handler (incremental_vacuum, no full VACUUM, kill children)

cleanup() {
    [[ "$YCA_CLEANUP_CALLED" == "1" ]] && return 0
    YCA_CLEANUP_CALLED=1
    logmsg "$(c_dim "Cleaning up...")"
    [[ -n "$YCA_HEARTBEAT_PID" ]] && proc_kill "$YCA_HEARTBEAT_PID" 2>/dev/null || true
    [[ -n "$YCA_UPDATE_PID" ]] && proc_kill "$YCA_UPDATE_PID" 2>/dev/null || true
    # Kill child processes (but not ourselves)
    local child
    while IFS= read -r child; do
        [[ -n "$child" && "$child" != "$YCA_PID" ]] && proc_kill "$child" 2>/dev/null || true
    done < <(proc_children "$YCA_PID" 2>/dev/null)
    [[ -n "$YCA_DB_PATH" ]] && {
        db_exec "DELETE FROM heartbeats WHERE ts < datetime('now','-10 minutes');" 2>/dev/null || true
        db_exec "DELETE FROM events WHERE ts < datetime('now','-1 hour');" 2>/dev/null || true
        # Retention for the tables that otherwise grow forever across sessions:
        # consumed inter-agent messages, stale tasks, and old change records.
        db_exec "DELETE FROM messages WHERE consumed=1 AND ts < datetime('now','-7 days');" 2>/dev/null || true
        db_exec "DELETE FROM tasks WHERE updated_ts < datetime('now','-90 days');" 2>/dev/null || true
        db_exec "DELETE FROM changes WHERE ts < datetime('now','-90 days');" 2>/dev/null || true
        db_exec "PRAGMA incremental_vacuum;" 2>/dev/null || true
    } || true
}

cleanup_register_trap() {
    trap cleanup EXIT INT TERM
    # SIGPIPE: a machine-mode client (MCP/NDJSON) dying mid-write must still run
    # cleanup — untrapped, the shell dies silently and skips the EXIT handler.
    trap 'cleanup; exit 141' PIPE
}
