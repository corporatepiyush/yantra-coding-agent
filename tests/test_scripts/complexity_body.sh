#!/usr/bin/env bash
# tests/test_scripts/complexity_body.sh — unit body for complexity taxonomy and
# the tool/workflow complexity lookups (incl. config overrides). Args: $1=YCA_DIR
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source harness modules at TOP LEVEL so their `declare -A` stays global.
export YCA_DIR="$1"
source "$YCA_DIR/harness/lib/constants.sh"
source "$YCA_DIR/harness/lib/bash53.sh"; _yca_bash_init
source "$YCA_DIR/harness/lib/logging.sh"
source "$YCA_DIR/harness/lib/strings.sh"
source "$YCA_DIR/harness/core/complexity.sh"
source "$YCA_DIR/harness/core/projectconfig.sh"
source "$YCA_DIR/harness/core/tools.sh"
source "$YCA_DIR/harness/core/workflows.sh"
source "$HERE/lib_common.sh"

# normalize
assert_eq "high" "$(complexity_normalize think)"  "think→high"
assert_eq "mid"  "$(complexity_normalize build)"  "build→mid"
assert_eq "low"  "$(complexity_normalize tool)"   "tool→low"
assert_eq "low"  "$(complexity_normalize '')"     "empty→low"
assert_eq "low"  "$(complexity_normalize garbage)" "garbage→low"

# tier mapping
assert_eq "think" "$(complexity_tier high)" "high→think tier"
assert_eq "build" "$(complexity_tier mid)"  "mid→build tier"
assert_eq "tool"  "$(complexity_tier low)"  "low→tool tier"

# needs_llm
complexity_needs_llm high && : || { echo "high should need llm" >&2; exit 1; }
complexity_needs_llm mid  && : || { echo "mid should need llm"  >&2; exit 1; }
if complexity_needs_llm low; then echo "low should NOT need llm" >&2; exit 1; fi

# tool registry complexity (default low; explicit mid; config override wins)
tool_register "u_static" fn_static '{"type":"object","properties":{}}' safe all core
tool_register "u_llm"    fn_llm    '{"type":"object","properties":{}}' safe all core mid
assert_eq "low" "$(tool_complexity u_static)" "static tool defaults low"
assert_eq "mid" "$(tool_complexity u_llm)"    "llm tool registered mid"
YCA_COMPLEXITY_OVERRIDE[u_static]="high"
assert_eq "high" "$(tool_complexity u_static)" "config override wins for tool"

# workflow registry complexity
wf_register "u.wf"    fn_wf    1 safe "" "static wf"
wf_register "u.wfmid" fn_wfmid 1 safe "" "dynamic wf" mid
assert_eq "low" "$(wf_complexity u.wf)"    "static wf defaults low"
assert_eq "mid" "$(wf_complexity u.wfmid)" "dynamic wf registered mid"
YCA_COMPLEXITY_OVERRIDE[u.wf]="high"
assert_eq "high" "$(wf_complexity u.wf)"   "config override wins for wf"

echo "complexity_body OK"
