#!/usr/bin/env bash
# core/validate.sh — Argument validation with corrective errors + safe coercion (T7)
#
# Flow (see _tool_exec): coerce_arguments first (fix obviously-wrong types so the
# model isn't punished for a string-encoded number/array), THEN validate. On a
# real error, emit a message the small model can act on next turn: unknown field
# with a did-you-mean, missing required field, or wrong type naming the expected.

# _levenshtein A B -> edit distance (for did-you-mean suggestions).
_levenshtein() {
    awk -v a="$1" -v b="$2" 'BEGIN{
        la=length(a); lb=length(b);
        for(i=0;i<=la;i++) d[i,0]=i;
        for(j=0;j<=lb;j++) d[0,j]=j;
        for(i=1;i<=la;i++) for(j=1;j<=lb;j++){
            c=(substr(a,i,1)==substr(b,j,1))?0:1;
            m=d[i-1,j]+1; n=d[i,j-1]+1; o=d[i-1,j-1]+c;
            d[i,j]=(m<n?(m<o?m:o):(n<o?n:o));
        }
        print d[la,lb];
    }'
}

# _closest_field UNKNOWN VALID_CSV -> the nearest valid field name if it is a
# plausible typo (edit distance <= 2 and strictly closer than "unrelated"),
# else empty. Prevents suggesting 'path' for an unrelated 'timeout'.
_closest_field() {
    local unknown="$1" valids="$2" best="" bestd=99 f d
    IFS=',' read -ra _arr <<< "$valids"
    for f in "${_arr[@]}"; do
        f="${f// /}"; [[ -z "$f" ]] && continue
        d=$(_levenshtein "$unknown" "$f")
        if (( d < bestd )); then bestd=$d; best=$f; fi
    done
    # Only suggest for near-misses: distance <= 2 and <= half the field length.
    if (( bestd <= 2 )) && (( bestd * 2 <= ${#best} + 1 )); then printf '%s' "$best"; fi
}

# coerce_arguments ARGS_JSON TOOL_NAME -> ARGS_JSON with schema-driven safe
# coercions applied. Idempotent. Only converts when the schema's declared type
# makes the intent unambiguous:
#   number/integer  <- numeric string  ("8080" -> 8080)
#   boolean         <- "true"/"false"  ("true" -> true)
#   array           <- JSON-array string ("[\"a\"]" -> ["a"])
coerce_arguments() {
    local args_json="$1" tool_name="$2"
    local schema="${YCA_TOOL_SCHEMAS[$tool_name]:-}"
    [[ -z "$schema" ]] && { printf '%s' "$args_json"; return 0; }
    # Build a {field:type} map from the schema, then coerce matching string values.
    printf '%s' "$args_json" | jq -c --argjson sch "$schema" '
        ($sch.properties // {}) as $props
        | with_entries(
            .key as $k | .value as $v
            | ($props[$k].type // "") as $t
            | .value = (
                if ($v|type) != "string" then $v
                elif ($t=="number" or $t=="integer") and ($v|test("^-?[0-9]+(\\.[0-9]+)?$")) then ($v|tonumber)
                elif ($t=="boolean") and ($v=="true" or $v=="false") then ($v=="true")
                elif ($t=="array") and ($v|test("^\\s*\\[")) then (($v|fromjson?) // $v)
                else $v end))' 2>/dev/null || printf '%s' "$args_json"
}

# validate_args_against_schema NAME ARGS_JSON -> 0 valid, 1 invalid.
# Prints the corrective message to stderr on failure.
validate_args_against_schema() {
    local tool_name="$1" args_json="$2"
    local schema="${YCA_TOOL_SCHEMAS[$tool_name]:-}"
    [[ -z "$schema" ]] && return 0   # unknown/schemaless tool: nothing to check

    local properties valid_csv
    properties=$(printf '%s' "$schema" | jq -c '.properties // {}' 2>/dev/null)
    valid_csv=$(printf '%s' "$properties" | jq -r 'keys | join(",")' 2>/dev/null)

    # Args must be a JSON object.
    printf '%s' "$args_json" | jq -e 'type == "object"' >/dev/null 2>&1 \
        || { printf "arguments must be a JSON object\n" >&2; return 1; }

    # Unknown fields -> error with a did-you-mean when a near-miss exists.
    local unknown
    unknown=$(jq -rn --argjson a "$args_json" --argjson p "$properties" \
        '($a|keys) - ($p|keys) | .[0] // empty' 2>/dev/null)
    if [[ -n "$unknown" ]]; then
        local hint suggestion
        suggestion=$(_closest_field "$unknown" "$valid_csv")
        [[ -n "$suggestion" ]] && hint="; did you mean '$suggestion'?"
        printf "unknown field '%s'; this tool takes {%s}%s\n" "$unknown" "$valid_csv" "${hint:-}" >&2
        return 1
    fi

    # Missing required fields (presence, not truthiness — a required false/null/0
    # is still present). `has` is the correct test.
    local req missing
    while IFS= read -r req; do
        [[ -z "$req" ]] && continue
        printf '%s' "$args_json" | jq -e --arg k "$req" 'has($k)' >/dev/null 2>&1 \
            || missing="${missing:+$missing, }$req"
    done < <(printf '%s' "$schema" | jq -r '.required[]? // empty' 2>/dev/null)
    if [[ -n "${missing:-}" ]]; then
        printf "missing required field(s): %s\n" "$missing" >&2
        return 1
    fi

    # Type checks (run AFTER coercion, so only genuinely-wrong types remain).
    local key
    while IFS= read -r key; do
        [[ -z "$key" ]] && continue
        local expected actual
        expected=$(printf '%s' "$properties" | jq -r --arg k "$key" '.[$k].type // empty' 2>/dev/null)
        [[ -z "$expected" ]] && continue
        # Skip absent or null values.
        printf '%s' "$args_json" | jq -e --arg k "$key" 'has($k) and (.[$k] != null)' >/dev/null 2>&1 || continue
        actual=$(printf '%s' "$args_json" | jq -r --arg k "$key" '.[$k] | type' 2>/dev/null)
        # A string value is tolerated for ANY field (F9): coercion already ran, so
        # a string that remains is either JSON the tool will parse or bad input the
        # tool rejects with a domain-specific message ("boxes must be valid JSON").
        # Hard-erroring here would pre-empt those better messages and punish the
        # exact small-model mistake T7 is meant to forgive.
        [[ "$actual" == "string" ]] && continue
        case "$expected" in
            integer|number) [[ "$actual" == "number" ]]  || { printf "field '%s' expects %s, got %s\n" "$key" "$expected" "$actual" >&2; return 1; } ;;
            boolean)        [[ "$actual" == "boolean" ]] || { printf "field '%s' expects boolean, got %s\n" "$key" "$actual" >&2; return 1; } ;;
            array)          [[ "$actual" == "array" ]]   || { printf "field '%s' expects array, got %s\n" "$key" "$actual" >&2; return 1; } ;;
            object)         [[ "$actual" == "object" ]]  || { printf "field '%s' expects object, got %s\n" "$key" "$actual" >&2; return 1; } ;;
        esac
    done < <(printf '%s' "$properties" | jq -r 'keys[]' 2>/dev/null)

    return 0
}
