#!/usr/bin/env bash
# Test T6: Schema descriptions + enums.
# Sources the harness and iterates the REGISTRY (YCA_TOOL_SCHEMAS) — never greps
# source text (PLAN.md T6). Enforces, for every registered tool schema:
#  (1) parses under jq -e;
#  (2) every property has a non-empty description;
#  (3) `required` is a subset of `properties` keys (classic silent-drift bug);
#  (4) no anyOf/oneOf/allOf anywhere, and nesting depth <= 3 (flat-schema rule, F12);
#  (5) every `enum` is a non-empty array of strings;
#  (6) the flagship closed set docker_list_containers.target carries its enum;
#  (7) wire-size snapshot: build_tools_json bytes stay under a recorded cap (D6).
set -Euo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
cd "$TMP"

RES=$( (
  export YCA_DIR="$PROJ_ROOT" YCA_PROJECT_DIR="$TMP" HARNESS_UPDATE_ENABLED=false
  source "$PROJ_ROOT/harness/main.sh" </dev/null 2>/dev/null
  fail(){ echo "FAIL: $1"; exit 1; }

  bad_json=0 no_desc=0 req_drift=0 complex=0 deep=0 bad_enum=0
  first_nodesc="" first_reqdrift="" first_complex="" first_enum=""
  for name in "${!YCA_TOOL_SCHEMAS[@]}"; do
    s="${YCA_TOOL_SCHEMAS[$name]}"
    # (1) valid JSON
    printf '%s' "$s" | jq -e . >/dev/null 2>&1 || { bad_json=$((bad_json+1)); [[ -z "${first_bad:-}" ]] && first_bad="$name"; continue; }
    # (2) every property has a non-empty description
    n=$(printf '%s' "$s" | jq '[.properties // {} | to_entries[] | select((.value.description // "")=="")] | length')
    [[ "$n" == "0" ]] || { no_desc=$((no_desc+1)); [[ -z "$first_nodesc" ]] && first_nodesc="$name"; }
    # (3) required subset of properties
    d=$(printf '%s' "$s" | jq '((.required // []) - ((.properties // {}) | keys)) | length')
    [[ "$d" == "0" ]] || { req_drift=$((req_drift+1)); [[ -z "$first_reqdrift" ]] && first_reqdrift="$name"; }
    # (4) no anyOf/oneOf/allOf; nesting depth <= 3
    c=$(printf '%s' "$s" | jq '[paths | map(tostring) | any(. == "anyOf" or . == "oneOf" or . == "allOf")] | any')
    [[ "$c" == "false" ]] || { complex=$((complex+1)); [[ -z "$first_complex" ]] && first_complex="$name"; }
    depth=$(printf '%s' "$s" | jq '[paths | length] | max // 0')
    [[ "$depth" -le 6 ]] || { deep=$((deep+1)); }
    # (5) every enum is a non-empty array of strings
    e=$(printf '%s' "$s" | jq '[.. | objects | select(has("enum")) | .enum | select((type != "array") or (length==0) or (map(type) | any(. != "string")))] | length')
    [[ "$e" == "0" ]] || { bad_enum=$((bad_enum+1)); [[ -z "$first_enum" ]] && first_enum="$name"; }
  done

  [[ "$bad_json"  == "0" ]] || fail "$bad_json schemas are not valid JSON (e.g. ${first_bad:-})"
  [[ "$no_desc"   == "0" ]] || fail "$no_desc schemas have a property without a description (e.g. $first_nodesc)"
  [[ "$req_drift" == "0" ]] || fail "$req_drift schemas list a required field absent from properties (e.g. $first_reqdrift)"
  [[ "$complex"   == "0" ]] || fail "$complex schemas use anyOf/oneOf/allOf (e.g. $first_complex)"
  [[ "$deep"      == "0" ]] || fail "$deep schemas nest too deep"
  [[ "$bad_enum"  == "0" ]] || fail "$bad_enum schemas have an enum that is not a non-empty array of strings (e.g. $first_enum)"

  # (6) flagship enum present
  printf '%s' "${YCA_TOOL_SCHEMAS[docker_list_containers]}" \
    | jq -e '.properties.target.enum == ["all","running","stopped"]' >/dev/null \
    || fail "docker_list_containers.target must carry the enum [all,running,stopped]"
  printf '%s' "${YCA_TOOL_SCHEMAS[docker_list_containers]}" \
    | jq -e '(.properties.target.description // "") != ""' >/dev/null \
    || fail "docker_list_containers.target must carry a description"

  # (7) wire-size snapshot for the default (core) tool set. Descriptions cost
  # tokens; this cap makes catalog growth a conscious commit (D6). Core-only.
  YCA_CAT_ENABLED=(); YCA_CAT_ENABLED[core]=1
  tools_invalidate_cache 2>/dev/null || true
  bytes=$(build_tools_json | wc -c | tr -d ' ')
  CAP=6000
  [[ "$bytes" -le "$CAP" ]] || fail "default core tools JSON is $bytes bytes (> $CAP cap); descriptions grew the wire — bump CAP deliberately if intended"
  [[ "$bytes" -gt 0 ]] || fail "build_tools_json produced no bytes"

  echo "schema_descriptions OK (core wire=$bytes bytes)"
) 2>&1 )
if ! echo "$RES" | grep -q "schema_descriptions OK"; then
    echo "$RES" | grep -E "FAIL" || echo "$RES"
    exit 1
fi
echo "test_schema_descriptions OK"
exit 0
