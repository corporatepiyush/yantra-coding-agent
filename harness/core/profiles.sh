#!/usr/bin/env bash
# core/profiles.sh — T9 capability profiles.
#
# Two kinds of profile, both facts (never assumptions):
#  (a) PROVIDER profile — for the LLM endpoints Yantra's *_llm_* tools still call
#      directly via llm_analyze. Records context_window (feeds T10),
#      response_format support, vision, and a `metered` flag. A metered provider
#      (config `probe:false`) is NEVER contacted — its profile is config+defaults
#      only. Config-declared fields always win over probed ones.
#  (b) HOST record — captured from the MCP handshake: does the connected host
#      support sampling / elicitation / roots. Drives every fallback (D5): no
#      sampling → *_llm_* tools use the provider; no elicitation → writes-class
#      tools deny with explanation (enforced in tool_dispatch).
#
# Out of scope by decision (D8): tool-call wire formats, parallel calls,
# tool_choice, id formats — those concern the host's loop, not Yantra.

declare -A YCA_PROVIDER_PROFILE   # provider url -> JSON profile (session cache)
: "${YCA_PROFILE_DEFAULT_CTX:=4096}"   # conservative floor for small local models

# _profile_curl URL TOKEN PATH BODY -> raw response body on stdout; rc reflects
# reachability. THE stubbable HTTP seam: tests override this to count calls and
# return canned responses without a network. PATH is appended to URL.
_profile_curl() {
    local url="$1" token="$2" path="$3" body="$4"
    printf '%s' "$body" | curl -sS --max-time "${YCA_LLM_TIMEOUT:-30}" \
        --connect-timeout 10 --proto '=http,https' \
        -H @<(printf 'Authorization: Bearer %s\n' "$token") \
        -H "Content-Type: application/json" \
        --data-binary @- "${url}${path}" 2>/dev/null
}

# _provider_config_field URL FIELD -> the value declared for URL in the provider
# config, or empty if the field is absent. Config is authoritative over probed
# values. Uses has()/else-empty rather than `//` because jq's `//` treats a
# legitimate `false` (e.g. probe:false, vision:false) as absent — which would
# silently defeat the metered guard.
_provider_config_field() {
    local url="$1" field="$2"
    printf '%s' "${YCA_PROVIDERS_JSON:-{}}" | jq -r --arg u "$url" --arg f "$field" \
        '[.think,.build,.tool] | add | map(select(.url==$u)) | .[0]
         | if type=="object" and has($f) then .[$f] else empty end' 2>/dev/null
}

# provider_is_metered URL -> 0 (true) if the provider declares probe:false.
# A metered provider must receive ZERO probe traffic (bills per request).
provider_is_metered() {
    [[ "$(_provider_config_field "$1" probe)" == "false" ]]
}

# _provider_probe_ctx URL TOKEN MODEL -> context window via Ollama's /api/show
# (the one widely-available introspection endpoint), else empty. One HTTP call.
_provider_probe_ctx() {
    local url="$1" token="$2" model="$3"
    # /api/show lives at the server root; strip a trailing /v1 if present.
    local root="${url%/v1}"
    local resp
    resp=$(_profile_curl "$root" "$token" "/api/show" "$(jq -cn --arg m "$model" '{name:$m}')")
    printf '%s' "$resp" | jq -r '
        (.model_info // {}) | to_entries
        | map(select(.key | endswith(".context_length"))) | .[0].value // empty' 2>/dev/null
}

# _provider_probe_rf URL TOKEN MODEL -> "yes"|"no": does the endpoint honor
# response_format:{json_object}? One tiny chat/completions call.
_provider_probe_rf() {
    local url="$1" token="$2" model="$3"
    local body resp
    body=$(jq -cn --arg m "$model" \
        '{model:$m, max_tokens:1, response_format:{type:"json_object"},
          messages:[{role:"user",content:"reply with {}"}]}')
    resp=$(_profile_curl "$url" "$token" "/chat/completions" "$body")
    # A well-formed choices array (no error object) means the field was accepted.
    printf '%s' "$resp" | jq -e '.choices[0] and (.error|not)' >/dev/null 2>&1 && printf 'yes' || printf 'no'
}

# provider_profile_build URL MODEL TOKEN -> compute + cache the profile.
# Metered => no HTTP at all. Config-declared fields win over probed.
provider_profile_build() {
    local url="$1" model="${2:-}" token="${3:-}"
    local cfg_ctx cfg_vis cfg_rf metered=false ctx vision rf
    cfg_ctx=$(_provider_config_field "$url" context_window)
    cfg_vis=$(_provider_config_field "$url" vision)
    cfg_rf=$(_provider_config_field "$url" response_format)

    if provider_is_metered "$url"; then
        metered=true
        ctx="${cfg_ctx:-$YCA_PROFILE_DEFAULT_CTX}"
        vision="${cfg_vis:-unknown}"
        rf="${cfg_rf:-unknown}"
    else
        if [[ -n "$cfg_ctx" ]]; then ctx="$cfg_ctx"; else ctx="$(_provider_probe_ctx "$url" "$token" "$model")"; fi
        [[ -n "$ctx" ]] || ctx="$YCA_PROFILE_DEFAULT_CTX"
        vision="${cfg_vis:-unknown}"
        if [[ -n "$cfg_rf" ]]; then rf="$cfg_rf"; else rf="$(_provider_probe_rf "$url" "$token" "$model")"; fi
    fi

    YCA_PROVIDER_PROFILE[$url]=$(jq -cn \
        --arg u "$url" --arg c "$ctx" --arg v "$vision" --arg r "$rf" --argjson m "$metered" \
        '{url:$u, context_window:(($c|tonumber?) // $c), vision:$v, response_format:$r, metered:$m}')
    printf '%s' "${YCA_PROVIDER_PROFILE[$url]}"
}

# provider_profile URL -> the cached profile JSON (building it if absent).
provider_profile() {
    local url="$1"
    [[ -n "${YCA_PROVIDER_PROFILE[$url]:-}" ]] && { printf '%s' "${YCA_PROVIDER_PROFILE[$url]}"; return 0; }
    provider_profile_build "$url" "${2:-}" "${3:-}"
}

# ── Host capability record (from the MCP handshake) ─────────────────────────
# _b VALUE -> the JSON boolean for a "true"/"false"/"1"/"0" string.
_b() { case "$1" in true|1) printf 'true';; *) printf 'false';; esac; }

# host_capability_record -> JSON of the connected host's capabilities. Defaults to
# all-false (safe: no sampling → provider fallback; no elicitation → deny writes).
host_capability_record() {
    jq -cn \
        --argjson s "$(_b "${YCA_MCP_SAMPLING:-false}")" \
        --argjson e "$(_b "${YCA_MCP_ELICITATION:-false}")" \
        --argjson r "$(_b "${YCA_MCP_ROOTS:-false}")" \
        '{sampling:$s, elicitation:$e, roots:$r}'
}

# host_supports CAP -> 0 if the host advertised CAP (sampling|elicitation|roots).
host_supports() {
    case "$1" in
        sampling)    [[ "${YCA_MCP_SAMPLING:-false}"    == "true" || "${YCA_MCP_SAMPLING:-}"    == "1" ]] ;;
        elicitation) [[ "${YCA_MCP_ELICITATION:-false}" == "true" || "${YCA_MCP_ELICITATION:-}" == "1" ]] ;;
        roots)       [[ "${YCA_MCP_ROOTS:-false}"       == "true" || "${YCA_MCP_ROOTS:-}"       == "1" ]] ;;
        *) return 1 ;;
    esac
}

# doctor_profile_providers -> build a profile for every configured provider url
# (metered ones stay uncontacted). Idempotent; safe to call from doctor.
doctor_profile_providers() {
    local urls u model token
    urls=$(printf '%s' "${YCA_PROVIDERS_JSON:-{}}" | jq -r '[.think,.build,.tool] | add | map(.url) | .[]?' 2>/dev/null)
    for u in $urls; do
        [[ -n "$u" ]] || continue
        model=$(_provider_config_field "$u" model); [[ -n "$model" ]] || model="${YCA_LLM_MODEL:-}"
        token=$(_provider_config_field "$u" token)
        provider_profile_build "$u" "$model" "$token" >/dev/null
    done
}

# profiles_json -> both profiles as one object (for the doctor result frame).
profiles_json() {
    # The keys form `${!arr[@]}` is set -u safe on an empty assoc array; the count
    # form `${#arr[@]}` is NOT (bash quirk), so route through a keys array.
    local -a _urls=( "${!YCA_PROVIDER_PROFILE[@]}" )
    local provs="[]" u
    if [[ ${#_urls[@]} -gt 0 ]]; then
        provs=$(for u in "${_urls[@]}"; do printf '%s\n' "${YCA_PROVIDER_PROFILE[$u]}"; done | jq -cs .)
    fi
    jq -cn --argjson h "$(host_capability_record)" --argjson p "$provs" '{host:$h, providers:$p}'
}

# doctor_print_profiles -> human-readable dump of both profiles (called by doctor).
doctor_print_profiles() {
    printf 'Host capabilities (MCP handshake):\n'
    printf '  sampling=%s  elicitation=%s  roots=%s\n' \
        "$(host_supports sampling && echo yes || echo no)" \
        "$(host_supports elicitation && echo yes || echo no)" \
        "$(host_supports roots && echo yes || echo no)"
    local -a _urls=( "${!YCA_PROVIDER_PROFILE[@]}" ) u   # keys form is set -u safe
    printf 'Provider profiles (%s):\n' "${#_urls[@]}"
    if [[ ${#_urls[@]} -eq 0 ]]; then
        printf '  (none profiled yet)\n'; return 0
    fi
    for u in "${_urls[@]}"; do
        printf '  %s\n' "$(printf '%s' "${YCA_PROVIDER_PROFILE[$u]}" | jq -r \
            '"    " + .url + "  ctx=" + (.context_window|tostring) + "  response_format=" + .response_format + "  vision=" + .vision + "  metered=" + (.metered|tostring)')"
    done
}
