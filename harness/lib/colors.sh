# lib/13-colors.sh — ANSI colors and symbol legend
# Colors are cosmetic; symbols carry meaning (plain mode loses nothing).

# Color codes
readonly C_RESET=$'\033[0m'
readonly C_BOLD=$'\033[1m'
readonly C_DIM=$'\033[2m'
readonly C_RED=$'\033[31m'
readonly C_GREEN=$'\033[32m'
readonly C_YELLOW=$'\033[33m'
readonly C_BLUE=$'\033[34m'
readonly C_MAGENTA=$'\033[35m'
readonly C_CYAN=$'\033[36m'
readonly C_GRAY=$'\033[90m'
readonly C_WHITE=$'\033[97m'
# Background
readonly BG_RED=$'\033[41m'
readonly BG_GREEN=$'\033[42m'
readonly BG_BLUE=$'\033[44m'
readonly BG_YELLOW=$'\033[43m'

# Symbols (color-independent)
readonly SYM_OK='✓'
readonly SYM_FAIL='✗'
readonly SYM_WARN='⚠'
readonly SYM_INFO='ℹ'
readonly SYM_RESULT='▸'
readonly SYM_PROGRESS='…'
readonly SYM_ARROW='→'
readonly SYM_BULLET='•'
readonly SYM_DIAMOND='◆'
readonly SYM_BOX='█'

# Should we use color?
_use_color() {
    [[ "$YCA_UI_MODE" == "human" ]] && [[ -t 2 ]] && [[ "${TERM:-dumb}" != "dumb" ]]
}

# color_wrap COLOR TEXT -> prints text wrapped in color (or plain if no color)
color_wrap() {
    local color="$1" text="$2"
    if _use_color; then
        printf '%s%s%s' "$color" "$text" "$C_RESET"
    else
        printf '%s' "$text"
    fi
}

# Convenience: c_ok, c_fail, c_warn, c_info, c_dim, c_bold
c_ok()   { color_wrap "$C_GREEN"  "$1"; }
c_fail() { color_wrap "$C_RED"    "$1"; }
c_warn() { color_wrap "$C_YELLOW" "$1"; }
c_info() { color_wrap "$C_CYAN"   "$1"; }
c_dim()  { color_wrap "$C_GRAY"   "$1"; }
c_bold() { color_wrap "$C_BOLD"   "$1"; }

# color_symbol KIND -> colored symbol for status
# KIND: ok, fail, warn, info, result, progress
color_symbol() {
    case "$1" in
        ok)      c_ok "$SYM_OK" ;;
        fail)    c_fail "$SYM_FAIL" ;;
        warn)    c_warn "$SYM_WARN" ;;
        info)    c_info "$SYM_INFO" ;;
        result)  color_wrap "$C_CYAN" "$SYM_RESULT" ;;
        progress) c_dim "$SYM_PROGRESS" ;;
        *) printf '%s' "$1" ;;
    esac
}

# banner SUBTITLE -> prints the branded YANTRA wordmark + subtitle to stderr.
# Color-aware; degrades cleanly under NO_COLOR / non-tty (plain mode).
banner() {
    local subtitle="${1:-Coding Agent}"
    local c1="" c2="" c3="" r=""
    if _use_color; then c1="$C_CYAN" c2="$C_BOLD" c3="$C_DIM" r="$C_RESET"; fi
    {
        printf '%s __   __     _    _   _ _____ ____      _   %s\n' "$c1" "$r"
        printf '%s \\ \\ / /    / \\  | \\ | |_   _|  _ \\    / \\  %s\n' "$c1" "$r"
        printf '%s  \\ V /    / _ \\ |  \\| | | | | |_) |  / _ \\ %s\n' "$c1" "$r"
        printf '%s   | |    / ___ \\| |\\  | | | |  _ <  / ___ \\%s\n' "$c1" "$r"
        printf '%s   |_|   /_/   \\_\\_| \\_| |_| |_| \\_\\/_/   \\_\\%s\n' "$c1" "$r"
        printf '%s   %s%s%s  %s·  deterministic-first · 11 languages · dual-mode%s\n' \
            "$c2" "$subtitle" "$r" "" "$c3" "$r"
    } >&2
}

# separator -> prints a horizontal line
separator() {
    local char="${1:─}" count="${2:-60}"
    str_repeat "$count" "$char" >&2
    printf '\n' >&2
}
