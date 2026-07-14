# core/providers.sh — Multi-provider LLM routing.
#
# Three tiers, one per complexity level:
#   think (high) · build (mid) · tool (low)
# Each tier is a priority-ordered list of providers {url, model, token|token_env,
# priority}. Routing rules:
#   • Sticky single URL — a tier keeps using its highest-priority URL so a remote
#     endpoint's prompt cache stays warm. We only advance to the next URL when the
#     current one is NOT network-reachable (marked dead by a failed call).
#   • Fall-down — if a call's tier has no live URL, fall to lower tiers
#     (think→build→tool). "low" only ever uses the tool tier.
#   • env override — HARNESS_LLM_URL (if set) becomes the sole provider in every
#     tier, so a single env var still works and wins over the config file.

# providers_load — normalize YCA_PROVIDERS_JSON: apply the env override, then sort
# each tier by descending priority so index 0 is the preferred provider.
providers_load() {
    if [[ -n "${HARNESS_LLM_URL:-}" ]]; then
        # Same gate every config-file URL passes (provider_resolve): reject a
        # value that isn't a plain http(s) URL so it can never smuggle a curl
        # option (leading '-') or shell metacharacters into the LLM layer.
        local _env_url
        if _env_url=$(sanitize_url "$HARNESS_LLM_URL"); then
            YCA_PROVIDERS_JSON=$(jq -n \
                --arg url "$_env_url" --arg model "$YCA_LLM_MODEL" \
                --arg tokenEnv "HARNESS_API_TOKEN" \
                '{provider:[{url:$url,model:$model,token_env:$tokenEnv,priority:100}]}
                 | {think:.provider, build:.provider, tool:.provider}')
        else
            log_warn "ignoring malformed HARNESS_LLM_URL (not a plain http(s) URL)"
        fi
    fi
    YCA_PROVIDERS_JSON=$(printf '%s' "$YCA_PROVIDERS_JSON" | jq -c '
        (.think // []) as $t | (.build // []) as $b | (.tool // []) as $l |
        { think: ($t | sort_by(-(.priority // 0))),
          build: ($b | sort_by(-(.priority // 0))),
          tool:  ($l | sort_by(-(.priority // 0))) }' 2>/dev/null || printf '{"think":[],"build":[],"tool":[]}')
    YCA_TIER_ACTIVE_URL=()
    YCA_URL_DEAD=()
}

# providers_detect — set YCA_HAVE_LLM=1 iff any tier has at least one provider URL.
providers_detect() {
    local n
    n=$(printf '%s' "$YCA_PROVIDERS_JSON" | jq '[.think,.build,.tool] | add | map(select(.url and (.url|length>0))) | length' 2>/dev/null || printf 0)
    YCA_HAVE_LLM=0
    [[ "${n:-0}" -gt 0 ]] && YCA_HAVE_LLM=1
    return 0
}

# providers_tier_order COMPLEXITY -> tiers to try, preferred first, then downward.
providers_tier_order() {
    case "$(complexity_normalize "$1")" in
        high) printf 'think build tool' ;;
        mid)  printf 'build tool' ;;
        *)    printf 'tool' ;;
    esac
}

# _provider_token ENTRY_JSON -> resolved bearer token (entry.token, else
# $entry.token_env, else the global fallback).
_provider_token() {
    local entry="$1" tok tenv
    tok=$(printf '%s' "$entry" | jq -r '.token // empty' 2>/dev/null)
    if [[ -z "$tok" ]]; then
        tenv=$(printf '%s' "$entry" | jq -r '.token_env // empty' 2>/dev/null)
        [[ -n "$tenv" ]] && tok="${!tenv:-}"
    fi
    printf '%s' "${tok:-$YCA_API_TOKEN}"
}

# provider_resolve COMPLEXITY -> prints "url\tmodel\ttoken" for the provider to
# use, honoring sticky selection and tier fall-down. Returns 1 if none available.
provider_resolve() {
    local complexity="$1" tier entries n i url active
    for tier in $(providers_tier_order "$complexity"); do
        entries=$(printf '%s' "$YCA_PROVIDERS_JSON" | jq -c ".${tier} // []" 2>/dev/null)
        n=$(printf '%s' "$entries" | jq 'length' 2>/dev/null || printf 0)
        [[ "${n:-0}" -eq 0 ]] && continue

        # Sticky: reuse this tier's active URL if it is still live and present.
        active="${YCA_TIER_ACTIVE_URL[$tier]:-}"
        if [[ -n "$active" && -z "${YCA_URL_DEAD[$active]:-}" ]]; then
            local entry
            entry=$(printf '%s' "$entries" | jq -c --arg u "$active" '.[] | select(.url==$u)' 2>/dev/null | head -1)
            [[ -n "$entry" ]] && { _provider_emit "$entry"; return 0; }
        fi
        # Otherwise pick the first live (non-dead), well-formed URL by priority.
        for ((i=0; i<n; i++)); do
            url=$(printf '%s' "$entries" | jq -r ".[$i].url // empty" 2>/dev/null)
            [[ -z "$url" || -n "${YCA_URL_DEAD[$url]:-}" ]] && continue
            sanitize_url "$url" >/dev/null || { log_warn "ignoring malformed provider url: $url"; continue; }
            YCA_TIER_ACTIVE_URL[$tier]="$url"
            _provider_emit "$(printf '%s' "$entries" | jq -c ".[$i]")"
            return 0
        done
    done
    return 1
}

_provider_emit() {
    local entry="$1" url model token
    url=$(printf '%s' "$entry" | jq -r '.url')
    model=$(printf '%s' "$entry" | jq -r --arg m "$YCA_LLM_MODEL" '.model // $m')
    token=$(_provider_token "$entry")
    printf '%s\t%s\t%s' "$url" "$model" "$token"
}

# provider_mark_dead URL — record a URL as network-unreachable for this session so
# provider_resolve rotates to the next one. Called by the LLM layer on curl
# connect/timeout failures (not on HTTP error codes — those keep the URL sticky).
provider_mark_dead() {
    local url="$1"; [[ -z "$url" ]] && return 0
    YCA_URL_DEAD[$url]=1
    local tier
    for tier in $YCA_TIER_ORDER; do
        [[ "${YCA_TIER_ACTIVE_URL[$tier]:-}" == "$url" ]] && unset "YCA_TIER_ACTIVE_URL[$tier]"
    done
}

# provider_add_session URL — inject a URL as a provider in every tier for this
# session only (used when the user pastes a URL at the LLM-unavailable prompt).
# Never written back to the config file.
provider_add_session() {
    local url="$1"; [[ -z "$url" ]] && return 1
    YCA_PROVIDERS_JSON=$(printf '%s' "$YCA_PROVIDERS_JSON" | jq -c \
        --arg url "$url" --arg model "$YCA_LLM_MODEL" \
        '{provider:[{url:$url,model:$model,token_env:"HARNESS_API_TOKEN",priority:1000}]}
         | { think: ((.provider) + ($p.think // [])),
             build: ((.provider) + ($p.build // [])),
             tool:  ((.provider) + ($p.tool  // [])) }' --argjson p "$YCA_PROVIDERS_JSON" 2>/dev/null || printf '%s' "$YCA_PROVIDERS_JSON")
    YCA_TIER_ACTIVE_URL=()
    providers_detect
    return 0
}
