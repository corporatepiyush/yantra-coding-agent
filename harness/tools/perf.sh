# tools/perf.sh — Performance monitoring tools (cross-platform: linux/darwin)

# ── Helpers ──────────────────────────────────────────────────────────────
_perf_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# ── Doctor ─────────────────────────────────────────────────────────────────
tool_perf_doctor() {
    local out=""
    local t v
    for t in mpstat iostat sar vmstat top htop perf strace dtrace atop pidstat bpftrace; do
        v=$(command -v "$t" 2>/dev/null && printf 'ok' || printf 'MISSING')
        out+="$t: $v\n"
    done
    command -v flamegraph.pl &>/dev/null && out+="flamegraph.pl: ok\n" || out+="flamegraph.pl: MISSING\n"
    printf '%b' "$out"
}

# ── CPU ──────────────────────────────────────────────────────────────────
tool_perf_cpu_usage() {
    printf '=== Load Average ===\n'
    uptime
    printf '\n'
    case "$(os_detect)" in
        linux)
            if command -v mpstat &>/dev/null; then
                mpstat -P ALL 1 1 2>&1
            else
                _perf_missing "mpstat" "apt-get install sysstat"
                return 1
            fi
            ;;
        darwin)
            top -l 1 -n 0 2>/dev/null | head -12
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── Memory ───────────────────────────────────────────────────────────────
tool_perf_memory() {
    case "$(os_detect)" in
        linux)
            if command -v free &>/dev/null; then
                free -h
            else
                cat /proc/meminfo 2>/dev/null || _perf_missing "free" "apt-get install procps"
            fi
            if command -v vmstat &>/dev/null; then
                printf '\n=== vmstat ===\n'
                vmstat -s 2>&1 | head -20
            fi
            ;;
        darwin)
            vm_stat 2>&1
            printf '\n=== Memory pressure ===\n'
            memory_pressure 2>/dev/null | head -10 || true
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── I/O ──────────────────────────────────────────────────────────────────
tool_perf_io_stats() {
    if command -v iostat &>/dev/null; then
        case "$(os_detect)" in
            linux) iostat -x 1 1 2>&1 ;;
            darwin) iostat 1 1 2>&1 ;;
            *) iostat 2>&1 ;;
        esac
    else
        _perf_missing "iostat" "apt-get install sysstat (linux) / brew install sysstat (mac)"
        return 1
    fi
}

# ── Network ──────────────────────────────────────────────────────────────
tool_perf_network() {
    case "$(os_detect)" in
        linux)
            if command -v sar &>/dev/null; then
                sar -n DEV 1 1 2>&1
            else
                netstat -i 2>&1
            fi
            if command -v ss &>/dev/null; then
                printf '\n=== Socket stats ===\n'
                ss -s 2>&1
            fi
            ;;
        darwin)
            netstat -i 2>&1
            if command -v lsof &>/dev/null; then
                printf '\n=== Open Internet sockets ===\n'
                lsof -i -P -n 2>/dev/null | head -20 || true
            fi
            ;;
        *)
            netstat -i 2>&1
            ;;
    esac
}

# ── Disk ─────────────────────────────────────────────────────────────────
tool_perf_disk_io() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    printf '=== Disk usage ===\n'
    df -h 2>&1
    if [[ -d "$dir" ]]; then
        printf '\n=== Top directories by size ===\n'
        if command -v du &>/dev/null; then
            du -sh "$dir"/*/ 2>/dev/null | sort -rh | head -10
        fi
    fi
    printf '\n=== Inode usage ===\n'
    df -i 2>&1 | head -5
}

# ── Top processes ────────────────────────────────────────────────────────
tool_perf_top_processes() {
    if command -v ps &>/dev/null; then
        printf '=== Top 10 by CPU ===\n'
        ps aux --sort=-%cpu 2>/dev/null | head -11 || ps aux 2>/dev/null | sort -k3 -rn | head -11
        printf '\n=== Top 10 by MEM ===\n'
        ps aux --sort=-%mem 2>/dev/null | head -11 || ps aux 2>/dev/null | sort -k4 -rn | head -11
    else
        printf 'ps not found'
        return 1
    fi
}

# ── strace (linux only) ──────────────────────────────────────────────────
tool_perf_strace() {
    local pid="${1:?}"
    case "$(os_detect)" in
        linux)
            command -v strace &>/dev/null || { _perf_missing "strace" "apt-get install strace"; return 1; }
            strace -p "$pid" -c 2>&1 | head -25
            ;;
        darwin)
            printf 'strace is not available on macOS. Use dtruss instead:\n  dtruss -p %s\nOr install with: brew install dtrace' "$pid"
            return 1
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── dtrace/dtruss ────────────────────────────────────────────────────────
tool_perf_dtrace() {
    local pid="${1:?}"
    case "$(os_detect)" in
        darwin)
            command -v dtruss &>/dev/null || { _perf_missing "dtruss" "requires SIP-disabled macOS or Xcode Command Line Tools"; return 1; }
            sudo dtruss -p "$pid" 2>&1 | head -30
            ;;
        linux)
            command -v dtrace &>/dev/null && dtrace -p "$pid" 2>&1 | head -30 || \
                printf 'dtrace is not commonly available on Linux. Use strace or bpftrace instead.'
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── perf record (linux only) ────────────────────────────────────────────
tool_perf_record() {
    local pid="$1"
    [[ -z "$pid" ]] && { printf 'pid required (pass via "name" field)'; return 1; }
    case "$(os_detect)" in
        linux)
            command -v perf &>/dev/null || { _perf_missing "perf" "apt-get install linux-tools-common"; return 1; }
            perf record -p "$pid" -g -o "/tmp/perf_${EPOCHSECONDS}.data" 2>&1
            printf '\nRecorded. View with: perf report -i /tmp/perf_*.data'
            ;;
        darwin)
            printf 'perf is not available on macOS. Use dtrace/xray or instruments instead:\n  brew install dtrace\n  xcrun xctrace record --template "Time Profiler" --all-processes'
            return 1
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── pidstat (linux only) ────────────────────────────────────────────────
tool_perf_pidstat() {
    local pid="$1"
    [[ -z "$pid" ]] && { printf 'pid required (pass via "name" field)'; return 1; }
    case "$(os_detect)" in
        linux)
            command -v pidstat &>/dev/null || { _perf_missing "pidstat" "apt-get install sysstat"; return 1; }
            pidstat -urd -p "$pid" 1 3 2>&1
            ;;
        darwin)
            printf 'pidstat is not available on macOS. Use top or ps instead:\n  top -pid %s\n  ps -p %s -o pid,%%cpu,%%mem,rss,command' "$pid" "$pid"
            return 1
            ;;
        *)
            printf 'unsupported OS'
            return 1
            ;;
    esac
}

# ── Load / uptime ────────────────────────────────────────────────────────
tool_perf_load_average() {
    printf '=== System load ===\n'
    uptime 2>&1
    printf '\n=== OS ===\n'
    os_name
    printf '\n=== CPU cores ===\n'
    os_cpu_count
    printf '\n=== Memory ===\n'
    os_mem_info
    printf '\n=== Uptime ===\n'
    local uptime_sec
    uptime_sec=$(os_uptime 2>/dev/null || printf '0')
    printf '%d sec (%d days %d hours %d min)\n' "$uptime_sec" $((uptime_sec/86400)) $(( (uptime_sec%86400)/3600 )) $(( (uptime_sec%3600)/60 ))
}

# ── Benchmark a command (hyperfine, or 3 timed runs) ─────────────────────
tool_perf_benchmark() {
    local cmd="$1"
    [[ -n "$cmd" ]] || { printf 'command required (use .command)'; return 1; }
    if command -v hyperfine &>/dev/null; then
        hyperfine --warmup 1 --runs 5 "$cmd" 2>&1
    else
        printf 'hyperfine not found (brew install hyperfine) — 3 timed runs:\n'
        local i t0 t1
        for i in 1 2 3; do
            t0="$EPOCHREALTIME"
            bash -c "$cmd" >/dev/null 2>&1
            t1="$EPOCHREALTIME"
            printf 'run %d: %ss\n' "$i" "$(awk -v a="$t1" -v b="$t0" 'BEGIN{printf "%.3f", a-b}')"
        done
    fi
}

# ── Binary size breakdown ────────────────────────────────────────────────
tool_perf_binary_size() {
    local f="$1"
    [[ -f "$f" ]] || { printf 'file not found: %s' "$f"; return 1; }
    printf '=== size ===\n'; du -h "$f" 2>&1
    if command -v file &>/dev/null; then printf '\n=== type ===\n'; file -b "$f" 2>&1; fi
    if command -v size &>/dev/null; then printf '\n=== sections ===\n'; size "$f" 2>&1; fi
    if command -v nm &>/dev/null; then
        printf '\n=== largest symbols (top 15) ===\n'
        local syms
        syms=$(nm --size-sort -r "$f" 2>/dev/null | head -15)
        [[ -z "$syms" ]] && syms=$(nm "$f" 2>/dev/null | head -15)
        printf '%s\n' "${syms:-(no symbols — stripped?)}"
    fi
    case "$(os_detect)" in
        darwin) if command -v otool &>/dev/null; then printf '\n=== linked libs ===\n'; otool -L "$f" 2>/dev/null | head -15; fi ;;
        *)      if command -v ldd &>/dev/null; then printf '\n=== linked libs ===\n'; ldd "$f" 2>/dev/null | head -15; fi ;;
    esac
}

# ── Memory/CPU of a whole process tree ───────────────────────────────────
tool_perf_process_tree() {
    local pid; pid=$(int_guard "$(tool_arg pid "$1")" 0)
    (( pid > 0 )) || { printf 'valid pid required'; return 1; }
    local -A children=()
    local p pp
    while read -r p pp; do children[$pp]+=" $p"; done < <(ps ax -o pid=,ppid= 2>/dev/null)
    local -a queue=("$pid") all=()
    local cur
    while ((${#queue[@]})); do
        cur="${queue[0]}"; queue=("${queue[@]:1}")
        all+=("$cur")
        for p in ${children[$cur]:-}; do queue+=("$p"); done
    done
    local csv; csv=$(IFS=,; printf '%s' "${all[*]}")
    printf '%d processes in tree of pid %d\n\n' "${#all[@]}" "$pid"
    ps -o pid,ppid,rss,%cpu,%mem,command -p "$csv" 2>&1
    printf '\ntotal RSS: '
    ps -o rss= -p "$csv" 2>/dev/null | awk '{s+=$1} END {printf "%.1f MB\n", s/1024}'
}

# ── Open file descriptors per process ────────────────────────────────────
tool_perf_open_files() {
    command -v lsof &>/dev/null || { _perf_missing "lsof" "apt-get install lsof"; return 1; }
    printf 'open-fds  pid  command (top 15)\n'
    lsof -n 2>/dev/null | awk 'NR>1 {c[$2"  "$1]++} END {for (k in c) print c[k], k}' | sort -rn | head -15
}

# ── Register ─────────────────────────────────────────────────────────────
tool_register "perf_cpu_usage"         tool_perf_cpu_usage         '{"type":"object","properties":{}}' safe all perf
tool_register "perf_memory"         tool_perf_memory         '{"type":"object","properties":{}}' safe all perf
tool_register "perf_io_stats"          tool_perf_io_stats          '{"type":"object","properties":{}}' safe all perf
tool_register "perf_network"         tool_perf_network         '{"type":"object","properties":{}}' safe all perf
tool_register "perf_disk_io"        tool_perf_disk_io        '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all perf
tool_register "perf_top_processes"   tool_perf_top_processes   '{"type":"object","properties":{}}' safe all perf
tool_register "perf_strace"      tool_perf_strace      '{"type":"object","properties":{"pid":{"type":"integer","description":"the process id"}},"required":["pid"]}' dangerous all perf
tool_register "perf_dtrace"      tool_perf_dtrace      '{"type":"object","properties":{"pid":{"type":"integer","description":"the process id"}},"required":["pid"]}' dangerous all perf
tool_register "perf_record" tool_perf_record '{"type":"object","properties":{"pid":{"type":"integer","description":"the process id"},"name":{"type":"string","description":"the resource name"}}}' dangerous all perf
tool_register "perf_pidstat"     tool_perf_pidstat     '{"type":"object","properties":{"pid":{"type":"integer","description":"the process id"},"name":{"type":"string","description":"the resource name"}}}' safe all perf
tool_register "perf_load_average"        tool_perf_load_average        '{"type":"object","properties":{}}' safe all perf
tool_register "perf_doctor"      tool_perf_doctor      '{"type":"object","properties":{}}' safe all perf
tool_register "perf_benchmark"       tool_perf_benchmark       '{"type":"object","properties":{"command":{"type":"string","description":"the shell command to run"}},"required":["command"]}' dangerous all perf
tool_register "perf_binary_size"    tool_perf_binary_size    '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all perf
tool_register "perf_process_tree"   tool_perf_process_tree   '{"type":"object","properties":{"pid":{"type":"integer","description":"the process id"}},"required":["pid"]}' safe all perf
tool_register "perf_open_files"  tool_perf_open_files  '{"type":"object","properties":{}}' safe all perf