#!/usr/bin/env bash
# Test: every tool category the scanner recommends actually registers >=1 tool.
# Regression guard for the bug where scanner recommended ci/doc/data/media/ai/helm
# but enabling them exposed nothing to the LLM (no tools were registered).
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo "a" > a.txt
git add a.txt
git commit -qm init >/dev/null 2>&1

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
export HARNESS_UPDATE_ENABLED=false
# Ask the harness for the tool list in each category and count entries.
count_cat() {
    local cat="$1" out
    out=$(mcp_wf "$HARNESS" tools.list "{\"category\":\"$cat\"}" y) || { echo 0; return; }
    printf '%s' "$out" | jq -r '.data.tools | length' 2>/dev/null || echo 0
}

# Categories the scanner can recommend — each MUST back its recommendation with tools.
RECOMMENDED="docker kubernetes helm pg mysql redis fs perf net sec quality ci doc data media ollama monitor s3 ssh brew"
fail=0
for cat in $RECOMMENDED; do
    n=$(count_cat "$cat")
    if [[ -z "$n" || "$n" -lt 1 ]]; then
        echo "category '$cat' is recommended by the scanner but registers 0 tools"
        fail=1
    fi
done
[[ "$fail" == 0 ]] || exit 1

# The 6 categories added in this pass must each have a meaningful number of tools.
for cat in data doc ci helm media ollama; do
    n=$(count_cat "$cat")
    [[ "$n" -ge 5 ]] || { echo "new category '$cat' has only $n tools (expected >=5)"; exit 1; }
done

echo "tool_categories OK"
exit 0
