#!/usr/bin/env bash
# tests/test_scripts/capability_profiles_body.sh — T9 capability profiles, REAL test.
# Provider profiles (probed via a stubbed HTTP seam that counts calls) + host
# capability record. Asserts: every profile field; metered protection (ZERO
# probe traffic); config override beats probe; host record + fallbacks; doctor
# surfaces both. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null </dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=plain
YCA_CAT_ENABLED[core]=1
fail(){ echo "FAIL: $1"; exit 1; }

CALLS="$2/probe_calls"; : > "$CALLS"
# Stub the ONE HTTP seam: record every call, return canned engine responses.
_profile_curl() {
    printf '%s\n' "$3" >> "$CALLS"
    case "$3" in
        /api/show)        printf '%s' '{"model_info":{"llama.context_length":16384}}' ;;
        /chat/completions) printf '%s' '{"choices":[{"message":{"content":"{}"}}]}' ;;
    esac
}
ncalls(){ wc -l < "$CALLS" | tr -d ' '; }

# ── 1. Probed provider: every field populated from the stub ──────────────────
: > "$CALLS"; YCA_PROVIDER_PROFILE=()
YCA_PROVIDERS_JSON='{"think":[{"url":"http://live","model":"m"}],"build":[],"tool":[]}'
p=$(provider_profile_build "http://live" "m" "tok")
[[ "$(printf '%s' "$p" | jq -r '.context_window')" == "16384" ]] || fail "probed context_window wrong: $p"
[[ "$(printf '%s' "$p" | jq -r '.response_format')" == "yes" ]]  || fail "probed response_format wrong: $p"
[[ "$(printf '%s' "$p" | jq -r '.metered')" == "false" ]]        || fail "probed provider marked metered: $p"
[[ "$(ncalls)" -ge 1 ]] || fail "a non-metered provider was never probed"

# ── 2. METERED protection — the never-miss assertion: ZERO probe traffic ─────
: > "$CALLS"; YCA_PROVIDER_PROFILE=()
YCA_PROVIDERS_JSON='{"think":[{"url":"http://paid","probe":false,"context_window":8192}],"build":[],"tool":[]}'
provider_is_metered "http://paid" || fail "probe:false provider not detected as metered"
p=$(provider_profile_build "http://paid" "m" "tok")
[[ "$(ncalls)" == "0" ]] || fail "METERED provider received $(ncalls) probe request(s) — must be ZERO"
[[ "$(printf '%s' "$p" | jq -r '.metered')" == "true" ]] || fail "metered flag not set: $p"
[[ "$(printf '%s' "$p" | jq -r '.context_window')" == "8192" ]] || fail "metered ctx should come from config: $p"

# ── 3. Config override beats probed value ────────────────────────────────────
: > "$CALLS"; YCA_PROVIDER_PROFILE=()
YCA_PROVIDERS_JSON='{"think":[{"url":"http://ovr","model":"m","context_window":32000}],"build":[],"tool":[]}'
p=$(provider_profile_build "http://ovr" "m" "tok")
[[ "$(printf '%s' "$p" | jq -r '.context_window')" == "32000" ]] || fail "config context_window did not beat probe: $p"
# ctx was config-declared, so the /api/show probe must NOT have fired for it
grep -q '/api/show' "$CALLS" && fail "ctx probe fired despite a config-declared context_window"

# ── 4. Host capability record + fallbacks ────────────────────────────────────
YCA_MCP_SAMPLING=false YCA_MCP_ELICITATION=false YCA_MCP_ROOTS=false
rec=$(host_capability_record)
[[ "$(printf '%s' "$rec" | jq -r '.sampling')" == "false" ]] || fail "host record sampling wrong: $rec"
host_supports sampling    && fail "host_supports sampling true when off"
host_supports elicitation && fail "host_supports elicitation true when off"
# elicitation OFF -> a writes-class tool is denied and does NOT run (marker spy)
MARK="$2/cap_ran"; _cap_spy(){ touch "$MARK"; printf 'ran'; }
tool_register cap_spy _cap_spy '{"type":"object","properties":{}}' writes all core
rm -f "$MARK"; YCA_UI_MODE=mcp; YCA_AUTO_CONFIRM=false
out=$(tool_dispatch cap_spy '{}') || true
[[ ! -e "$MARK" ]] || fail "writes tool ran over MCP without elicitation (should deny)"
echo "$out" | grep -qi 'cancel\|confirm' || fail "no deny-with-explanation over MCP: $out"
YCA_UI_MODE=plain
# capabilities ON -> record reflects them
YCA_MCP_SAMPLING=true YCA_MCP_ELICITATION=true YCA_MCP_ROOTS=true
host_supports sampling    || fail "host_supports sampling false when on"
host_supports elicitation || fail "host_supports elicitation false when on"
[[ "$(host_capability_record | jq -r '.roots')" == "true" ]] || fail "host record roots not reflected"

# ── 5. doctor surfaces both profiles ─────────────────────────────────────────
YCA_MCP_SAMPLING=true YCA_MCP_ELICITATION=false YCA_MCP_ROOTS=false
YCA_PROVIDER_PROFILE=()
YCA_PROVIDERS_JSON='{"think":[{"url":"http://paid","probe":false}],"build":[],"tool":[]}'
: > "$CALLS"; doctor_profile_providers
[[ "$(ncalls)" == "0" ]] || fail "doctor probed a metered provider ($(ncalls) calls)"
pj=$(profiles_json)
[[ "$(printf '%s' "$pj" | jq -r '.host.sampling')" == "true" ]] || fail "doctor profiles missing host.sampling"
[[ "$(printf '%s' "$pj" | jq -r '.providers[0].url')" == "http://paid" ]] || fail "doctor profiles missing provider"
doctor_print_profiles | grep -q "http://paid" || fail "doctor_print_profiles omits the provider"

echo "capability_profiles_body OK"
exit 0
