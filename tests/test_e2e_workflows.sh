#!/usr/bin/env bash
# Test: end-to-end run of non-LLM workflows through the real entry script.
#
# Drives the harness exactly as an MCP host would (JSON-RPC over stdin) across
# a batch of deterministic, non-LLM workflows (wf__ tools) and asserts:
#   1. stdout is PURE protocol — every non-empty line is valid JSON. (This is
#      what caught tool text like "tool missing: gitleaks" leaking into the
#      stream, and the errexit leak that killed the session mid-run.)
#   2. every workflow call is answered, by id.
#   3. the session survives all of them and exits 0.
#   4. a removed workflow (serve.*) is an unknown-tool error result, not a crash.
#   5. stderr carries no shell-level failures (command not found / unbound / syntax).
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"

# ── Fixture: a small but varied git project ─────────────────────────────────
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
printf '#!/usr/bin/env bash\necho hi  # TODO: tidy this up\n' > run.sh
printf '{"a":1,"b":[2,3]}\n' > config.json
mkdir -p src
printf 'def main():\n    return 1  # FIXME\n' > src/app.py
printf '# Readme\n' > README.md
git add -A
git commit -qm init >/dev/null 2>&1

# Workflows to exercise. All are non-LLM and safe (or auto-confirmed). The last
# one is intentionally removed and must degrade to a 404, proving the removal.
WFS=(
    project.overview project.onboard
    tools.status tools.list
    harness.doctor harness.cost harness.history harness.config
    git.branch git.clean
    lint.check fmt.all
    sec.secrets sec.iac sec.complexity sec.deadcode sec.shellcheck
    pipeline.preflight deps.tree
    serve.port-free            # removed → expect error 404
)

# Build one MCP session: initialize, call every workflow as wf__<id>, exit.
session() {
    printf '%s\n' '{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"e2e","version":"1"}}}'
    local i=0 w
    for w in "${WFS[@]}"; do
        i=$((i+1))
        printf '{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{"name":"wf__%s","arguments":{}}}\n' "$i" "${w//./_}"
    done
    printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}'
}

OUT="$TMP/stdout.ndjson"; ERR="$TMP/stderr.log"
session | HARNESS_UPDATE_ENABLED=false timeout 300 bash "$HARNESS" -y >"$OUT" 2>"$ERR"
rc=$?

# 3. clean exit
[[ "$rc" -eq 0 ]] || { echo "session exited $rc (expected 0)"; sed 's/^/  /' "$ERR" | tail -20; exit 1; }

# 1. every non-empty stdout line must be valid JSON (protocol purity)
lineno=0
while IFS= read -r line; do
    lineno=$((lineno+1))
    [[ -z "$line" ]] && continue
    printf '%s' "$line" | jq -e . >/dev/null 2>&1 || {
        echo "stdout line $lineno is not valid JSON (protocol pollution):"
        echo "  $line"
        exit 1
    }
done < "$OUT"

# 2. every call answered, by id (initialize is id 0).
answered=$(jq -rs '[.[] | select(has("method") | not) | .id] | length' "$OUT" 2>/dev/null || echo 0)
[[ "$answered" -eq $((${#WFS[@]} + 1)) ]] || { echo "expected $((${#WFS[@]} + 1)) responses, got $answered"; exit 1; }

# 4. removed serve.port-free must be an unknown-tool error result, not a crash
jq -es --argjson id "${#WFS[@]}" 'any(.[]; (has("method") | not) and .id == $id and .result.isError == true and (.result.content[0].text | contains("unknown tool")))' "$OUT" >/dev/null 2>&1 \
    || { echo "removed workflow serve.port-free did not report unknown tool"; exit 1; }

# A representative safe workflow must genuinely succeed (not just not-crash).
jq -es 'any(.[]; (has("method") | not) and .id == 1 and .result.isError == false and (.result.content[0].text | fromjson | .ok == true))' "$OUT" >/dev/null 2>&1 \
    || { echo "project.overview did not return ok:true"; exit 1; }

# 5. no shell-level errors leaked to stderr
if grep -qiE "command not found|unbound variable|syntax error|: line [0-9]+:" "$ERR"; then
    echo "shell-level error on stderr:"
    grep -iE "command not found|unbound variable|syntax error|: line [0-9]+:" "$ERR" | head -5
    exit 1
fi

echo "e2e_workflows OK (${#WFS[@]} workflows, $answered responses, stdout pure JSON)"
exit 0
