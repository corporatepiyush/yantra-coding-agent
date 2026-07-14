# lib/14-logging.sh — Logging and event recording

# logmsg MESSAGE... -> prints to stderr (always, in all modes)
logmsg() {
    printf '%s\n' "$*" >&2
}

# log_debug MESSAGE... -> only if log level is debug
log_debug() {
    [[ "${YCA_LOG_LEVEL:-info}" == "debug" ]] && printf '[DEBUG] %s\n' "$*" >&2
}

# log_info MESSAGE...
log_info() {
    printf '[INFO] %s\n' "$*" >&2
}

# log_warn MESSAGE...
log_warn() {
    printf '[WARN] %s\n' "$*" >&2
}

# log_error MESSAGE...
log_error() {
    printf '[ERROR] %s\n' "$*" >&2
}

# log_event LEVEL KIND MESSAGE [DATA_JSON]
# Records to the events table in SQLite
log_event() {
    local level="$1" kind="$2" message="$3" data_json="${4:-}"
    [[ -z "$YCA_DB_PATH" ]] && return 0
    local agent="${YCA_ROLE:-main}"
    # Redact secrets from message
    message=$(str_redact "$message" "$YCA_API_TOKEN")
    db_exec "INSERT INTO events(agent, level, kind, message, data_json) VALUES ($(sql_quote "$agent"), $(sql_quote "$level"), $(sql_quote "$kind"), $(sql_quote "$message"), $(sql_quote "$data_json"));" 2>/dev/null || true
}

# log_workflow_start WF_ID
log_workflow_start() {
    log_event "info" "workflow.start" "Starting: $1"
}

# log_workflow_end WF_ID EXIT_CODE
log_workflow_end() {
    log_event "info" "workflow.end" "Finished: $1 rc=$2" "{\"exit_code\":$2}"
}

# log_tool_call TOOL_NAME ARGS_JSON
log_tool_call() {
    log_event "info" "tool.call" "$1" "$2"
}

# log_bash_exec COMMAND EXIT_CODE
log_bash_exec() {
    log_event "info" "bash.exec" "$1" "{\"exit\":$2}"
}

# Progress message to stderr (human-readable)
log_progress() {
    local stage="$1" message="$2"
    logmsg "  $(color_symbol progress) ${stage}: ${message}"
}

# Success message
log_success() {
    logmsg "$(c_ok "$SYM_OK") $1"
}

# Failure message
log_failure() {
    logmsg "$(c_fail "$SYM_FAIL") $1"
}

# Warning message
log_warning() {
    logmsg "$(c_warn "$SYM_WARN") $1"
}

# Print a key-value pair nicely
log_kv() {
    local key="$1" val="$2"
    logmsg "  $(c_dim "$key"): $val"
}
