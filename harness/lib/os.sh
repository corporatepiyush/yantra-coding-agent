# lib/os.sh — OS detection and platform-specific utilities (macOS/Linux/FreeBSD)

# os_detect -> prints: darwin | linux | freebsd | unknown
os_detect() {
    case "$(uname -s)" in
        Darwin)    printf 'darwin' ;;
        Linux)     printf 'linux' ;;
        FreeBSD)   printf 'freebsd' ;;
        *)         printf 'unknown' ;;
    esac
}

# os_name -> friendly name
os_name() {
    case "$(os_detect)" in
        darwin)  printf 'macOS' ;;
        linux)   printf 'Linux' ;;
        freebsd) printf 'FreeBSD' ;;
        *)       printf "$(uname -s)" ;;
    esac
}

# os_hosts_file -> path to hosts file
os_hosts_file() {
    case "$(os_detect)" in
        darwin)  printf '/private/etc/hosts' ;;
        *)       printf '/etc/hosts' ;;
    esac
}

# os_brew_ensure -> 0 if brew is available (installs it if missing, macOS + Linux)
# Homebrew is the unified package manager across macOS and Linux (Linuxbrew).
# Non-interactive install. Idempotent. Sets HOMEBREW_NO_AUTO_UPDATE=1 to stay fast.
os_brew_ensure() {
    command -v brew &>/dev/null && return 0
    local os; os=$(os_detect)
    case "$os" in
        darwin|linux)
            local install_url="https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh"
            logmsg "$(c_info "Homebrew not found — installing (this runs once)…")"
            # Non-interactive: set NONINTERACTIVE=1 so the installer doesn't prompt
            if command -v curl &>/dev/null; then
                NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL $install_url)" 2>&1 | tail -5
            elif command -v wget &>/dev/null; then
                NONINTERACTIVE=1 /bin/bash -c "$(wget -qO- $install_url)" 2>&1 | tail -5
            else
                logmsg "$(c_fail "Need curl or wget to install Homebrew.")"
                return 1
            fi
            # Make brew available on PATH for this shell + future shells
            local brew_prefix
            case "$os" in
                darwin) brew_prefix="/opt/homebrew" ;;   # Apple Silicon; /usr/local on Intel
                linux)  brew_prefix="/home/linuxbrew/.linuxbrew" ;;
            esac
            [[ -x "/usr/local/bin/brew" ]] && brew_prefix="/usr/local"
            eval "$("$brew_prefix/bin/brew" shellenv 2>/dev/null)" 2>/dev/null || true
            command -v brew &>/dev/null && {
                logmsg "$(c_ok "Homebrew installed at $brew_prefix")"
                return 0
            }
            logmsg "$(c_fail "Homebrew install failed. Install manually: https://brew.sh")"
            return 1
            ;;
        *)
            logmsg "$(c_warn "Homebrew not supported on $os")"
            return 1
            ;;
    esac
}

# os_brew_prefix -> prints brew prefix path (e.g. /opt/homebrew, /home/linuxbrew/.linuxbrew)
os_brew_prefix() {
    brew --prefix 2>/dev/null || {
        local os; os=$(os_detect)
        case "$os" in
            darwin) [[ -x /opt/homebrew/bin/brew ]] && printf '/opt/homebrew' || printf '/usr/local' ;;
            linux)  printf '/home/linuxbrew/.linuxbrew' ;;
        esac
    }
}

# os_install_cmd -> package manager install command prefix.
# Prefers Homebrew on BOTH macOS and Linux (installs it if missing via os_brew_ensure).
# Falls back to the native distro package manager only if brew is unavailable.
os_install_cmd() {
    case "$(os_detect)" in
        darwin)
            os_brew_ensure 2>/dev/null && printf 'brew install' || printf 'port install' ;;
        linux)
            if command -v brew &>/dev/null; then printf 'brew install'
            elif os_brew_ensure 2>/dev/null; then printf 'brew install'
            elif command -v apt-get &>/dev/null; then printf 'apt-get install -y'
            elif command -v yum &>/dev/null; then printf 'yum install -y'
            elif command -v dnf &>/dev/null; then printf 'dnf install -y'
            elif command -v pacman &>/dev/null; then printf 'pacman -S --noconfirm'
            elif command -v apk &>/dev/null; then printf 'apk add'
            elif command -v zypper &>/dev/null; then printf 'zypper install -y'
            else printf 'echo no-package-manager-found'
            fi ;;
        freebsd)
            command -v pkg &>/dev/null && printf 'pkg install -y' || printf 'make install' ;;
        *) printf 'echo unknown-os' ;;
    esac
}

# os_pkg_install NAME... -> install system packages via brew (preferred) or native pm.
os_pkg_install() {
    local cmd
    cmd=$(os_install_cmd)
    logmsg "$(c_info "Installing via: $cmd $*")"
    case "$cmd" in
        brew\ *)
            # brew doesn't need sudo; run as current user
            HOMEBREW_NO_AUTO_UPDATE=1 $cmd "$@" 2>&1 || {
                logmsg "$(c_fail "brew install failed. Try manually: $cmd $*")"
                return 1
            } ;;
        *)
            sudo $cmd "$@" 2>/dev/null || $cmd "$@" 2>/dev/null || {
                logmsg "$(c_fail "Package install failed. Try manually: $cmd $*")"
                return 1
            } ;;
    esac
}

# os_service_ctl ACTION SERVICE (start/stop/restart/status/enable/disable)
os_service_ctl() {
    local action="$1" service="$2"
    case "$(os_detect)" in
        linux)
            if command -v systemctl &>/dev/null; then
                sudo systemctl "$action" "$service" 2>/dev/null
            elif command -v service &>/dev/null; then
                sudo service "$service" "$action" 2>/dev/null
            fi ;;
        darwin)
            sudo launchctl "$action" "$service" 2>/dev/null || \
                brew services "$action" "$service" 2>/dev/null ;;
        freebsd)
            sudo service "$service" "$action" 2>/dev/null ;;
    esac
}

# os_open_ports -> list listening TCP ports
os_open_ports() {
    case "$(os_detect)" in
        darwin|freebsd)
            netstat -an -p tcp 2>/dev/null | grep LISTEN || lsof -iTCP -sTCP:LISTEN -P -n 2>/dev/null ;;
        linux)
            ss -tlnp 2>/dev/null || netstat -tlnp 2>/dev/null ;;
    esac
}

# os_disk_free [PATH] -> free space in KB
os_disk_free() {
    local path="${1:-/}"
    df -k "$path" 2>/dev/null | awk 'NR==2 {print $4}'
}

# os_cpu_count -> number of CPU cores
os_cpu_count() {
    case "$(os_detect)" in
        darwin|freebsd) sysctl -n hw.ncpu 2>/dev/null || printf '2' ;;
        linux) grep -c '^processor' /proc/cpuinfo 2>/dev/null || nproc 2>/dev/null || printf '2' ;;
    esac
}

# os_mem_info -> "total_mb free_mb"
os_mem_info() {
    case "$(os_detect)" in
        darwin)
            local total free
            total=$(sysctl -n hw.memsize 2>/dev/null | awk '{print int($1/1048576)}')
            free=$(vm_stat 2>/dev/null | awk '/free/ {gsub(/\./,"",$3); print int($3*4096/1048576)}')
            printf '%s %s' "${total:-0}" "${free:-0}" ;;
        linux)
            awk '/MemTotal/ {t=int($2/1024)} /MemAvailable/ {f=int($2/1024)} END {print t, f}' /proc/meminfo 2>/dev/null ;;
        freebsd)
            local total free
            total=$(sysctl -n hw.physmem 2>/dev/null | awk '{print int($1/1048576)}')
            free=$(vmstat 2>/dev/null | awk 'NR==2 {print int($5/1024)}')
            printf '%s %s' "${total:-0}" "${free:-0}" ;;
    esac
}

# os_temp_dir -> platform temp directory
os_temp_dir() {
    printf '%s' "${TMPDIR:-/tmp}"
}

# os_sudo_available -> 0 if sudo works without password
os_sudo_available() {
    sudo -n true 2>/dev/null
}

# os_firewall_cmd -> firewall command for this OS
os_firewall_cmd() {
    case "$(os_detect)" in
        linux)
            if command -v ufw &>/dev/null; then printf 'ufw'
            elif command -v firewall-cmd &>/dev/null; then printf 'firewall-cmd'
            elif command -v iptables &>/dev/null; then printf 'iptables'
            else printf ''
            fi ;;
        darwin)  printf 'pfctl' ;;
        freebsd) printf 'ipfw' ;;
    esac
}

# os_pid_exists PID -> 0 if process running
os_pid_exists() {
    kill -0 "$1" 2>/dev/null
}

# os_kill_pid PID [SIGNAL]
os_kill_pid() {
    local pid="$1" sig="${2:-TERM}"
    case "$(os_detect)" in
        darwin|freebsd) kill -"$sig" "$pid" 2>/dev/null ;;
        linux) kill -"$sig" "$pid" 2>/dev/null ;;
    esac
}

# os_read_file_safe PATH -> cat with fallback for binary
os_read_file_safe() {
    local f="$1"
    [[ -r "$f" ]] || return 1
    if file --brief --mime "$f" 2>/dev/null | grep -q 'text/'; then
        cat "$f"
    else
        printf '[binary file: %s (%s bytes)]\n' "$f" "$(path_size "$f")"
    fi
}

# os_hostname -> system hostname
os_hostname() { hostname 2>/dev/null || cat /etc/hostname 2>/dev/null || printf 'localhost'; }

# os_uptime -> system uptime in seconds
os_uptime() {
    case "$(os_detect)" in
        darwin|freebsd) sysctl -n kern.boottime 2>/dev/null | awk -F'[ ,]' '{print $4}' ;;
        linux) awk '{print int($1)}' /proc/uptime 2>/dev/null ;;
    esac
}

# os_display_server -> the windowing/display server in effect, for tools that
# capture or drive the screen (CUA / computer-use). Prints one of:
#   quartz   — macOS (CoreGraphics/Quartz); capture via screencapture, input via
#              cliclick / AppleScript System Events
#   wayland  — a Wayland session; input injection is deliberately restricted, so
#              this needs grim + wtype/ydotool. NOTE: xdotool does NOT work on
#              native Wayland (it only reaches XWayland-hosted X11 apps)
#   x11      — an X11 session; xdotool + scrot/maim/import all work
#   none     — headless: neither DISPLAY nor WAYLAND_DISPLAY is set
# The Wayland-vs-X11 split is the single most important OS fact for computer use:
# the same task needs completely different binaries on each, and running the
# wrong one silently no-ops. Wayland takes precedence when its socket is present
# because a Wayland session usually ALSO exports DISPLAY for XWayland — so a set
# DISPLAY does not prove the native server is X11.
os_display_server() {
    case "$(os_detect)" in
        darwin) printf 'quartz'; return 0 ;;
    esac
    if [[ -n "${WAYLAND_DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "wayland" ]]; then
        printf 'wayland'; return 0
    fi
    if [[ -n "${DISPLAY:-}" || "${XDG_SESSION_TYPE:-}" == "x11" ]]; then
        printf 'x11'; return 0
    fi
    printf 'none'
}

# os_wayland_compositor -> best-effort Wayland compositor family, which decides
# the screenshot + input backend:
#   wlroots  — sway / hyprland / river: grim (shot) + wtype (type/keys) work
#   gnome    — Mutter: gnome-screenshot (shot); input needs ydotool + ydotoold
#   kde      — KWin: spectacle (shot); input needs ydotool + ydotoold
#   unknown  — fall back to ydotool for input, grim/gnome-screenshot probed
# Detected from XDG_CURRENT_DESKTOP/DESKTOP_SESSION, then a live socket probe.
os_wayland_compositor() {
    local d; d=$(str_lower "${XDG_CURRENT_DESKTOP:-}:${DESKTOP_SESSION:-}")
    case "$d" in
        *sway*|*hyprland*|*river*|*wlroots*) printf 'wlroots'; return 0 ;;
        *gnome*)                             printf 'gnome';   return 0 ;;
        *kde*|*plasma*)                      printf 'kde';     return 0 ;;
    esac
    if [[ -n "${SWAYSOCK:-}" || -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ]] || command -v swaymsg &>/dev/null; then
        printf 'wlroots'
    else
        printf 'unknown'
    fi
}
