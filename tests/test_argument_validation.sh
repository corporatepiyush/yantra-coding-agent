#!/usr/bin/env bash
# Test T7: Argument validation with corrective errors
# Verifies: validation logic produces corrective error messages when schema exists
set -Euo pipefail
HARNESS="$1"; TMP="$2"

PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"

# Source validation functions
source "$PROJ_ROOT/harness/core/validate.sh"

# Set up minimal test schemas
declare -A YCA_TOOL_SCHEMAS
declare -A YCA_TOOL_REGISTRY
YCA_TOOL_SCHEMAS["read"]='{"type":"object","properties":{"path":{"type":"string","description":"File path"}},"required":["path"]}'
YCA_TOOL_SCHEMAS["docker_list_containers"]='{"type":"object","properties":{"target":{"type":"string","description":"Container filter","enum":["all","running","stopped"]}},"required":["target"]}'

# Test 1: Missing required field
ERROR=$(validate_args_against_schema "read" '{}' 2>&1 || true)
if [[ "$ERROR" == *"missing required"* ]]; then
    : # Pass
else
    echo "FAIL: Should detect missing required field"
    echo "Got: $ERROR"
    exit 1
fi

# Test 2: Unknown field error
ERROR=$(validate_args_against_schema "read" '{"path":"/tmp/test","unknown_field":"value"}' 2>&1 || true)
if [[ "$ERROR" == *"unknown field"* ]]; then
    : # Pass
else
    echo "FAIL: Should detect unknown field"
    echo "Got: $ERROR"
    exit 1
fi

# Test 3: Error message includes valid fields
if [[ "$ERROR" == *"path"* ]]; then
    : # Pass
else
    echo "FAIL: Error should mention valid field names"
    echo "Got: $ERROR"
    exit 1
fi

# Test 4: Valid arguments pass validation
if validate_args_against_schema "read" '{"path":"/tmp/test"}' 2>&1; then
    : # Pass
else
    echo "FAIL: Valid arguments should pass"
    exit 1
fi

# Test 5: No schema = no validation (returns 0)
if validate_args_against_schema "nosuchool" '{}' 2>&1; then
    : # Pass - no schema means no validation
else
    echo "FAIL: Tool without schema should pass (no validation)"
    exit 1
fi

# Test 6: Error is actionable
ERROR=$(validate_args_against_schema "read" '{"wrong_name":"/tmp"}' 2>&1 || true)
if [[ "$ERROR" == *"wrong_name"* ]] && [[ "$ERROR" == *"path"* ]]; then
    : # Pass
else
    echo "FAIL: Error should show the wrong field and suggest correct one"
    echo "Got: $ERROR"
    exit 1
fi

# ── Phase 2: full-harness assertions through tool_dispatch ───────────────────
# The above tests validate() directly; these drive the real dispatch path (which
# also exercises the args_json plumbing) and cover coercion + the spy pattern.
DOUT=$( (
  export YCA_DIR="$PROJ_ROOT" YCA_PROJECT_DIR="$TMP"
  source "$PROJ_ROOT/harness/main.sh" 2>/dev/null </dev/null
  YCA_PROJECT_DIR="$TMP"; YCA_SAFETY_PATHS="$TMP"; YCA_UI_MODE=plain; YCA_AUTO_CONFIRM=true
  YCA_CAT_ENABLED[core]=1; db_init 2>/dev/null; cd "$TMP"
  df(){ echo "FAIL: $1"; exit 1; }

  # did-you-mean on a near-miss, through dispatch
  err=$(tool_dispatch read '{"paht":"x"}')
  [[ "$err" == *"did you mean 'path'?"* ]] || df "no did-you-mean for near-miss 'paht': $err"
  # false-positive guard: NO suggestion for an unrelated field
  err=$(tool_dispatch read '{"zzzzz":"x"}')
  [[ "$err" != *"did you mean"* ]] || df "unexpected suggestion for unrelated field: $err"

  # Coercion via an echo fixture: string number/array/bool arrive typed
  _t7_echo(){ printf '%s' "${5:-}"; }
  tool_register t7_echo _t7_echo '{"type":"object","properties":{"port":{"type":"integer"},"tags":{"type":"array"},"flag":{"type":"boolean"}},"required":["port"]}' safe all core
  got=$(tool_dispatch t7_echo '{"port":"8080","tags":"[\"a\"]","flag":"false"}')
  [[ "$(printf '%s' "$got" | jq -r '.port|type')" == "number" ]]  || df "port not coerced to number: $got"
  [[ "$(printf '%s' "$got" | jq -r '.tags|type')" == "array" ]]   || df "tags not coerced to array: $got"
  [[ "$(printf '%s' "$got" | jq -r '.flag|type')" == "boolean" ]] || df "flag not coerced to boolean: $got"

  # Spy: an INVALID call must NOT run the tool fn (checklist #1); the generic
  # positional fallback is never reached (validation returns before exec).
  MARK="$TMP/t7.ran"; _t7_spy(){ touch "$MARK"; printf 'ran'; }
  tool_register t7_spy _t7_spy '{"type":"object","properties":{"port":{"type":"integer"}},"required":["port"]}' safe all core
  rm -f "$MARK"
  out=$(tool_dispatch t7_spy '{"nope":1}')
  [[ ! -e "$MARK" ]] || df "tool fn ran on an invalid call (marker present)"
  [[ "$out" == *"unknown field"* || "$out" == *"missing required"* ]] || df "no corrective error on invalid call: $out"
  # companion positive case: a VALID call DOES run it
  tool_dispatch t7_spy '{"port":5}' >/dev/null
  [[ -e "$MARK" ]] || df "valid call did not run the tool fn"

  echo "t7_dispatch_ok"
) 2>&1 )
if ! echo "$DOUT" | grep -q "t7_dispatch_ok"; then
    echo "$DOUT" | grep -E "FAIL" || echo "$DOUT"
    exit 1
fi

echo "test_argument_validation OK"
exit 0
