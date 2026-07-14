# core/complexity.sh — Complexity taxonomy and complexity→tier routing.
# Single responsibility: translate a registered complexity (high|mid|low) into an
# LLM provider tier, and answer "does this complexity need an LLM at all?".
# Kept dependency-free so tools, workflows, and the LLM layer can all reuse it.

# complexity_normalize VALUE -> one of: high | mid | low  (unknown → low)
# Fork-free (${v,,} instead of $(str_lower)): this sits under every dispatch.
complexity_normalize() {
    local v="${1:-}"
    case "${v,,}" in
        high|think) printf 'high' ;;
        mid|build|medium) printf 'mid' ;;
        low|tool|static|"") printf 'low' ;;
        *) printf 'low' ;;
    esac
}

# complexity_tier COMPLEXITY -> think | build | tool
complexity_tier() {
    case "$(complexity_normalize "$1")" in
        high) printf '%s' "$YCA_TIER_THINK" ;;
        mid)  printf '%s' "$YCA_TIER_BUILD" ;;
        *)    printf '%s' "$YCA_TIER_TOOL" ;;
    esac
}

# complexity_needs_llm COMPLEXITY -> exit 0 if the call routes to an LLM.
# low is static (no LLM); mid/high are dynamic (LLM-backed).
complexity_needs_llm() {
    case "$(complexity_normalize "$1")" in
        high|mid) return 0 ;;
        *)        return 1 ;;
    esac
}

# complexity_label COMPLEXITY -> human string for catalogs/help.
complexity_label() {
    case "$(complexity_normalize "$1")" in
        high) printf 'high (think tier)' ;;
        mid)  printf 'mid (build tier)' ;;
        *)    printf 'low (static, no LLM)' ;;
    esac
}
