#!/usr/bin/env bash
# Test: pubapi category — international public APIs (weather/stocks/flights/FX).
# Validation + gating are asserted strictly; network happy-paths are asserted
# LENIENTLY (online -> structured JSON; offline/rate-limited -> a clean error
# message) so CI stays green with or without connectivity.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
fail() { echo "FAIL: $*"; exit 1; }
export MCP_FLAGS="--enable pubapi --project $TMP"

# ── 1. Registration (safe/pubapi) ────────────────────────────────────────────
REG=$(registry_dump "$PROJ_ROOT")
for t in pubapi_weather pubapi_forecast pubapi_stock pubapi_fx pubapi_flight pubapi_book_search; do
    grep -q "^$t|safe|pubapi|" <<<"$REG" || fail "$t not registered as safe/pubapi"
done

# ── 2. Enable-gating: hidden until the category is enabled ────────────────────
DEF=$({ printf '%s\n' '{"jsonrpc":"2.0","id":"l0","method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}'
  printf '%s\n' '{"jsonrpc":"2.0","id":"l1","method":"tools/list","params":{}}'
  printf '%s\n' '{"jsonrpc":"2.0","method":"notifications/exit"}'
} | HARNESS_UPDATE_ENABLED=false timeout 30 bash "$HARNESS" --project "$TMP" 2>/dev/null \
  | jq -r 'select(.id=="l1").result.tools[]?.name' | grep -c '^pubapi_' || true)
[[ "$DEF" == "0" ]] || fail "pubapi tools visible without enabling ($DEF)"

# ── 3. Input validation — must reject cleanly (isError, no crash) ─────────────
out=$(mcp_call "$HARNESS" pubapi_fx '{"from":"XX","to":"EUR"}') && fail "fx accepted a bad currency"
grep -qi 'currency' <<<"$out" || fail "fx bad-currency message unexpected: $out"
out=$(mcp_call "$HARNESS" pubapi_stock '{"symbol":"bad;rm -rf"}') && fail "stock accepted a bad symbol"
grep -qi 'invalid symbol' <<<"$out" || fail "stock bad-symbol message unexpected: $out"
out=$(mcp_call "$HARNESS" pubapi_flight '{}') && fail "flight accepted no args"
grep -qiE 'icao24.*callsign' <<<"$out" || fail "flight no-arg message unexpected: $out"

# ── 4. Network happy-paths (lenient: data key OR a clean error phrase) ────────
netok() { # $1=tool $2=args $3=expected-key-on-success
    local o; o=$(mcp_call "$HARNESS" "$1" "$2" || true)
    [[ -n "$o" ]] || fail "$1 produced no output at all"
    grep -q "\"$3\"" <<<"$o" && return 0
    grep -qiE 'could not reach|offline|rate.?limit|no quote|no rate|no location|no live data|no data|no results' <<<"$o" \
        || fail "$1 neither returned data nor a clean error: $o"
}
netok pubapi_weather  '{"location":"Tokyo"}'             temperature_c
netok pubapi_forecast '{"location":"London","days":2}'   days
netok pubapi_stock    '{"symbol":"AAPL"}'                price
netok pubapi_fx       '{"from":"USD","to":"EUR"}'        rate
netok pubapi_flight   '{"icao24":"4b1806"}'              count
netok pubapi_book_search '{"query":"cache locality","limit":2}' total

# ── 5. Authenticated APIs (FingerprintJS / Bitly / Apify) ────────────────────
unset FPJS_API_KEY BITLY_TOKEN APIFY_TOKEN   # exercise the missing-key path deterministically
for spec in 'pubapi_fingerprint|safe' 'pubapi_bitly_clicks|safe' 'pubapi_apify_dataset|safe' \
            'pubapi_bitly_shorten|writes' 'pubapi_apify_run|writes'; do
    t="${spec%%|*}"; d="${spec#*|}"
    grep -q "^$t|$d|pubapi|" <<<"$REG" || fail "$t not registered as $d/pubapi"
done
# writes tools auto-deny without consent (-y)
out=$(mcp_call "$HARNESS" pubapi_bitly_shorten '{"url":"https://example.com"}') && fail "bitly_shorten ran without consent"
grep -qiE 'consent|confirm|auto-den' <<<"$out" || fail "bitly_shorten denial message unexpected: $out"
# safe auth tools: a clean 'set <ENV>' when the key is absent
out=$(mcp_call "$HARNESS" pubapi_fingerprint '{"request_id":"abc123"}' || true)
grep -qi 'set FPJS_API_KEY' <<<"$out" || fail "fingerprint missing-key message unexpected: $out"
out=$(mcp_call "$HARNESS" pubapi_bitly_clicks '{"bitlink":"bit.ly/x"}' || true)
grep -qi 'set BITLY_TOKEN' <<<"$out" || fail "bitly_clicks missing-key message unexpected: $out"
out=$(mcp_call "$HARNESS" pubapi_apify_dataset '{"dataset_id":"abc"}' || true)
grep -qi 'set APIFY_TOKEN' <<<"$out" || fail "apify_dataset missing-key message unexpected: $out"
# consented-but-keyless write -> clean 'set <ENV>'
out=$(mcp_call "$HARNESS" pubapi_apify_run '{"actor":"apify~web-scraper"}' y || true)
grep -qi 'set APIFY_TOKEN' <<<"$out" || fail "apify_run keyless message unexpected: $out"

echo "pubapi OK"
exit 0
