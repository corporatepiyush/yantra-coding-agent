#!/usr/bin/env bash
# Test: the ytdl (YouTube / media downloader, yt-dlp) tool category — over MCP.
#
# Two tiers:
#   1. Structural + security tests that need NO network and NO yt-dlp:
#      registration, danger classification, schemas, category gating, the
#      consent gate on the write half, and the SSRF/URL guard (unit-tested
#      against the real _ytdl_url code path, deterministic offline because the
#      blocked ranges are lexical).
#   2. Dispatch-path behaviour that needs yt-dlp installed (arg guards); it makes
#      NO real download and NO network fetch to an external site.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
rm -f .harness.db
git init -q; git config user.email t@t; git config user.name t
echo a > a.txt; git add a.txt; git commit -qm init >/dev/null 2>&1
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

fail() { echo "FAIL: $*"; exit 1; }

ytdl() { MCP_FLAGS="--enable ytdl" mcp_call "$HARNESS" "ytdl_$1" "${2:-}" "${3:-}"; }
grep_ytdl() { local pat="$1" t="$2" a="${3:-}" y="${4:-}" o; o=$(ytdl "$t" "$a" "$y") || true; grep -qi -- "$pat" <<<"$o"; }

# ── 1. Registration ──────────────────────────────────────────────────────────
REG=$(registry_dump "$PROJ_ROOT")
EXPECTED="doctor info search download audio subtitles transcript llm_explain"
for t in $EXPECTED; do
    grep -q "^ytdl_${t}|" <<<"$REG" || fail "ytdl tool not registered: ytdl_${t}"
done
NYT=$(grep -c '|ytdl|' <<<"$REG")
[[ "$NYT" -ge 8 ]] || fail "ytdl registers only $NYT tools (expected >=8)"
mcp_wf "$HARNESS" tools.status '{}' y | grep -qi ytdl || fail "ytdl category missing from tools.status"

# ── 2. Danger classification (read = safe, download/write half = writes) ─────
for r in doctor info search llm_explain; do
    grep -q "^ytdl_${r}|safe|" <<<"$REG" || fail "ytdl_${r} should be danger=safe"
done
for w in download audio subtitles transcript; do
    grep -q "^ytdl_${w}|writes|" <<<"$REG" || fail "ytdl_${w} should be danger=writes (it fetches + writes files)"
done
grep -qE '^ytdl_llm_explain\|[a-z]+\|[a-z]+\|mid$' <<<"$REG" || fail "ytdl_llm_explain should be complexity=mid"

# ── 3. Schemas parse ─────────────────────────────────────────────────────────
BAD=$(YCA_DIR="$PROJ_ROOT" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  for n in "${!YCA_TOOL_SCHEMAS[@]}"; do
    [[ "$n" == ytdl_* ]] || continue
    printf "%s" "${YCA_TOOL_SCHEMAS[$n]}" | jq -e . >/dev/null 2>&1 || echo "$n"
  done')
[[ -z "$BAD" ]] || fail "ytdl schemas are not valid JSON: $BAD"

# ── 4. Category gating on the MCP dispatch path ──────────────────────────────
GATED=$(mcp_call "$HARNESS" ytdl_doctor '{}') && fail "ytdl_doctor should be gated when category is off"
grep -qi 'disabled' <<<"$GATED" || fail "gate message should say disabled: $GATED"

# ── 5. doctor always runs and names yt-dlp (works even when yt-dlp is absent) ─
DOC=$(ytdl doctor) || true
grep -qi 'yt-dlp' <<<"$DOC" || fail "ytdl doctor should mention yt-dlp: $DOC"

# ── 6. Consent gate on the write half (dispatch-level; no yt-dlp needed) ─────
# A writes tool with no -y is auto-denied BEFORE its function runs.
if ytdl download '{"url":"https://www.youtube.com/watch?v=x"}'; then
    fail "ytdl_download must be consent-gated (should fail without -y)"
fi
grep_ytdl 'confirmation\|cancelled' download '{"url":"https://www.youtube.com/watch?v=x"}' \
    || fail "ytdl_download without consent should return the deny message"

# ── 7. SSRF / URL guard — unit test the real _ytdl_url code path ─────────────
# Deterministic offline: loopback/link-local/private/metadata hosts are blocked
# lexically (no DNS), and a non-http scheme is refused by sanitize_url.
probe_url() {
    YCA_DIR="$PROJ_ROOT" YCA_TOOL_ARGS_JSON="$1" bash -c '
      set -u; export YCA_DIR YCA_TOOL_ARGS_JSON
      source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
      YCA_PROJECT_DIR="$PWD"; YCA_SAFETY_PATHS="$PWD"
      if out=$(_ytdl_url 2>&1); then printf "OK:%s" "$out"; else printf "REFUSED:%s" "$out"; fi'
}
for bad in \
    '{"url":"http://169.254.169.254/latest/meta-data"}' \
    '{"url":"http://localhost:9999/"}' \
    '{"url":"http://127.0.0.1/"}' \
    '{"url":"http://10.0.0.5/"}' \
    '{"url":"http://192.168.1.1/"}' \
    '{"url":"file:///etc/passwd"}' \
    '{"url":"not a url"}' ; do
    R=$(probe_url "$bad")
    [[ "$R" == REFUSED:* ]] || fail "_ytdl_url should REFUSE $bad — got: $R"
done
# A public http(s) URL is accepted (offline-safe: if DNS fails it returns nothing
# and the lexical floor lets a non-internal host through).
R=$(probe_url '{"url":"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}')
[[ "$R" == OK:https://www.youtube.com/* ]] || fail "_ytdl_url should ACCEPT a public URL — got: $R"

# ── 8. Black-box dispatch path via a STUBBED yt-dlp (deterministic everywhere) ─
# Shadow yt-dlp (and ffmpeg) with stubs that only record their argv. This lets us
# assert, without any network or real download: injection-blocking, that yt-dlp
# is NEVER invoked for a refused URL, and that every download carries the output-
# confinement flags (--restrict-filenames, -P <in-tree dir>, --no-playlist) and
# the URL as a single trailing argument.
LOG="$TMP/argv.log"
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
for b in yt-dlp ffmpeg; do
    cat > "$FAKE/$b" <<EOF
#!/usr/bin/env bash
{ printf 'CMD[%s]' "$b"; for a in "\$@"; do printf ' {%s}' "\$a"; done; printf '\n'; } >> "$LOG"
exit 0
EOF
    chmod +x "$FAKE/$b"
done
export PATH="$FAKE:$PATH"

# Arg guards now run deterministically (stub satisfies `command -v yt-dlp`).
grep_ytdl 'required' search '{}' || fail "ytdl_search should reject a missing query (schema validator)"
grep_ytdl 'query required' search '{"query":""}' || fail "ytdl_search should reject an empty query (in-function guard)"
grep_ytdl 'refusing\|internal' info '{"url":"http://127.0.0.1:1/"}' \
    || fail "ytdl_info should refuse an internal host end-to-end"

# (a) A normal download reaches yt-dlp with the confinement flags + url as one argv.
: > "$LOG"
ytdl download '{"url":"https://www.youtube.com/watch?v=abc"}' y >/dev/null || true
grep -q 'CMD\[yt-dlp\]' "$LOG" || fail "download did not invoke yt-dlp: $(cat "$LOG")"
for flag in '{--restrict-filenames}' '{--no-playlist}' '{--no-overwrites}' '{-P}'; do
    grep -qF "$flag" "$LOG" || fail "download missing confinement flag $flag: $(cat "$LOG")"
done
grep -qF '{https://www.youtube.com/watch?v=abc}' "$LOG" || fail "url should be a single trailing argv: $(cat "$LOG")"
grep -qE '\{-P\} \{[^}]*/downloads\}' "$LOG" || fail "output must be rooted at an in-tree downloads dir: $(cat "$LOG")"

# (b) An injection URL is refused by sanitize_url — yt-dlp is NEVER invoked.
: > "$LOG"; rm -f "$TMP/PWN"
OUT=$(ytdl download "{\"url\":\"https://youtube.com/\$(touch $TMP/PWN)\"}" y) || true
grep -qi 'invalid or unsafe' <<<"$OUT" || fail "injection URL should be rejected: $OUT"
[[ ! -e "$TMP/PWN" ]] || fail "SHELL INJECTION via ytdl url"
[[ ! -s "$LOG" ]] || fail "yt-dlp must NOT run for a rejected URL: $(cat "$LOG")"

# (c) An SSRF URL is refused before yt-dlp runs.
: > "$LOG"
OUT=$(ytdl download '{"url":"http://127.0.0.1/x"}' y) || true
grep -qi 'refusing\|internal' <<<"$OUT" || fail "SSRF URL should be refused: $OUT"
[[ ! -s "$LOG" ]] || fail "yt-dlp must NOT run for an SSRF URL: $(cat "$LOG")"

# (d) An out-of-tree dir is refused before yt-dlp runs.
: > "$LOG"
OUT=$(ytdl download '{"url":"https://youtube.com/x","dir":"/etc/evil"}' y) || true
grep -qi 'not allowed\|not creatable' <<<"$OUT" || fail "out-of-tree dir should be refused: $OUT"
[[ ! -s "$LOG" ]] || fail "yt-dlp must NOT run for a rejected dir: $(cat "$LOG")"

# (e) Playlist fan-out is capped at 50 regardless of the request.
: > "$LOG"
ytdl download '{"url":"https://youtube.com/x","playlist":true,"playlist_max":9999}' y >/dev/null || true
grep -qF '{--playlist-end} {50}' "$LOG" || fail "playlist_max must be capped to 50: $(cat "$LOG")"

# (f) search caps count at 20 and passes the query as one literal argv.
: > "$LOG"
ytdl search '{"query":"foo; rm -rf ~","count":999}' >/dev/null || true
grep -qF '{ytsearch20:foo; rm -rf ~}' "$LOG" || fail "search count must cap at 20 and keep the query intact: $(cat "$LOG")"

# (g) audio passes -x + the requested format (ffmpeg stubbed so it proceeds).
: > "$LOG"
ytdl audio '{"url":"https://youtube.com/x","audio_format":"m4a"}' y >/dev/null || true
grep -qF '{-x}' "$LOG" && grep -qF '{m4a}' "$LOG" || fail "audio should pass -x and the audio format: $(cat "$LOG")"

echo "ytdl OK (structural + SSRF unit + stubbed-yt-dlp black-box)"
exit 0
