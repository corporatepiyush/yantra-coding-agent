#!/usr/bin/env bash
# tests/test_scripts/danger_gate_body.sh — the machine-mode consent gate must deny
# EVERY consequential danger token (writes|destructive|dangerous), not just
# "writes". Before the fix the more-severe destructive/dangerous tokens fell
# straight through the gate fail-open (s3_delete, perf_benchmark, docker_prune, …) —
# the most dangerous tools had the weakest guard. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json
# Enable the category our fixtures register into — sourcing main.sh doesn't run
# main()/cat_init_defaults, so the gate's category check would otherwise fire first.
YCA_CAT_ENABLED[core]=1

# 1) danger_needs_confirm predicate: the three consequential tokens need consent;
#    safe / unknown / empty do not.
for tok in writes destructive dangerous; do
    danger_needs_confirm "$tok" || { echo "FAIL: '$tok' should need confirmation"; exit 1; }
done
for tok in safe read "" bogus; do
    if danger_needs_confirm "$tok"; then echo "FAIL: '$tok' should NOT need confirmation"; exit 1; fi
done

# 2) A destructive AND a dangerous tool must be auto-denied in machine mode without
#    consent, and must NOT run their side effect (fail-CLOSED, not fail-open).
MARKER="$2/gate_marker"
_gate_fake() { touch "$MARKER"; printf 'ran'; }
tool_register "gate_fake_destructive" _gate_fake '{"type":"object","properties":{}}' destructive all core
tool_register "gate_fake_dangerous"   _gate_fake '{"type":"object","properties":{}}' dangerous   all core

for t in gate_fake_destructive gate_fake_dangerous; do
    rm -f "$MARKER"; YCA_AUTO_CONFIRM=false
    out=$(tool_dispatch "$t" '{}') || true
    if [[ -f "$MARKER" ]]; then echo "FAIL: $t ran WITHOUT consent (fail-open)"; exit 1; fi
    echo "$out" | grep -qi 'cancel\|confirm' || { echo "FAIL: $t gave no denial message (got: $out)"; exit 1; }
done

# 3) With explicit consent the same tool runs.
rm -f "$MARKER"; YCA_AUTO_CONFIRM=true
out=$(tool_dispatch gate_fake_destructive '{}') || true
[[ -f "$MARKER" ]] || { echo "FAIL: destructive tool blocked even with auto_confirm"; exit 1; }
YCA_AUTO_CONFIRM=false

# 3b) Consent parity on the MCP surface: the gate keys on machine mode, and mcp
#     is a machine mode too. A non-core writes tool that does NOT confirm
#     internally must be auto-denied over MCP (deny-with-explanation, D5) — else
#     it runs unconfirmed. Regression guard for the gate covering YCA_UI_MODE=mcp.
YCA_UI_MODE=mcp
rm -f "$MARKER"; YCA_AUTO_CONFIRM=false
out=$(tool_dispatch gate_fake_destructive '{}') || true
[[ ! -f "$MARKER" ]] || { echo "FAIL: destructive tool ran WITHOUT consent over MCP (fail-open)"; exit 1; }
echo "$out" | grep -qi 'cancel\|confirm' || { echo "FAIL: MCP gate gave no denial message (got: $out)"; exit 1; }
# with consent it runs, same as json mode
rm -f "$MARKER"; YCA_AUTO_CONFIRM=true
out=$(tool_dispatch gate_fake_destructive '{}') || true
[[ -f "$MARKER" ]] || { echo "FAIL: destructive tool blocked over MCP even with auto_confirm"; exit 1; }
YCA_AUTO_CONFIRM=false; YCA_UI_MODE=json

# 4) Real known-dangerous tools must keep a gated token — guards against a future
#    edit re-tagging one back to `safe`. Registry entry = fn|danger|agents|cat|cx.
for t in s3_delete perf_benchmark perf_strace docker_prune docker_remove brew_uninstall; do
    info="${YCA_TOOL_REGISTRY[$t]:-}"
    [[ -n "$info" ]] || { echo "FAIL: $t not registered"; exit 1; }
    IFS='|' read -r _fn dg _rest <<< "$info"
    danger_needs_confirm "$dg" || { echo "FAIL: $t is tagged '$dg' — bypasses the consent gate"; exit 1; }
done

echo "danger_gate_body OK"
