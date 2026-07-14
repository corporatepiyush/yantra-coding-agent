#!/usr/bin/env bash
# tests/test_scripts/lib_common.sh — assert helpers for the extracted test bodies.
# NOTE: harness modules must be sourced at the body script's TOP LEVEL (not from a
# function), because their `declare -A` would otherwise be function-local.

# assert_eq EXPECTED ACTUAL MESSAGE
assert_eq() {
    if [[ "$1" != "$2" ]]; then
        printf 'ASSERT FAIL: %s\n  expected: [%s]\n  actual:   [%s]\n' "$3" "$1" "$2" >&2
        exit 1
    fi
}

# assert_contains HAYSTACK NEEDLE MESSAGE
assert_contains() {
    case "$1" in
        *"$2"*) : ;;
        *) printf 'ASSERT FAIL: %s\n  [%s] does not contain [%s]\n' "$3" "$1" "$2" >&2; exit 1 ;;
    esac
}
