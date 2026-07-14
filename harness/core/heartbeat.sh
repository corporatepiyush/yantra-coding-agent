# core/heartbeat.sh — Background heartbeat writer (correct PID tracking)

start_heartbeat() {
    local agent="${1:?agent name required}"
    local interval="${YCA_HEARTBEAT_INTERVAL:-5}"
    local parent_pid=$$
    db_exec "DELETE FROM heartbeats WHERE ts < datetime('now','-5 minutes');" 2>/dev/null || true
    (
        while true; do
            local cpu mem
            cpu=$(proc_cpu "$parent_pid" 2>/dev/null || printf '0')
            mem=$(proc_mem "$parent_pid" 2>/dev/null || printf '0')
            db_exec "INSERT INTO heartbeats(agent, pid, status, cpu, mem) VALUES ($(sql_quote "$agent"), $parent_pid, 'alive', ${cpu:-0}, ${mem:-0});" 2>/dev/null || true
            db_exec "DELETE FROM heartbeats WHERE ts < datetime('now','-10 minutes');" 2>/dev/null || true
            # In-session event retention: the exit-time cleanup never runs for a
            # session that lives for days, so the event log (one row per tool
            # call) would grow unbounded. 24h is plenty for the monitor tools.
            db_exec "DELETE FROM events WHERE ts < datetime('now','-1 day');" 2>/dev/null || true
            sleep "$interval"
        done
    ) &
    YCA_HEARTBEAT_PID=$!
}
