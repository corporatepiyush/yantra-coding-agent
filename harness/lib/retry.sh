# lib/retry.sh — Retry helper with exponential backoff + jitter
# Usage: retry <max_attempts> <cmd...>
#   retry 3 curl -sS "$url"
#   retry 3 db_exec "INSERT INTO ..."

retry() {
    local max="${1:?max attempts required}"; shift
    local attempt=0 delay=1 max_delay=30
    while [[ $attempt -lt $max ]]; do
        ((attempt++))
        if "$@"; then
            [[ $attempt -gt 1 ]] && log_debug "retry succeeded on attempt $attempt"
            return 0
        fi
        if [[ $attempt -lt $max ]]; then
            local jitter=$(( SRANDOM % 1000 ))
            local sleep_time=$(( delay + jitter / 1000 ))
            log_debug "retry $attempt/$max failed, sleeping ${sleep_time}s"
            sleep "$sleep_time"
            delay=$(( delay * 2 ))
            (( delay > max_delay )) && delay=$max_delay
        fi
    done
    log_warn "retry exhausted after $max attempts: $*"
    return 1
}

# retry_with_backoff <max> <initial_delay> <cmd...>
retry_with_backoff() {
    local max="$1" delay="$2"; shift 2
    local attempt=0
    while [[ $attempt -lt $max ]]; do
        ((attempt++))
        if "$@"; then return 0; fi
        [[ $attempt -lt $max ]] && sleep "$delay"
        delay=$(( delay * 2 ))
    done
    return 1
}

# retry_until_timeout <timeout_secs> <interval_secs> <cmd...>
# Runs cmd every interval until it succeeds or timeout reached
retry_until_timeout() {
    local timeout="$1" interval="$2"; shift 2
    local elapsed=0
    while [[ $elapsed -lt $timeout ]]; do
        if "$@"; then return 0; fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
    done
    log_warn "retry_until_timeout: ${timeout}s exceeded"
    return 1
}
