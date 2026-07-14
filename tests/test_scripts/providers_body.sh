#!/usr/bin/env bash
# tests/test_scripts/providers_body.sh — unit body for the provider router.
# Args: $1=YCA_DIR
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Source harness modules at TOP LEVEL so their `declare -A` stays global.
export YCA_DIR="$1"
source "$YCA_DIR/harness/lib/constants.sh"
source "$YCA_DIR/harness/lib/bash53.sh"; _yca_bash_init
source "$YCA_DIR/harness/lib/logging.sh"
source "$YCA_DIR/harness/lib/strings.sh"
source "$YCA_DIR/harness/lib/sanitize.sh"
source "$YCA_DIR/harness/core/complexity.sh"
source "$YCA_DIR/harness/core/providers.sh"
source "$HERE/lib_common.sh"

# ── Deterministic routing ───────────────────────────────────────────────────
YCA_PROVIDERS_JSON='{"think":[{"url":"http://think-a","model":"big","priority":10},{"url":"http://think-b","priority":5}],"build":[{"url":"http://build-a"}],"tool":[{"url":"http://tool-a"}]}'
providers_load
providers_detect
assert_eq "1" "$YCA_HAVE_LLM" "have_llm with providers"

assert_eq "http://think-a" "$(provider_resolve high | cut -f1)" "high → highest-priority think"
assert_eq "http://think-a" "$(provider_resolve high | cut -f1)" "high sticky"
# model fallback: think-b has no model → YCA_LLM_MODEL
provider_mark_dead "http://think-a"
assert_eq "http://think-b" "$(provider_resolve high | cut -f1)" "rotate to next think on dead"
assert_eq "$YCA_LLM_MODEL" "$(provider_resolve high | cut -f2)" "model falls back when omitted"
provider_mark_dead "http://think-b"
assert_eq "http://build-a" "$(provider_resolve high | cut -f1)" "fall-down think→build"
assert_eq "http://build-a" "$(provider_resolve mid | cut -f1)" "mid → build"
assert_eq "http://tool-a"  "$(provider_resolve low | cut -f1)" "low → tool"
provider_mark_dead "http://build-a"; provider_mark_dead "http://tool-a"
if provider_resolve low >/dev/null; then echo "ASSERT FAIL: low should fail when tool dead" >&2; exit 1; fi

# ── env override wins over file ─────────────────────────────────────────────
HARNESS_LLM_URL="http://env-only" providers_load
assert_eq "http://env-only" "$(provider_resolve high | cut -f1)" "env override → high"
assert_eq "http://env-only" "$(provider_resolve low  | cut -f1)" "env override → low"

# ── token resolution: explicit token vs token_env vs global fallback ─────────
YCA_API_TOKEN="GLOBALTOK"
export SOME_TOKEN_ENV="ENVTOK"
YCA_PROVIDERS_JSON='{"think":[{"url":"http://x","token":"INLINE"}],"build":[{"url":"http://y","token_env":"SOME_TOKEN_ENV"}],"tool":[{"url":"http://z"}]}'
providers_load
assert_eq "INLINE"    "$(provider_resolve high | cut -f3)" "inline token wins"
assert_eq "ENVTOK"    "$(provider_resolve mid  | cut -f3)" "token_env resolved"
assert_eq "GLOBALTOK" "$(provider_resolve low  | cut -f3)" "global token fallback"

# ── session provider injection (from an unavailable-URL prompt) ─────────────
YCA_PROVIDERS_JSON='{"think":[],"build":[],"tool":[]}'
providers_load; providers_detect
assert_eq "0" "$YCA_HAVE_LLM" "no providers → have_llm 0"
provider_add_session "http://pasted"
assert_eq "1" "$YCA_HAVE_LLM" "session provider flips have_llm"
assert_eq "http://pasted" "$(provider_resolve high | cut -f1)" "session provider used"

# ── Fuzz: random provider lists must never crash or emit a non-URL ──────────
rand_url() { printf 'http://h%d.%d' "$RANDOM" "$RANDOM"; }
for i in $(seq 1 60); do
    mk() { # emit a random-length tier array
        local n=$((RANDOM % 4)) j out="["
        for ((j=0;j<n;j++)); do
            [[ $j -gt 0 ]] && out+=","
            out+=$(printf '{"url":"%s","priority":%d}' "$(rand_url)" "$((RANDOM%100))")
        done
        printf '%s]' "$out"
    }
    YCA_PROVIDERS_JSON=$(printf '{"think":%s,"build":%s,"tool":%s}' "$(mk)" "$(mk)" "$(mk)")
    providers_load; providers_detect
    for cx in high mid low think build tool "" garbage; do
        res=$(provider_resolve "$cx" 2>/dev/null) || continue
        url=$(printf '%s' "$res" | cut -f1)
        case "$url" in http://*) : ;; *) echo "FUZZ FAIL: bad url [$url] for [$cx] cfg=$YCA_PROVIDERS_JSON" >&2; exit 1 ;; esac
    done
done

echo "providers_body OK"
