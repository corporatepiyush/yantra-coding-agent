#!/usr/bin/env bash
# tests/test_scripts/dep_add_body.sh — per-language dep_add (add-a-dependency).
# Verifies: package-name validation runs BEFORE the tool-present check (so a
# hostile name is rejected offline, without cargo/npm/etc. installed); every
# language registers a dep_add tool; the real-fetch adds are gated `writes`;
# machine mode without consent denies a dep_add via tool_dispatch; and the
# toolchain-aware deps.add workflow exists. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1" YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json
for c in nodejs python rust golang ruby php; do YCA_CAT_ENABLED[$c]=1; done
fail(){ echo "FAIL: $1"; exit 1; }

# (1) A package name with a leading '-' (CLI option injection) or shell
# metacharacters is rejected as "invalid" — and this happens BEFORE the
# command-present check, so it works offline (the package managers are absent in
# CI). Call the tool fn directly (bypassing dispatch) with the name in the raw
# args JSON, exactly as _tool_exec would set it.
for bad in '-rf' 'evil;rm -rf /' 'a$(whoami)' '--registry=http://evil'; do
    argj=$(jq -n --arg p "$bad" '{package:$p}')
    out=$(YCA_TOOL_ARGS_JSON="$argj" tool_rust_dep_add 2>&1) || true
    grep -qi 'invalid' <<<"$out" || fail "rust_dep_add accepted invalid name [$bad] (got: $out)"
    out=$(YCA_TOOL_ARGS_JSON="$argj" tool_nodejs_dep_add 2>&1) || true
    grep -qi 'invalid' <<<"$out" || fail "nodejs_dep_add accepted invalid name [$bad] (got: $out)"
    out=$(YCA_TOOL_ARGS_JSON="$argj" tool_go_dep_add 2>&1) || true
    grep -qi 'invalid' <<<"$out" || fail "go_dep_add accepted invalid name [$bad] (got: $out)"
done

# (2) A well-formed name is NOT rejected as invalid (the validator isn't
# over-rejecting). tool_invoke bypasses the dispatch gate, but the tool's own
# confirm_action still denies in machine mode (auto_confirm off), so no real
# install runs — output is a missing-tool hint or a cancellation, never "invalid".
YCA_AUTO_CONFIRM=false
out=$(tool_invoke rust_dep_add "$(jq -n '{package:"leftpad"}')" 2>&1) || true
if grep -qi 'invalid' <<<"$out"; then fail "rust_dep_add wrongly rejected a valid name (got: $out)"; fi

# (3) Every language registers a dep_add tool (registry entry = fn|danger|agents|cat|cx).
ALL="rust_dep_add nodejs_dep_add python_dep_add go_dep_add ccpp_dep_add java_dep_add kotlin_dep_add scala_dep_add ruby_dep_add php_dep_add"
for t in $ALL; do
    [[ -n "${YCA_TOOL_REGISTRY[$t]:-}" ]] || fail "$t not registered"
done

# (4) The real-fetch languages MUST be gated `writes` — adding a dep fetches +
# may run install/postinstall code + mutates the lockfile. >=4 is the audit bar;
# pin the six that genuinely mutate so a future edit can't quietly loosen them.
n_writes=0
for t in rust_dep_add nodejs_dep_add python_dep_add go_dep_add ruby_dep_add php_dep_add; do
    IFS='|' read -r _fn dg _rest <<< "${YCA_TOOL_REGISTRY[$t]}"
    [[ "$dg" == "writes" ]] || fail "$t registered '$dg', expected writes (must be gated)"
    n_writes=$((n_writes + 1))
done
(( n_writes >= 4 )) || fail "expected >=4 dep_add tools gated writes, got $n_writes"

# (5) Machine-mode consent gate: tool_dispatch of a `writes` dep_add in json mode
# without auto_confirm is auto-denied (never runs the add). Categories rust/nodejs
# are enabled in the preamble, so the denial is the danger gate, not the cat gate.
YCA_AUTO_CONFIRM=false
for t in rust_dep_add nodejs_dep_add; do
    out=$(tool_dispatch "$t" '{"package":"leftpad"}') || true
    grep -qi 'cancel\|confirm' <<<"$out" || fail "$t not gated in machine mode (got: $out)"
done

# (6) The toolchain-aware deps.add workflow exists and is a gated write
# (wf entry = fn|tier|danger|needs|desc|cx).
info="${YCA_WF_REGISTRY[deps.add]:-}"
[[ -n "$info" ]] || fail "deps.add workflow not registered"
IFS='|' read -r _wfn _tier wdg _wrest <<< "$info"
[[ "$wdg" == "writes" ]] || fail "deps.add workflow registered '$wdg', expected writes"

echo "dep_add_body OK"
