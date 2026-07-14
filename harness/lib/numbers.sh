# lib/05-numbers.sh — Numeric/math utilities

# math_add a b -> prints sum (integers)
math_add() { printf '%d' "$(( $1 + $2 ))"; }
math_sub() { printf '%d' "$(( $1 - $2 ))"; }
math_mul() { printf '%d' "$(( $1 * $2 ))"; }
math_div() { printf '%d' "$(( $1 / $2 ))"; }
math_mod() { printf '%d' "$(( $1 % $2 ))"; }

# math_max a b
math_max() { (( $1 >= $2 )) && printf '%d' "$1" || printf '%d' "$2"; }

# math_min a b
math_min() { (( $1 <= $2 )) && printf '%d' "$1" || printf '%d' "$2"; }

# math_abs n
math_abs() { local n="$1"; (( n < 0 )) && n=$((-n)); printf '%d' "$n"; }

# math_clamp n min max
math_clamp() {
    local n="$1" lo="$2" hi="$3"
    (( n < lo )) && n="$lo"
    (( n > hi )) && n="$hi"
    printf '%d' "$n"
}

# math_between n min max -> 0 if in range
math_between() {
    local n="$1" lo="$2" hi="$3"
    (( n >= lo && n <= hi ))
}

# math_is_int STRING -> 0 if valid integer
math_is_int() {
    [[ "$1" =~ ^-?[0-9]+$ ]]
}

# math_is_number STRING -> 0 if integer or float
math_is_number() {
    [[ "$1" =~ ^-?[0-9]+\.?[0-9]*$ ]]
}

# math_random MIN MAX -> random integer in [min, max].
# SRANDOM (Bash 5.1+) is a high-quality 32-bit RNG; RANDOM is a weak, predictable
# 15-bit sequence.
math_random() {
    local lo="$1" hi="$2"
    local range=$(( hi - lo + 1 ))
    printf '%d' "$(( SRANDOM % range + lo ))"
}

# math_core_count -> number of CPU cores (for parallel ops)
math_core_count() {
    if command -v nproc &>/dev/null; then nproc
    elif command -v sysctl &>/dev/null; then sysctl -n hw.ncpu 2>/dev/null || printf '2'
    elif [[ -f /proc/cpuinfo ]]; then grep -c '^processor' /proc/cpuinfo
    else printf '2'
    fi
}

# math_pct part total -> percentage (integer)
math_pct() {
    local part="$1" total="$2"
    (( total == 0 )) && { printf '0'; return; }
    printf '%d' "$(( part * 100 / total ))"
}

# math_sleep SECONDS [FRACTION] — sleep, optionally fractional (e.g. 0 500 → 0.5s).
# Uses the external `sleep` (which accepts fractional seconds on modern systems).
# The old read-timeout trick was removed: it read from stdin, so under the NDJSON
# stdio loop it would swallow a protocol line.
math_sleep() {
    if (( $# == 2 )); then sleep "$1.$2"; else sleep "$1"; fi
}
