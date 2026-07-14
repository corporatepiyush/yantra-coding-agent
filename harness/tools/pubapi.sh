# tools/pubapi.sh — International public APIs (keyless by default).
#
# Value over a raw curl (which the bash tool can already run): the correct
# endpoint + params are encoded, user input is validated + percent-encoded, and
# the messy upstream response (nested JSON, CSV, OpenSky positional arrays) is
# shaped into clean, model-ready JSON. All read-only (safe). Opt-in via
# `tools enable pubapi`.
#
# Network goes through curl_web (bounded + http(s)-pinned) — deliberately NOT
# http_get, which attaches the LLM Authorization bearer that must never leak to a
# third-party API. Hosts are hardcoded (no SSRF surface); only query params vary.
#
# Sources (no API key required): Open-Meteo (weather), Stooq (stock quotes),
# Frankfurter/ECB (FX), OpenSky Network (live flights, anonymous + rate-limited).

_pubapi_need() { doctor_check_needs "curl jq" || return 1; }
_pubapi_get()  { curl_web --max-time 20 "$1"; }   # body on stdout; rc propagates

# WMO weather interpretation code -> text (Open-Meteo current/daily weather_code).
_pubapi_wmo() {
    case "$1" in
        0) printf 'Clear sky' ;; 1) printf 'Mainly clear' ;; 2) printf 'Partly cloudy' ;; 3) printf 'Overcast' ;;
        45|48) printf 'Fog' ;; 51|53|55) printf 'Drizzle' ;; 56|57) printf 'Freezing drizzle' ;;
        61|63|65) printf 'Rain' ;; 66|67) printf 'Freezing rain' ;; 71|73|75) printf 'Snow' ;; 77) printf 'Snow grains' ;;
        80|81|82) printf 'Rain showers' ;; 85|86) printf 'Snow showers' ;; 95) printf 'Thunderstorm' ;; 96|99) printf 'Thunderstorm with hail' ;;
        *) printf 'Unknown' ;;
    esac
}

# Geocode a place name -> "lat lon name country" (one line), or empty on miss.
_pubapi_geocode() {
    local enc body; enc=$(url_encode "$1")
    body=$(_pubapi_get "https://geocoding-api.open-meteo.com/v1/search?name=${enc}&count=1&language=en&format=json") || return 1
    printf '%s' "$body" | jq -r '.results[0] | select(.) | "\(.latitude) \(.longitude) \(.name) \(.country // "")"' 2>/dev/null
}

# pubapi_weather — current conditions for a place name.
tool_pubapi_weather() {
    _pubapi_need || return 1
    local loc; loc=$(tool_arg location)
    [[ -z "$loc" ]] && { printf 'location required (a place name, e.g. "Tokyo")'; return 1; }
    local geo; geo=$(_pubapi_geocode "$loc") || { printf 'could not reach the geocoding API (offline?)'; return 1; }
    [[ -z "$geo" ]] && { printf 'no location found for "%s"' "$loc"; return 1; }
    local lat lon name country; read -r lat lon name country <<< "$geo"
    local body; body=$(_pubapi_get "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,weather_code,wind_speed_10m,wind_direction_10m&wind_speed_unit=kmh&timezone=auto") \
        || { printf 'could not reach the weather API (offline?)'; return 1; }
    local code cond; code=$(printf '%s' "$body" | jq -r '.current.weather_code // empty' 2>/dev/null); cond=$(_pubapi_wmo "${code:-x}")
    printf '%s' "$body" | jq -c --arg name "$name" --arg country "$country" --arg cond "$cond" '
        { location:$name, country:$country, time:.current.time, conditions:$cond,
          temperature_c:.current.temperature_2m, feels_like_c:.current.apparent_temperature,
          humidity_pct:.current.relative_humidity_2m, precipitation_mm:.current.precipitation,
          wind_kmh:.current.wind_speed_10m, wind_dir_deg:.current.wind_direction_10m }' 2>/dev/null \
        || printf 'weather lookup failed to parse'
}

# pubapi_forecast — multi-day daily forecast for a place name.
tool_pubapi_forecast() {
    _pubapi_need || return 1
    local loc days; loc=$(tool_arg location); days=$(tool_arg days 3)
    [[ -z "$loc" ]] && { printf 'location required (a place name)'; return 1; }
    [[ "$days" =~ ^[0-9]+$ ]] || days=3; (( days < 1 )) && days=1; (( days > 16 )) && days=16
    local geo; geo=$(_pubapi_geocode "$loc") || { printf 'could not reach the geocoding API (offline?)'; return 1; }
    [[ -z "$geo" ]] && { printf 'no location found for "%s"' "$loc"; return 1; }
    local lat lon name country; read -r lat lon name country <<< "$geo"
    local body; body=$(_pubapi_get "https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_sum&forecast_days=${days}&timezone=auto") \
        || { printf 'could not reach the weather API (offline?)'; return 1; }
    # Map each day's code to text in-shell, then let jq zip the daily arrays.
    local codes conds=""; codes=$(printf '%s' "$body" | jq -r '.daily.weather_code[]?' 2>/dev/null)
    while IFS= read -r c; do [[ -z "$c" ]] && continue; conds+="$(_pubapi_wmo "$c")"$'\n'; done <<< "$codes"
    printf '%s' "$body" | jq -c --arg name "$name" --arg country "$country" --rawfile conds <(printf '%s' "$conds") '
        ($conds | rtrimstr("\n") | split("\n")) as $cs |
        { location:$name, country:$country,
          days: [ range(0; (.daily.time|length)) as $i |
            { date: .daily.time[$i], conditions: ($cs[$i] // "Unknown"),
              high_c: .daily.temperature_2m_max[$i], low_c: .daily.temperature_2m_min[$i],
              precip_mm: .daily.precipitation_sum[$i] } ] }' 2>/dev/null \
        || printf 'forecast lookup failed to parse'
}

# pubapi_stock — latest quote for a ticker via Yahoo Finance's keyless chart
# endpoint. Plain symbols (AAPL, MSFT), indices use ^ (^GSPC), crypto e.g. BTC-USD.
tool_pubapi_stock() {
    _pubapi_need || return 1
    local sym; sym=$(tool_arg symbol)
    [[ -z "$sym" ]] && { printf 'symbol required (e.g. AAPL, MSFT, ^GSPC, BTC-USD)'; return 1; }
    [[ "$sym" =~ ^[A-Za-z0-9.^=-]{1,20}$ ]] || { printf 'invalid symbol'; return 1; }
    local enc body; enc=$(url_encode "$sym")
    body=$(_pubapi_get "https://query1.finance.yahoo.com/v8/finance/chart/${enc}?range=1d&interval=1d") \
        || { printf 'could not reach the market-data API (offline?)'; return 1; }
    printf '%s' "$body" | jq -e '.chart.result[0].meta.regularMarketPrice' >/dev/null 2>&1 \
        || { printf 'no quote for "%s" (unknown symbol? indices use ^ e.g. ^GSPC; crypto e.g. BTC-USD)' "$sym"; return 1; }
    printf '%s' "$body" | jq -c '
        def r2: (. * 100 | round) / 100;
        .chart.result[0].meta as $m | {
          symbol: $m.symbol, price: $m.regularMarketPrice, currency: $m.currency,
          exchange: $m.exchangeName, previous_close: $m.chartPreviousClose,
          change: (($m.regularMarketPrice - $m.chartPreviousClose) | r2),
          change_pct: ((($m.regularMarketPrice - $m.chartPreviousClose) / $m.chartPreviousClose * 100) | r2),
          day_high: $m.regularMarketDayHigh, day_low: $m.regularMarketDayLow,
          volume: $m.regularMarketVolume, time: ($m.regularMarketTime // 0), source: "yahoo" }' 2>/dev/null \
        || printf 'stock lookup failed to parse'
}

# pubapi_fx — currency exchange rate (ECB reference rates via Frankfurter, keyless).
tool_pubapi_fx() {
    _pubapi_need || return 1
    local from to amount; from=$(tool_arg from); to=$(tool_arg to); amount=$(tool_arg amount 1)
    [[ "$from" =~ ^[A-Za-z]{3}$ && "$to" =~ ^[A-Za-z]{3}$ ]] || { printf 'from and to must be 3-letter currency codes (e.g. USD, EUR)'; return 1; }
    [[ "$amount" =~ ^[0-9]+(\.[0-9]+)?$ ]] || amount=1
    from=$(printf '%s' "$from" | tr '[:lower:]' '[:upper:]'); to=$(printf '%s' "$to" | tr '[:lower:]' '[:upper:]')
    local body; body=$(_pubapi_get "https://api.frankfurter.dev/v1/latest?base=${from}&symbols=${to}") \
        || { printf 'could not reach the FX API (offline?)'; return 1; }
    printf '%s' "$body" | jq -e --arg to "$to" '.rates[$to]' >/dev/null 2>&1 \
        || { printf 'no rate for %s->%s (unsupported currency? ECB set is fiat only — no crypto)' "$from" "$to"; return 1; }
    printf '%s' "$body" | jq -c --arg from "$from" --arg to "$to" --argjson amount "$amount" '
        def r4: (. * 10000 | round) / 10000;
        .rates[$to] as $rate | { from:$from, to:$to, amount:$amount, rate:($rate|r4),
          converted:(($rate * $amount) | r4), date:.date, source:"ECB/Frankfurter" }' 2>/dev/null \
        || printf 'fx lookup failed to parse'
}

# pubapi_flight — live position for an aircraft via OpenSky (keyless, anonymous
# rate limits apply). Query by icao24 (24-bit hex transponder id) — the reliable
# keyless key — or best-effort by callsign. Flight-NUMBER lookup needs a paid API.
tool_pubapi_flight() {
    _pubapi_need || return 1
    local icao24 callsign; icao24=$(tool_arg icao24); callsign=$(tool_arg callsign)
    local url filter='.states'
    if [[ -n "$icao24" ]]; then
        [[ "$icao24" =~ ^[0-9a-fA-F]{6}$ ]] || { printf 'icao24 must be 6 hex chars (e.g. 4b1806)'; return 1; }
        url="https://opensky-network.org/api/states/all?icao24=$(printf '%s' "$icao24" | tr '[:upper:]' '[:lower:]')"
    elif [[ -n "$callsign" ]]; then
        [[ "$callsign" =~ ^[A-Za-z0-9_-]{1,12}$ ]] || { printf 'invalid callsign'; return 1; }
        url="https://opensky-network.org/api/states/all"
        filter=".states // [] | map(select((.[1] // \"\") | ascii_upcase | gsub(\" \";\"\") == (\"$callsign\" | ascii_upcase)))"
    else
        printf 'provide icao24 (6 hex) or callsign'; return 1
    fi
    local body; body=$(_pubapi_get "$url") || { printf 'could not reach OpenSky (offline or rate-limited — anonymous access is throttled)'; return 1; }
    local states; states=$(printf '%s' "$body" | jq -c "$filter" 2>/dev/null)
    [[ -z "$states" || "$states" == "null" || "$states" == "[]" ]] && { printf 'no live data (aircraft not airborne, or OpenSky rate-limited)'; return 1; }
    printf '%s' "$states" | jq -c 'map({
        icao24: .[0], callsign: ((.[1] // "") | gsub(" +$";"")), country: .[2],
        longitude: .[5], latitude: .[6], baro_altitude_m: .[7], on_ground: .[8],
        velocity_ms: .[9], heading_deg: .[10], geo_altitude_m: .[13] }) | {count:length, aircraft:.}' 2>/dev/null \
        || printf 'flight lookup failed to parse'
}

# pubapi_book_search — full-text search INSIDE digitized books (OpenLibrary /
# Internet Archive "search inside"). Keyless. Returns matching books with the
# highlighted snippet ({{{term}}} markers normalised to «term») + a read URL.
tool_pubapi_book_search() {
    _pubapi_need || return 1
    local q limit; q=$(tool_arg query); limit=$(tool_arg limit 10)
    [[ -z "$q" ]] && { printf 'query required (text to find inside books)'; return 1; }
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=10; (( limit < 1 )) && limit=1; (( limit > 50 )) && limit=50
    local body; body=$(_pubapi_get "https://openlibrary.org/search/inside.json?q=$(url_encode "$q")") \
        || { printf 'could not reach OpenLibrary (offline?)'; return 1; }
    printf '%s' "$body" | jq -e '.hits.hits' >/dev/null 2>&1 \
        || { printf 'no results (or unexpected response) for "%s"' "$q"; return 1; }
    printf '%s' "$body" | jq -c --arg q "$q" --argjson lim "$limit" '
        def clean: (. // "") | gsub("\\{\\{\\{";"«") | gsub("\\}\\}\\}";"»") | gsub("\\s+";" ") | gsub("^ | $";"");
        { query: $q,
          total: (.hits.total.value? // .hits.total // (.hits.hits|length)),
          results: [ .hits.hits[:$lim][] | (.fields.identifier[0] // (._id|split("|")[0])) as $id | {
            title: (.fields.meta_title[0] // $id),
            author: (.fields.meta_creator[0] // null),
            year: (.fields.meta_year[0] // null),
            archive_id: $id,
            page: (.fields.page_num[0][0]? // null),
            read_url: ("https://archive.org/details/" + ($id // "")),
            snippet: (.highlight.text[0] // "" | clean) } ] }' 2>/dev/null \
        || printf 'book search failed to parse'
}

# ── Authenticated public APIs (an API key in the environment is required) ─────
# The secret is passed via a header FILE (-H @<(...)), NEVER on the curl argv:
# argv is world-readable through `ps`, so a key on the command line leaks to every
# local process. Same rule the harness enforces for the LLM bearer token.
_pubapi_auth_get() {   # url  header-name  secret
    curl_web --max-time 20 --fail-with-body "$1" -H @<(printf '%s: %s\n' "$2" "$3")
}
_pubapi_auth_post() {  # url  header-name  secret  json-body
    curl_web --max-time 30 --fail-with-body -X POST -H 'Content-Type: application/json' \
        -H @<(printf '%s: %s\n' "$2" "$3") --data-binary @<(printf '%s' "$4") "$1"
}

# pubapi_fingerprint — FingerprintJS Pro Server API: retrieve device-intelligence
# for a request_id (one identification event) or a visitor_id (visit history).
# Read-only. Needs FPJS_API_KEY (Server API secret); region via FPJS_REGION (us|eu|ap).
tool_pubapi_fingerprint() {
    _pubapi_need || return 1
    local key="${FPJS_API_KEY:-}"
    [[ -z "$key" ]] && { printf 'set FPJS_API_KEY (Fingerprint Pro Server API secret — dashboard.fingerprint.com)'; return 1; }
    local req vis; req=$(tool_arg request_id); vis=$(tool_arg visitor_id)
    local base; case "${FPJS_REGION:-us}" in eu) base="https://eu.api.fpjs.io" ;; ap) base="https://ap.api.fpjs.io" ;; *) base="https://api.fpjs.io" ;; esac
    local url
    if [[ -n "$req" ]]; then
        [[ "$req" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { printf 'invalid request_id'; return 1; }
        url="$base/events/$(url_encode "$req")"
    elif [[ -n "$vis" ]]; then
        [[ "$vis" =~ ^[A-Za-z0-9]{1,40}$ ]] || { printf 'invalid visitor_id'; return 1; }
        url="$base/visitors/$(url_encode "$vis")?limit=10"
    else
        printf 'provide request_id (one event) or visitor_id (visit history)'; return 1
    fi
    local resp; resp=$(_pubapi_auth_get "$url" "Auth-API-Key" "$key")
    [[ -z "$resp" ]] && { printf 'could not reach Fingerprint (offline or auth failed)'; return 1; }
    printf '%s' "$resp" | jq -e 'has("error") or has("errors")' >/dev/null 2>&1 \
        && { printf 'Fingerprint API error: %s' "$(printf '%s' "$resp" | jq -c '.error // .errors' 2>/dev/null | head -c 200)"; return 1; }
    printf '%s' "$resp" | jq -c . 2>/dev/null || printf '%s' "$resp"
}

# pubapi_bitly_shorten — shorten a long URL via Bitly (creates a link → writes).
# Needs BITLY_TOKEN (dev.bitly.com generic access token).
tool_pubapi_bitly_shorten() {
    _pubapi_need || return 1
    local tok="${BITLY_TOKEN:-}"
    [[ -z "$tok" ]] && { printf 'set BITLY_TOKEN (dev.bitly.com → generic access token)'; return 1; }
    local url; url=$(tool_arg url)
    [[ "$url" =~ ^https?://[^[:space:]]+$ ]] || { printf 'url must be a valid http(s) URL to shorten'; return 1; }
    local resp; resp=$(_pubapi_auth_post "https://api-ssl.bitly.com/v4/shorten" "Authorization" "Bearer $tok" "$(jq -cn --arg u "$url" '{long_url:$u}')")
    [[ -z "$resp" ]] && { printf 'could not reach Bitly (offline?)'; return 1; }
    printf '%s' "$resp" | jq -e '.link' >/dev/null 2>&1 \
        || { printf 'Bitly error: %s' "$(printf '%s' "$resp" | jq -r '.message // .description // .' 2>/dev/null | head -c 200)"; return 1; }
    printf '%s' "$resp" | jq -c '{short_url:.link, id:.id, long_url:.long_url, created_at:.created_at}'
}

# pubapi_bitly_clicks — total click metrics for a bitlink (read-only). Needs BITLY_TOKEN.
tool_pubapi_bitly_clicks() {
    _pubapi_need || return 1
    local tok="${BITLY_TOKEN:-}"
    [[ -z "$tok" ]] && { printf 'set BITLY_TOKEN'; return 1; }
    local bl; bl=$(tool_arg bitlink); bl="${bl#http://}"; bl="${bl#https://}"
    [[ "$bl" =~ ^[A-Za-z0-9._/-]{1,120}$ ]] || { printf 'bitlink required (e.g. bit.ly/3abcXYZ)'; return 1; }
    # bl is validated to safe chars only — inserted directly so its '/' stays literal.
    local resp; resp=$(_pubapi_auth_get "https://api-ssl.bitly.com/v4/bitlinks/${bl}/clicks/summary" "Authorization" "Bearer $tok")
    [[ -z "$resp" ]] && { printf 'could not reach Bitly (offline?)'; return 1; }
    printf '%s' "$resp" | jq -e '.total_clicks' >/dev/null 2>&1 \
        || { printf 'Bitly error: %s' "$(printf '%s' "$resp" | jq -r '.message // .description // .' 2>/dev/null | head -c 200)"; return 1; }
    printf '%s' "$resp" | jq -c --arg bl "$bl" '{bitlink:$bl, total_clicks:.total_clicks, unit:.unit, units:.units, unit_reference:.unit_reference}'
}

# pubapi_apify_run — start an Apify actor run (executes a scraper — consumes
# compute on your Apify account → writes/consent-gated). Returns run + dataset id.
# Needs APIFY_TOKEN.
tool_pubapi_apify_run() {
    _pubapi_need || return 1
    local tok="${APIFY_TOKEN:-}"
    [[ -z "$tok" ]] && { printf 'set APIFY_TOKEN (console.apify.com → Settings → Integrations)'; return 1; }
    local actor input; actor=$(tool_arg actor); input=$(tool_arg input)
    [[ "$actor" =~ ^[A-Za-z0-9~_.-]{1,120}$ ]] || { printf 'actor required: an actorId or username~actor-name (e.g. apify~web-scraper)'; return 1; }
    [[ -z "$input" ]] && input='{}'
    printf '%s' "$input" | jq -e . >/dev/null 2>&1 || { printf 'input must be valid JSON (the actor input object)'; return 1; }
    local resp; resp=$(_pubapi_auth_post "https://api.apify.com/v2/acts/${actor}/runs" "Authorization" "Bearer $tok" "$input")
    [[ -z "$resp" ]] && { printf 'could not reach Apify (offline?)'; return 1; }
    printf '%s' "$resp" | jq -e '.data.id' >/dev/null 2>&1 \
        || { printf 'Apify error: %s' "$(printf '%s' "$resp" | jq -r '.error.message // .error // .' 2>/dev/null | head -c 200)"; return 1; }
    printf '%s' "$resp" | jq -c '.data | {run_id:.id, actor:.actId, status:.status, dataset_id:.defaultDatasetId, started:.startedAt}'
}

# pubapi_apify_dataset — fetch items from an Apify dataset (a run's results).
# Read-only, bounded by limit (default 100, max 1000). Needs APIFY_TOKEN.
tool_pubapi_apify_dataset() {
    _pubapi_need || return 1
    local tok="${APIFY_TOKEN:-}"
    [[ -z "$tok" ]] && { printf 'set APIFY_TOKEN'; return 1; }
    local ds limit; ds=$(tool_arg dataset_id); limit=$(tool_arg limit 100)
    [[ "$ds" =~ ^[A-Za-z0-9_-]{1,60}$ ]] || { printf 'dataset_id required (a run'"'"'s dataset_id / defaultDatasetId)'; return 1; }
    [[ "$limit" =~ ^[0-9]+$ ]] || limit=100; (( limit > 1000 )) && limit=1000
    local resp; resp=$(_pubapi_auth_get "https://api.apify.com/v2/datasets/${ds}/items?clean=true&limit=${limit}" "Authorization" "Bearer $tok")
    [[ -z "$resp" ]] && { printf 'could not reach Apify (offline?)'; return 1; }
    printf '%s' "$resp" | jq -e 'type=="array"' >/dev/null 2>&1 \
        || { printf 'Apify error: %s' "$(printf '%s' "$resp" | jq -r '.error.message // .error // .' 2>/dev/null | head -c 200)"; return 1; }
    printf '%s' "$resp" | jq -c '{count:length, items:.}'
}

tool_register "pubapi_weather"   tool_pubapi_weather   '{"type":"object","properties":{"location":{"type":"string","description":"place name, e.g. \"Tokyo\" or \"Paris, France\""}},"required":["location"]}' safe all pubapi
tool_register "pubapi_forecast"  tool_pubapi_forecast  '{"type":"object","properties":{"location":{"type":"string","description":"place name"},"days":{"type":"integer","description":"number of days (1-16, default 3)"}},"required":["location"]}' safe all pubapi
tool_register "pubapi_stock"     tool_pubapi_stock     '{"type":"object","properties":{"symbol":{"type":"string","description":"ticker: plain symbol (AAPL, MSFT), indices use ^ (^GSPC), crypto e.g. BTC-USD"}},"required":["symbol"]}' safe all pubapi
tool_register "pubapi_fx"        tool_pubapi_fx        '{"type":"object","properties":{"from":{"type":"string","description":"source currency, 3-letter code (USD)"},"to":{"type":"string","description":"target currency, 3-letter code (EUR)"},"amount":{"type":"number","description":"amount to convert (default 1)"}},"required":["from","to"]}' safe all pubapi
tool_register "pubapi_flight"    tool_pubapi_flight    '{"type":"object","properties":{"icao24":{"type":"string","description":"24-bit hex transponder id (e.g. 4b1806) — the reliable keyless lookup"},"callsign":{"type":"string","description":"flight callsign (best-effort), e.g. UAL123"}}}' safe all pubapi
tool_register "pubapi_book_search" tool_pubapi_book_search '{"type":"object","properties":{"query":{"type":"string","description":"text to search for INSIDE books full text (quote for a phrase)"},"limit":{"type":"integer","description":"max results (default 10, max 50)"}},"required":["query"]}' safe all pubapi
# Authenticated (env-var API keys): FingerprintJS Pro, Bitly, Apify.
tool_register "pubapi_fingerprint"    tool_pubapi_fingerprint    '{"type":"object","properties":{"request_id":{"type":"string","description":"a single identification event id (FingerprintJS requestId)"},"visitor_id":{"type":"string","description":"a visitor id — returns visit history"}}}' safe all pubapi
tool_register "pubapi_bitly_shorten"  tool_pubapi_bitly_shorten  '{"type":"object","properties":{"url":{"type":"string","description":"the long http(s) URL to shorten"}},"required":["url"]}' writes all pubapi
tool_register "pubapi_bitly_clicks"   tool_pubapi_bitly_clicks   '{"type":"object","properties":{"bitlink":{"type":"string","description":"a bitlink id, e.g. bit.ly/3abcXYZ (scheme optional)"}},"required":["bitlink"]}' safe all pubapi
tool_register "pubapi_apify_run"      tool_pubapi_apify_run      '{"type":"object","properties":{"actor":{"type":"string","description":"actorId or username~actor-name (e.g. apify~web-scraper)"},"input":{"type":"string","description":"actor input as a JSON object string (default {})"}},"required":["actor"]}' writes all pubapi
tool_register "pubapi_apify_dataset"  tool_pubapi_apify_dataset  '{"type":"object","properties":{"dataset_id":{"type":"string","description":"an Apify dataset id (a run'"'"'s defaultDatasetId)"},"limit":{"type":"integer","description":"max items (default 100, max 1000)"}},"required":["dataset_id"]}' safe all pubapi
