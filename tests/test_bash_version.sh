#!/usr/bin/env bash
# Test: Bash 5.3+ hard requirement at the entry point.
#
# The guard in yantra-mcp-server.sh must run BEFORE any harness/ module is
# sourced, using only Bash 3.2-safe syntax, so an old shell gets a clear error
# (exit 3) instead of a cryptic parse/"unbound variable" failure from the
# 5.3+ modules it can't even parse.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"

# The running suite is already on Bash 5.3+, so the entry guard must let the
# harness proceed (any exit code other than 3 means the guard didn't reject us).
bash "$HARNESS" --workflow harness.doctor </dev/null >/dev/null 2>&1
rc=$?
[[ "$rc" -ne 3 ]] || { echo "guard wrongly rejected current Bash (exit 3)"; exit 1; }

# Find an OLD bash to prove the rejection path. macOS ships 3.2 at /bin/bash.
old_bash=""
for cand in /bin/bash /usr/bin/bash; do
    [[ -x "$cand" ]] || continue
    v=$("$cand" -c 'echo "${BASH_VERSINFO[0]}.${BASH_VERSINFO[1]}"' 2>/dev/null)
    major="${v%%.*}"; minor="${v##*.}"
    if [[ -n "$major" ]] && { (( major < 5 )) || { (( major == 5 )) && (( minor < 3 )); }; }; then
        old_bash="$cand"; break
    fi
done

if [[ -z "$old_bash" ]]; then
    echo "SKIP: no Bash < 5.3 found to exercise the rejection path (guard-passes case verified)"
    echo "bash_version OK"
    exit 0
fi

# Old bash must be rejected with exit 3 and a helpful message, and must NOT leak
# the internal "unbound variable"/parse errors that mean it got past the guard.
out=$("$old_bash" "$HARNESS" --ui json </dev/null 2>&1)
rc=$?
[[ "$rc" -eq 3 ]] || { echo "old bash ($old_bash) not rejected with exit 3 (got $rc)"; echo "$out"; exit 1; }
echo "$out" | grep -q "requires Bash 5.3+" || { echo "missing friendly error message"; echo "$out"; exit 1; }
if echo "$out" | grep -qi "unbound variable\|syntax error\|unexpected"; then
    echo "old bash leaked past the guard into harness sourcing:"; echo "$out"; exit 1
fi

echo "bash_version OK (rejected $("$old_bash" --version | head -1 | grep -oE 'version [0-9.]+'))"
exit 0
