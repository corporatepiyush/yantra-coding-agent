# tools/ssh.sh — SSH/Remote tools (safe: commands via stdin, no injection)

# _ssh_host_ok HOST -> print HOST if safe, else fail. A host that begins with '-'
# or carries shell/ssh metacharacters is an OPTION-INJECTION vector: ssh/scp read
# `-oProxyCommand=<payload>` as an option and execute <payload> on the LOCAL host.
# Every ssh/scp/tunnel entry validates the host through here.
_ssh_host_ok() { shell_arg_safe "$1"; }

# _ssh_run HOST CMD [ARG...] — run CMD on HOST. CMD is piped over stdin (never on
# the local argv) and ARGs are passed as positional params to the REMOTE shell,
# so a value (log path, unit, mount path) can't break out of the remote command.
# Closes both local option-injection and remote argument-injection.
_ssh_run() {
    local host="$1" cmd="$2"; shift 2
    _ssh_host_ok "$host" >/dev/null || { printf 'invalid host (unsafe characters or leading dash)'; return 1; }
    printf '%s' "$cmd" | ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$host" 'bash -s' -- "$@" 2>&1
}

tool_ssh_exec() {
    local host cmd; host=$(tool_arg host "${1:-}"); cmd=$(tool_arg command "${2:-}")
    [[ -n "$cmd" ]] || { printf 'command required'; return 1; }
    _ssh_host_ok "$host" >/dev/null || { printf 'invalid host'; return 1; }
    confirm_action "Run a command on REMOTE host $host" "$cmd" || { confirm_denied_msg; return 1; }
    _ssh_run "$host" "$cmd"
}
tool_ssh_upload() {
    local src host dst; src=$(tool_arg src "${1:-}"); host=$(tool_arg host); dst=$(tool_arg dst)
    [[ -n "$src" && -n "$host" && -n "$dst" ]] || { printf 'src, host, dst required'; return 1; }
    path_check_allowed "$src" || { printf 'path not allowed: %s' "$src"; return 1; }
    _ssh_host_ok "$host" >/dev/null || { printf 'invalid host'; return 1; }
    confirm_action "Copy local $src -> REMOTE $host:$dst" "scp $src $host:$dst" || { confirm_denied_msg; return 1; }
    scp -- "$src" "$host:$dst" 2>&1
}
tool_ssh_download() {
    local host src dst; host=$(tool_arg host "${1:-}"); src=$(tool_arg src); dst=$(tool_arg dst)
    [[ -n "$host" && -n "$src" && -n "$dst" ]] || { printf 'host, src, dst required'; return 1; }
    path_check_allowed "$dst" || { printf 'path not allowed: %s' "$dst"; return 1; }
    _ssh_host_ok "$host" >/dev/null || { printf 'invalid host'; return 1; }
    confirm_action "Copy REMOTE $host:$src -> local $dst" "scp $host:$src $dst" || { confirm_denied_msg; return 1; }
    scp -- "$host:$src" "$dst" 2>&1
}
tool_ssh_tail_log() {
    local host lines logfile
    host=$(tool_arg host "${1:-}"); lines=$(int_guard "$(tool_arg lines 50)" 50); logfile=$(tool_arg logfile /var/log/syslog)
    _ssh_run "$host" 'tail -n "$1" -- "$2"' "$lines" "$logfile"
}
tool_ssh_journal() {
    local host unit; host=$(tool_arg host "${1:-}"); unit=$(tool_arg unit "${2:-}")
    [[ -n "$unit" ]] || { printf 'unit required'; return 1; }
    _ssh_run "$host" 'journalctl -u "$1" --no-pager | tail -50' "$unit"
}
tool_ssh_disk_usage() {
    local host path; host=$(tool_arg host "${1:-}"); path=$(tool_arg path /)
    _ssh_run "$host" 'df -h -- "$1"' "$path"
}
tool_ssh_processes()    { _ssh_run "$(tool_arg host "${1:-}")" 'ps aux'; }
tool_ssh_tunnel() {
    local lport rhost rport
    lport=$(int_guard "$(tool_arg local 0)" 0); rport=$(int_guard "$(tool_arg remote_port 0)" 0); rhost=$(tool_arg remote_host)
    (( lport > 0 && rport > 0 )) || { printf 'valid local and remote_port required'; return 1; }
    _ssh_host_ok "$rhost" >/dev/null || { printf 'invalid remote_host'; return 1; }
    confirm_action "Open SSH tunnel localhost:$lport -> $rhost:$rport (backgrounded)" "ssh -fN -L $lport:localhost:$rport $rhost" || { confirm_denied_msg; return 1; }
    ssh -fN -L "${lport}:localhost:${rport}" "$rhost" 2>&1
}

# ── sshfs: mount a remote directory as a local filesystem ────────────────────
_sshfs_missing() { printf 'sshfs missing — install it\n  macOS: brew install macfuse sshfs\n  Linux: apt install sshfs / dnf install fuse-sshfs'; }

# ssh_mount — mount host:remote_path at a local mountpoint via sshfs.
tool_ssh_mount() {
    command -v sshfs &>/dev/null || { _sshfs_missing; return 127; }
    local host remote mount
    host=$(tool_arg host "${1:-}"); remote=$(tool_arg remote_path "$(tool_arg path /)"); mount=$(tool_arg mount "$(tool_arg local)")
    [[ -n "$host" && -n "$mount" ]] || { printf 'host and mount (local mountpoint) required'; return 1; }
    shell_arg_safe "$host" >/dev/null || { printf 'invalid host'; return 1; }
    path_check_allowed "$mount" || { printf 'mountpoint not allowed: %s' "$mount"; return 1; }
    path_ensure_dir "$mount"
    # reconnect + drop dead mounts so a dropped SSH session doesn't wedge the mount.
    sshfs -o reconnect,ServerAliveInterval=15,ServerAliveCountMax=3,idmap=user \
        "${host}:${remote}" "$mount" 2>&1 && printf 'mounted %s:%s at %s' "$host" "$remote" "$mount"
}

# ssh_unmount — unmount an sshfs mountpoint (platform-aware).
tool_ssh_unmount() {
    local mount; mount=$(tool_arg mount "$(tool_arg local "$1")")
    [[ -n "$mount" ]] || { printf 'mount (local mountpoint) required'; return 1; }
    path_check_allowed "$mount" || { printf 'mountpoint not allowed: %s' "$mount"; return 1; }
    if command -v fusermount &>/dev/null; then fusermount -u "$mount" 2>&1 && printf 'unmounted %s' "$mount"
    elif command -v fusermount3 &>/dev/null; then fusermount3 -u "$mount" 2>&1 && printf 'unmounted %s' "$mount"
    else umount "$mount" 2>&1 && printf 'unmounted %s' "$mount"; fi
}

# ── ssh_list_hosts: list configured hosts from ~/.ssh/config ─────────────────────
tool_ssh_list_hosts() {
    local cfg="$HOME/.ssh/config"
    [[ -f "$cfg" ]] || { printf 'no ~/.ssh/config'; return 0; }
    awk '
        tolower($1)=="host" && $2 != "*" { if (h) print line; h=$2; line=sprintf("%-25s", h) }
        tolower($1)=="hostname" && h { line=line " -> " $2 }
        tolower($1)=="user" && h     { line=line "  (user " $2 ")" }
        tolower($1)=="port" && h     { line=line "  :" $2 }
        END { if (h) print line }
    ' "$cfg"
}

# ── ssh_list_keys: local key fingerprints + what the agent holds ──────────────────
tool_ssh_list_keys() {
    local k found=0
    printf '=== ~/.ssh public keys ===\n'
    for k in "$HOME"/.ssh/*.pub; do
        [[ -f "$k" ]] || continue
        found=1
        ssh-keygen -lf "$k" 2>/dev/null || printf 'unreadable: %s\n' "$k"
    done
    [[ "$found" == 1 ]] || printf '(none)\n'
    printf '\n=== ssh-agent keys ===\n'
    ssh-add -l 2>&1
}

# ── ssh_check: is a host reachable with key auth (and how fast)? ─────────────
tool_ssh_check() {
    local host; host=$(shell_arg_safe "${1:?}") || { printf 'invalid host'; return 1; }
    local t0="$EPOCHREALTIME"
    if ssh -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new "$host" 'exit 0' 2>/dev/null; then
        awk -v a="$EPOCHREALTIME" -v b="$t0" -v h="$host" 'BEGIN{printf "%s reachable, key auth ok (%.2fs)\n", h, a-b}'
    else
        printf '%s unreachable or key auth failed (try: ssh -v %s)' "$host" "$host"
        return 1
    fi
}

tool_register "ssh_exec"      tool_ssh_exec      '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"command":{"type":"string","description":"the shell command to run"}},"required":["host","command"]}' writes all ssh
tool_register "ssh_upload"        tool_ssh_upload        '{"type":"object","properties":{"src":{"type":"string","description":"source path"},"host":{"type":"string","description":"target hostname or IP address"},"dst":{"type":"string","description":"destination path"}},"required":["src","host","dst"]}' writes all ssh
tool_register "ssh_download"      tool_ssh_download      '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"src":{"type":"string","description":"source path"},"dst":{"type":"string","description":"destination path"}},"required":["host","src","dst"]}' writes all ssh
tool_register "ssh_tail_log"   tool_ssh_tail_log   '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"lines":{"type":"integer","description":"number of lines to return"},"logfile":{"type":"string","description":"the logfile"}},"required":["host"]}' safe all ssh
tool_register "ssh_journal" tool_ssh_journal '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"unit":{"type":"string","description":"the unit"}},"required":["host","unit"]}' safe all ssh
tool_register "ssh_disk_usage"   tool_ssh_disk_usage   '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"}},"required":["host"]}' safe all ssh
tool_register "ssh_processes"     tool_ssh_processes     '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"}},"required":["host"]}' safe all ssh
tool_register "ssh_tunnel"    tool_ssh_tunnel    '{"type":"object","properties":{"local":{"type":"integer","description":"local path"},"remote_host":{"type":"string","description":"the remote hostname"},"remote_port":{"type":"integer","description":"the remote port number"}},"required":["local","remote_host","remote_port"]}' writes all ssh
tool_register "ssh_mount"     tool_ssh_mount     '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"},"remote_path":{"type":"string","description":"the remote path"},"mount":{"type":"string","description":"the mount point path"}},"required":["host","mount"]}' writes all ssh
tool_register "ssh_unmount"   tool_ssh_unmount   '{"type":"object","properties":{"mount":{"type":"string","description":"the mount point path"}},"required":["mount"]}' writes all ssh
tool_register "ssh_list_hosts"     tool_ssh_list_hosts     '{"type":"object","properties":{}}' safe all ssh
tool_register "ssh_list_keys"      tool_ssh_list_keys      '{"type":"object","properties":{}}' safe all ssh
tool_register "ssh_check"     tool_ssh_check     '{"type":"object","properties":{"host":{"type":"string","description":"target hostname or IP address"}},"required":["host"]}' safe all ssh
