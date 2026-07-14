# lib/11-process.sh — Process management utilities

# proc_exists PID -> 0 if process is running
proc_exists() {
    [[ "$1" =~ ^[0-9]+$ ]] || return 1
    kill -0 "$1" 2>/dev/null
}

# proc_kill PID [SIGNAL]
proc_kill() {
    local pid="$1" sig="${2:-TERM}"
    kill -"$sig" "$pid" 2>/dev/null
}

# proc_kill_wait PID [TIMEOUT] -> kill and wait up to TIMEOUT seconds
proc_kill_wait() {
    local pid="$1" timeout="${2:-5}"
    proc_kill "$pid" TERM 2>/dev/null
    local i
    for ((i=0; i<timeout; i++)); do
        proc_exists "$pid" || return 0
        sleep 1
    done
    proc_kill "$pid" KILL 2>/dev/null
    sleep 1
    ! proc_exists "$pid"
}

# proc_children PID -> prints child PIDs (one per line)
proc_children() {
    local pid="$1"
    pgrep -P "$pid" 2>/dev/null || ps -o pid= --ppid "$pid" 2>/dev/null | tr -d ' '
}

# proc_kill_tree PID -> kills process and all its children
proc_kill_tree() {
    local pid="$1"
    local children
    children=$(proc_children "$pid")
    local child
    while IFS= read -r child; do
        [[ -n "$child" ]] && proc_kill_tree "$child"
    done <<< "$children"
    proc_kill "$pid" KILL 2>/dev/null
}

# proc_cpu PID -> CPU percentage
proc_cpu() {
    ps -p "$1" -o %cpu= 2>/dev/null | tr -d ' ' || printf '0'
}

# proc_mem PID -> memory percentage
proc_mem() {
    ps -p "$1" -o %mem= 2>/dev/null | tr -d ' ' || printf '0'
}

# proc_rss PID -> resident set size in KB
proc_rss() {
    ps -p "$1" -o rss= 2>/dev/null | tr -d ' ' || printf '0'
}

# proc_command PID -> command line
proc_command() {
    ps -p "$1" -o command= 2>/dev/null || printf ''
}

# proc_list PATTERN -> list matching processes (pid command)
proc_list() {
    local pattern="${1:-.}"
    ps aux 2>/dev/null | grep -i "$pattern" | grep -v grep || ps -A 2>/dev/null | head -30
}

# proc_listening_ports -> list TCP listening sockets
proc_listening_ports() {
    if command -v ss &>/dev/null; then
        ss -tlnp 2>/dev/null
    elif command -v lsof &>/dev/null; then
        lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null
    elif command -v netstat &>/dev/null; then
        netstat -tlnp 2>/dev/null
    fi
}

# proc_port_in_use PORT -> 0 if something is listening on PORT
proc_port_in_use() {
    local port="$1"
    proc_listening_ports 2>/dev/null | grep -q ":$port\b"
}

# proc_find_free_port START END -> prints first free port
proc_find_free_port() {
    local start="${1:-8000}" end="${2:-9000}" p
    for ((p=start; p<=end; p++)); do
        if ! proc_port_in_use "$p"; then
            printf '%d' "$p"
            return 0
        fi
    done
    return 1
}

# proc_bg COMMAND... -> run command in background, print PID
proc_bg() {
    "$@" &
    printf '%d' "$!"
}

# proc_wait_any -> wait for any single background job to finish, print its PID.
proc_wait_any() {
    local pid
    wait -n -p pid 2>/dev/null
    printf '%s' "$pid"
}

# proc_bg_with_log COMMAND... -> run in background, log to file, print PID
proc_bg_with_log() {
    local logfile="$1"; shift
    "$@" >> "$logfile" 2>&1 &
    printf '%d' "$!"
}

# proc_nohup COMMAND... -> run detached from terminal
proc_nohup() {
    local logfile="${YCA_LOG_FILE:-/dev/null}"
    nohup "$@" >> "$logfile" 2>&1 &
    printf '%d' "$!"
}
