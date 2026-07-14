#!/usr/bin/env bash
# Test runner for Yantra Coding Agent v1.0
#
# Usage: bash tests/run_all.sh [harness_path] [-j N] [-k PATTERN]...
#   harness_path   path to yantra-mcp-server.sh (default: ../ from this dir)
#   -j N           run N test suites in parallel (default: CPU count; -j1 = serial)
#   -k PATTERN     only run suites whose name contains PATTERN (repeatable)
#
# Suites are isolated (each gets its own mktemp workdir; no shared /tmp paths,
# no global git config, no fixed ports), so they parallelize safely. The full
# suite spends most of its wall time booting the harness once per test, so
# running them concurrently is a near-linear speedup.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Argument parsing ─────────────────────────────────────────────────────────
HARNESS=""
JOBS=""
FILTERS=()
while (( $# )); do
    case "$1" in
        -j) JOBS="${2:-}"; shift 2 ;;
        -j*) JOBS="${1#-j}"; shift ;;
        -k) FILTERS+=("${2:-}"); shift 2 ;;
        -k*) FILTERS+=("${1#-k}"); shift ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) HARNESS="$1"; shift ;;
    esac
done

# Resolve HARNESS to an ABSOLUTE path. Each test does `cd "$TMP"` before
# launching the harness, so a relative path would no longer resolve.
HARNESS="${HARNESS:-$TESTS_DIR/../yantra-mcp-server.sh}"
HARNESS="$(cd "$(dirname "$HARNESS")" && pwd)/$(basename "$HARNESS")"

# Default parallelism = CPU count (portable across Linux/macOS/BSD), floored at 1.
if [[ -z "$JOBS" ]]; then
    JOBS="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)"
fi
[[ "$JOBS" =~ ^[0-9]+$ && "$JOBS" -ge 1 ]] || JOBS=1

# ── Syntax gate (fast, serial) ───────────────────────────────────────────────
if ! bash -n "$HARNESS"; then
    echo "FATAL: yantra-mcp-server.sh syntax error"
    exit 1
fi
for f in "$(dirname "$HARNESS")/harness/"**/*.sh "$(dirname "$HARNESS")/harness/"*.sh; do
    [[ -f "$f" ]] || continue
    if ! bash -n "$f" 2>/dev/null; then
        echo "FATAL: syntax error in $f"
        bash -n "$f"
        exit 1
    fi
done

# ── Collect suites (honouring -k filters) ────────────────────────────────────
SUITES=()
for t in "$TESTS_DIR"/test_*.sh; do
    [[ -f "$t" ]] || continue
    name=$(basename "$t" .sh)
    if (( ${#FILTERS[@]} )); then
        keep=0
        for pat in "${FILTERS[@]}"; do [[ "$name" == *"$pat"* ]] && keep=1 && break; done
        (( keep )) || continue
    fi
    SUITES+=("$t")
done

RESULTS=$(mktemp -d)
trap 'rm -rf "$RESULTS"' EXIT

# run_one SCRIPT -> runs a suite in its own workdir, records status + log.
# Prints one atomic result line (< PIPE_BUF, so parallel lines never interleave).
run_one() {
    local script="$1" name; name=$(basename "$script" .sh)
    local tmp; tmp=$(mktemp -d)
    if bash "$script" "$HARNESS" "$tmp" >"$tmp/out.log" 2>&1; then
        printf '  %-30s PASS\n' "$name"
        : > "$RESULTS/$name.pass"
    else
        printf '  %-30s FAIL\n' "$name"
        cp "$tmp/out.log" "$RESULTS/$name.fail"
    fi
    rm -rf "$tmp"
}

echo "── Yantra Coding Agent v1.0 — test suite ──"
echo "Entry: $HARNESS"
echo "Suites: ${#SUITES[@]}   Parallelism: -j$JOBS"
echo

# ── Run (bounded concurrency via `wait -n`) ──────────────────────────────────
running=0
for t in "${SUITES[@]}"; do
    run_one "$t" &
    if (( ++running >= JOBS )); then wait -n 2>/dev/null; ((running--)); fi
done
wait

# Any /tmp scratch a suite may have left behind (belt-and-suspenders).
rm -f /tmp/remote.git /tmp/yca-test-remote.git 2>/dev/null

# ── Tally ────────────────────────────────────────────────────────────────────
PASS=$(find "$RESULTS" -name '*.pass' | wc -l | tr -d ' ')
FAILED=()
while IFS= read -r f; do FAILED+=("$(basename "$f" .fail)"); done \
    < <(find "$RESULTS" -name '*.fail' | sort)

echo
echo "── Results: $PASS passed, ${#FAILED[@]} failed ──"
if (( ${#FAILED[@]} )); then
    echo "Failed: ${FAILED[*]}"
    for name in "${FAILED[@]}"; do
        echo "──────── $name ────────"
        sed 's/^/    /' "$RESULTS/$name.fail" | tail -20
    done
    exit 1
fi
exit 0
