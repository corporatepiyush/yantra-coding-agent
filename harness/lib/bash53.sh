# lib/bash53.sh — Bash 5.3 baseline guard.
#
# The entry point (yantra-mcp-server.sh) already hard-rejects Bash < 5.3 using
# 3.2-safe syntax, BEFORE any of these modules are sourced. So every module below
# may use 5.3 features unconditionally — associative arrays, namerefs, mapfile,
# ${v,,}/${v^^}, EPOCHSECONDS/EPOCHREALTIME, `wait -n`, printf '%()T', SRANDOM,
# and the ${ …; } no-fork command substitution — with no feature-detection or
# Bash-3.2 fallback branches. This file just re-affirms the requirement for code
# paths that source the harness directly (e.g. unit tests) without the entry gate.

# _yca_bash_init — no-op kept for call-site compatibility (main.sh, test bodies).
# Feature detection was removed: 5.3 is a hard requirement, so nothing to detect.
_yca_bash_init() { :; }

# _yca_require_bash — abort if we are somehow running under < 5.3.
_yca_require_bash() {
    local major="${BASH_VERSINFO[0]:-0}" minor="${BASH_VERSINFO[1]:-0}"
    if (( major < 5 )) || (( major == 5 && minor < 3 )); then
        printf 'ERROR: Bash 5.3+ required (you have %s.%s)\n' "$major" "$minor" >&2
        printf 'Install Bash 5.3: brew install bash (macOS) or build from source (Linux)\n' >&2
        exit 3
    fi
}
