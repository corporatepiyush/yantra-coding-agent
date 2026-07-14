#!/usr/bin/env bash
# tests/test_scripts/sanitize_body.sh — unit body for the input sanitizers +
# fuzz. Args: $1=YCA_DIR
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export YCA_DIR="$1"
source "$YCA_DIR/harness/lib/sanitize.sh"
source "$HERE/lib_common.sh"

ok()  { "$@" >/dev/null 2>&1 || { echo "should ACCEPT: $*" >&2; exit 1; }; }
no()  { "$@" >/dev/null 2>&1 && { echo "should REJECT: $*" >&2; exit 1; } || true; }

# sanitize_url
ok sanitize_url "https://api.openai.com/v1"
ok sanitize_url "http://localhost:11434/v1"
no sanitize_url "-X http://evil"
no sanitize_url 'http://x/$(rm -rf /)'
no sanitize_url "ftp://x"
no sanitize_url "https://a b"
no sanitize_url 'http://x`whoami`'
no sanitize_url ""

# sql_safe_fragment
ok sql_safe_fragment "agent='x' AND level='error'"
ok sql_safe_fragment "kind LIKE 'tool%'"
no sql_safe_fragment "1=1; DROP TABLE events"
no sql_safe_fragment "1=1 -- x"
no sql_safe_fragment "a /* b */ c"
no sql_safe_fragment "x UNION SELECT * FROM config"
no sql_safe_fragment "1=1 ATTACH DATABASE 'x'"

# int_guard
assert_eq "50" "$(int_guard 50 10)" "int_guard passes integer"
assert_eq "10" "$(int_guard 'x;DROP' 10)" "int_guard rejects non-int → default"
assert_eq "0"  "$(int_guard '' )" "int_guard empty → 0"

# sanitize_line strips ANSI + control bytes
got=$(sanitize_line "$(printf 'a\x1b[31mR\x1b[0m\x07b\x00c')")
assert_eq "aRbc" "$got" "sanitize_line strips ANSI/control"

# shell_arg_safe
ok shell_arg_safe "web01.example.com"
no shell_arg_safe 'host;rm -rf'
no shell_arg_safe "a b"
no shell_arg_safe "-flag"

# ── Fuzz: random hostile strings must never crash and never echo something the
#    validators claim to reject.
chars=('a' 'b' '1' '/' ':' ';' '`' '$' '(' ')' ' ' '|' '&' '"' "'" '\' '-' '.' '=' '%')
rnd() { local n=$((RANDOM%20+1)) s="" i; for ((i=0;i<n;i++)); do s+="${chars[$((RANDOM%${#chars[@]}))]}"; done; printf '%s' "$s"; }
for i in $(seq 1 300); do
    s=$(rnd)
    if u=$(sanitize_url "$s" 2>/dev/null); then
        case "$u" in http://*|https://*) : ;; *) echo "FUZZ: sanitize_url emitted non-url [$u] from [$s]" >&2; exit 1 ;; esac
        case "$u" in *' '*|*';'*|*'`'*|*'$'*) echo "FUZZ: sanitize_url passed a metachar [$u]" >&2; exit 1 ;; esac
    fi
    if f=$(sql_safe_fragment "$s" 2>/dev/null); then
        case "$f" in *';'*|*'--'*|*'/*'*) echo "FUZZ: sql_safe_fragment passed unsafe [$f]" >&2; exit 1 ;; esac
    fi
    n=$(int_guard "$s" 7); [[ "$n" =~ ^[0-9]+$ ]] || { echo "FUZZ: int_guard produced non-int [$n]" >&2; exit 1; }
done

echo "sanitize_body OK"
