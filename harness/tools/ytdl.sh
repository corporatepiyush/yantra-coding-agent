# tools/ytdl.sh — YouTube (and 1000+ other sites) media downloader, via yt-dlp.
# Same "shell out to a proven binary" discipline as media/opencv: yt-dlp does the
# fetching/format-negotiation, this file adds the harness guarantees around it —
# a validated http(s) URL, an SSRF pre-check on the host (reusing browse's
# resolve-and-vet helpers), output confined to a fenced in-tree directory with
# ASCII-restricted filenames, a playlist cap so one URL can't pull 500 videos,
# and consent on everything that writes to disk or reaches the network to fetch.
#
# Read half (safe): doctor / info / formats / subs_list / search — metadata only,
#   no file is written.
# Act half (gated `writes`): download / audio / subtitles / thumbnail / transcript
#   — these fetch bytes and write files, so they need consent (and on the MCP
#   surface run only under -y).

# ── Guards / helpers ─────────────────────────────────────────────────────────
_ytdl_bin() { command -v yt-dlp 2>/dev/null; }

_ytdl_need() {
    _ytdl_bin >/dev/null || {
        printf 'yt-dlp not installed.\ninstall: brew install yt-dlp   /   pip install -U yt-dlp   /   apt install yt-dlp'
        return 1
    }
}

# _ytdl_url -> the validated, SSRF-vetted URL from .url, or fail with a message.
# Enforces http(s) + no shell metacharacters (sanitize_url), then blocks the host
# lexically AND after resolution (reusing browse's SSRF trio) so a public-looking
# name that resolves to 169.254.169.254 / a private range is refused. yt-dlp does
# its own networking, so this is a best-effort pre-flight, not a pinned connect.
_ytdl_url() {
    local raw url host; raw=$(tool_arg url)
    [[ -n "$raw" ]] || { printf 'url required'; return 1; }
    url=$(sanitize_url "$raw") || { printf 'invalid or unsafe url (http/https only, no shell metacharacters)'; return 1; }
    host=$(_browse_url_host "$url")
    _browse_blocked_host "$host" && { printf 'refusing to fetch an internal/loopback/metadata host'; return 1; }
    local ip; while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        _browse_ip_internal "$ip" && { printf 'refusing: host resolves to an internal/loopback/metadata address (SSRF)'; return 1; }
    done < <(_browse_resolve "$host")
    printf '%s' "$url"
}

# _ytdl_outdir -> a fenced, existing, in-tree download directory (from .dir, else
# <project>/downloads). Every write tool routes output here.
_ytdl_outdir() {
    local dir; dir=$(tool_arg dir "${YCA_PROJECT_DIR}/downloads")
    path_check_allowed "$dir" 2>/dev/null || { printf ''; return 1; }
    path_ensure_dir "$dir" 2>/dev/null || { printf ''; return 1; }
    printf '%s' "$dir"
}

# _ytdl_playlist_args -> the playlist flags. Default is --no-playlist; opt in with
# .playlist=true, still capped by .playlist_max (default 10, hard ceiling 50) so a
# single call can never fan out into an unbounded download.
_ytdl_playlist_args() {
    local -n _out=$1
    if [[ "$(tool_arg playlist false)" == "true" ]]; then
        local n; n=$(int_guard "$(tool_arg playlist_max 10)" 10); (( n < 1 )) && n=1; (( n > 50 )) && n=50
        _out=(--yes-playlist --playlist-end "$n")
    else
        _out=(--no-playlist)
    fi
}

# ── doctor — is yt-dlp present, and is ffmpeg there for audio/merge? ─────────
tool_ytdl_doctor() {
    local out=""
    if _ytdl_bin >/dev/null; then
        out+="yt-dlp: ok  ($(yt-dlp --version 2>/dev/null))\n"
    else
        out+="yt-dlp: MISSING — install: brew install yt-dlp  /  pip install -U yt-dlp\n"
    fi
    if command -v ffmpeg &>/dev/null; then
        out+="ffmpeg: ok  (needed to extract audio and to merge separate video+audio streams)\n"
    else
        out+="ffmpeg: MISSING — audio extraction and best-quality merges need it: brew install ffmpeg\n"
    fi
    out+="download dir: ${YCA_PROJECT_DIR}/downloads (override per call with .dir)\n"
    printf '%b' "$out"
}

# ── info — metadata for a URL WITHOUT downloading. Read-only. ────────────────
tool_ytdl_info() {
    _ytdl_need || return 1
    local url; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    yt-dlp -J --no-playlist --no-warnings "$url" 2>/dev/null | jq '{
        title, id, uploader, channel, duration_string, upload_date,
        view_count, like_count, is_live, webpage_url,
        formats: (.formats | length), thumbnail, description: (.description[0:500])
    }' 2>/dev/null || { printf 'could not fetch metadata (is the URL valid and public?)'; return 1; }
}

# ── search — top N results for a query (metadata only, no download). ─────────
tool_ytdl_search() {
    _ytdl_need || return 1
    local q n; q=$(tool_arg query)
    [[ -n "$q" ]] || { printf 'query required'; return 1; }
    [[ "$q" == *$'\n'* ]] && { printf 'query must be a single line'; return 1; }
    n=$(int_guard "$(tool_arg count 5)" 5); (( n < 1 )) && n=1; (( n > 20 )) && n=20
    # "ytsearchN:QUERY" is passed as ONE argv — never a shell string — so the
    # query cannot inject anything regardless of its bytes.
    yt-dlp -J --flat-playlist --no-warnings "ytsearch${n}:${q}" 2>/dev/null \
        | jq '[.entries[]? | {title, id, url, uploader: .uploader, duration: .duration}]' 2>/dev/null \
        || { printf 'search failed (yt-dlp could not reach the search backend)'; return 1; }
}

# _ytdl_rel — rewrite absolute in-project paths to project-relative ones, so a
# model can feed a download result STRAIGHT into media_convert/read/etc. (which
# resolve relative to the project). yt-dlp prints an absolute filepath; a small
# model then tends to pass just the basename (dropping downloads/) and the next
# tool can't find it. Literal-prefix strip (no regex on the path).
_ytdl_rel() { awk -v pfx="${YCA_PROJECT_DIR}/" 'index($0,pfx)==1{$0=substr($0,length(pfx)+1)} 1'; }

# ── download — fetch the video (best, or a chosen quality/format). Gated. ────
tool_ytdl_download() {
    _ytdl_need || return 1
    local url dir; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    dir=$(_ytdl_outdir) || { printf 'download dir not allowed / not creatable (check .dir)'; return 1; }
    # Quality selection: .format (a raw yt-dlp -f expression) wins; else .quality
    # as a max height (e.g. 720) → best video ≤ that height + best audio.
    local fmt qual selector; fmt=$(tool_arg format ""); qual=$(tool_arg quality "")
    if [[ -n "$fmt" && "$fmt" != "null" ]]; then selector="$fmt"
    elif [[ "$qual" =~ ^[0-9]+$ ]]; then selector="bv*[height<=${qual}]+ba/b[height<=${qual}]"
    else selector="bv*+ba/b"; fi
    local -a plist; _ytdl_playlist_args plist
    confirm_action "Download video from $url to $dir" "yt-dlp -f '$selector' -> $dir" || { confirm_denied_msg; return 1; }
    local out
    out=$(yt-dlp -f "$selector" "${plist[@]}" --restrict-filenames --no-overwrites --no-progress \
             -P "$dir" -o '%(title).150B.%(ext)s' --no-simulate --print after_move:filepath "$url" 2>&1) || {
        printf 'download failed:\n%s' "$(printf '%s' "$out" | tail -8)"; return 1; }
    local files; files=$(printf '%s' "$out" | grep -E "^${dir}/" | _ytdl_rel || true)
    [[ -n "$files" ]] && printf 'downloaded:\n%s' "$files" \
        || printf 'download finished (in %s):\n%s' "$dir" "$(printf '%s' "$out" | tail -8)"
}

# ── audio — download and extract audio to mp3/m4a/opus/… (needs ffmpeg). ─────
tool_ytdl_audio() {
    _ytdl_need || return 1
    command -v ffmpeg &>/dev/null || { printf 'audio extraction needs ffmpeg: brew install ffmpeg'; return 1; }
    local url dir afmt; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    dir=$(_ytdl_outdir) || { printf 'download dir not allowed / not creatable (check .dir)'; return 1; }
    afmt=$(tool_arg audio_format mp3)
    case "$afmt" in mp3|m4a|opus|aac|flac|wav|vorbis) ;; *) printf 'audio_format must be one of: mp3 m4a opus aac flac wav vorbis'; return 1 ;; esac
    local -a plist; _ytdl_playlist_args plist
    confirm_action "Download audio ($afmt) from $url to $dir" "yt-dlp -x --audio-format $afmt -> $dir" || { confirm_denied_msg; return 1; }
    local out
    out=$(yt-dlp -x --audio-format "$afmt" --audio-quality 0 "${plist[@]}" --restrict-filenames --no-overwrites \
             --no-progress -P "$dir" -o '%(title).150B.%(ext)s' --no-simulate --print after_move:filepath "$url" 2>&1) || {
        printf 'audio download failed:\n%s' "$(printf '%s' "$out" | tail -8)"; return 1; }
    local files; files=$(printf '%s' "$out" | grep -E "^${dir}/" | _ytdl_rel || true)
    [[ -n "$files" ]] && printf 'audio:\n%s' "$files" \
        || printf 'audio download finished (in %s):\n%s' "$dir" "$(printf '%s' "$out" | tail -8)"
}

# ── subtitles — download subtitles for a language, as srt/vtt/ass. Gated. ────
tool_ytdl_subtitles() {
    _ytdl_need || return 1
    local url dir lang fmt auto; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    dir=$(_ytdl_outdir) || { printf 'download dir not allowed / not creatable (check .dir)'; return 1; }
    lang=$(tool_arg lang en); shell_arg_safe "$lang" >/dev/null || { printf 'lang must be a simple token (e.g. en, es, en.*)'; return 1; }
    fmt=$(tool_arg format srt); case "$fmt" in srt|vtt|ass|lrc) ;; *) printf 'format must be srt|vtt|ass|lrc'; return 1 ;; esac
    auto=$(tool_arg auto false)   # include auto-generated subs when true
    local -a subflag=(--write-subs); [[ "$auto" == "true" ]] && subflag+=(--write-auto-subs)
    confirm_action "Download $lang subtitles ($fmt) from $url to $dir" "yt-dlp --write-subs --sub-langs $lang" || { confirm_denied_msg; return 1; }
    local out
    out=$(yt-dlp --skip-download "${subflag[@]}" --sub-langs "$lang" --convert-subs "$fmt" --no-playlist \
             --restrict-filenames --no-overwrites --no-progress -P "$dir" -o '%(title).150B.%(ext)s' "$url" 2>&1)
    local written; written=$(printf '%s' "$out" | grep -oE '/[^ ]*\.'"$fmt" | sort -u || true)
    [[ -n "$written" ]] && printf 'subtitles:\n%s' "$written" || { printf 'no subtitles written (none available for "%s"?). yt-dlp said:\n%s' "$lang" "$(printf '%s' "$out" | tail -6)"; return 1; }
}

# ── transcript — auto-subtitles → plain text (great for summarizing a talk). ─
tool_ytdl_transcript() {
    _ytdl_need || return 1
    local url dir lang; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    dir=$(_ytdl_outdir) || { printf 'download dir not allowed / not creatable (check .dir)'; return 1; }
    lang=$(tool_arg lang en); shell_arg_safe "$lang" >/dev/null || { printf 'lang must be a simple token (e.g. en)'; return 1; }
    confirm_action "Fetch $lang transcript (auto-subtitles) from $url" "yt-dlp --write-auto-subs -> text" || { confirm_denied_msg; return 1; }
    local out srt
    out=$(yt-dlp --skip-download --write-auto-subs --write-subs --sub-langs "$lang" --convert-subs srt --no-playlist \
             --restrict-filenames --no-overwrites --no-progress -P "$dir" -o '%(title).150B.%(ext)s' "$url" 2>&1)
    srt=$(printf '%s' "$out" | grep -oE '/[^ ]*\.srt' | head -1)
    [[ -n "$srt" && -f "$srt" ]] || { printf 'no transcript available for "%s". yt-dlp said:\n%s' "$lang" "$(printf '%s' "$out" | tail -6)"; return 1; }
    # SRT -> plain text: drop indices, timestamp lines, and blank lines; de-dup
    # consecutive identical lines (auto-subs repeat the rolling caption heavily).
    local text; text=$(awk '
        /^[0-9]+$/ { next }
        /-->/ { next }
        /^[[:space:]]*$/ { next }
        { gsub(/<[^>]*>/, ""); if ($0 != prev) { print; prev = $0 } }' "$srt")
    printf 'transcript (from %s):\n\n%s' "$srt" "$text"
}

# ── llm_explain — recommend which format/quality to fetch for a goal. LLM. ───
tool_ytdl_llm_explain() {
    _ytdl_need || return 1
    local url goal; url=$(_ytdl_url) || { printf '%s' "$url"; return 1; }
    goal=$(tool_arg goal "get the best balance of quality and size")
    local content; content=$(yt-dlp -F --no-playlist --no-warnings "$url" 2>&1 | grep -vE '^\[' | head -60)
    local system_prompt='You are a yt-dlp expert. Given this "-F" format table and the user goal, recommend the exact yantra ytdl_download call: which .format selector (yt-dlp -f expression) or .quality (max height) to use and why, and whether ytdl_audio fits better. Note when ffmpeg is required to merge separate video+audio streams.'
    llm_analyze "$system_prompt" "$(printf 'GOAL: %s\n\nFORMATS:\n%s' "$goal" "$content")"
}

# ── Register (category: ytdl) ────────────────────────────────────────────────
tool_register "ytdl_doctor"      tool_ytdl_doctor      '{"type":"object","properties":{}}' safe all ytdl
tool_register "ytdl_info"        tool_ytdl_info        '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"}},"required":["url"]}' safe all ytdl
tool_register "ytdl_search"      tool_ytdl_search      '{"type":"object","properties":{"query":{"type":"string","description":"search terms"},"count":{"type":"integer","description":"number of results (1-20, default 5)"}},"required":["query"]}' safe all ytdl
tool_register "ytdl_download"    tool_ytdl_download    '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"},"quality":{"type":"integer","description":"max video height, e.g. 720 or 1080"},"format":{"type":"string","description":"a raw yt-dlp -f selector (overrides quality)"},"dir":{"type":"string","description":"in-tree output dir (default: downloads/)"},"playlist":{"type":"boolean","description":"allow a playlist URL (default false)"},"playlist_max":{"type":"integer","description":"cap when playlist=true (<=50)"}},"required":["url"]}' writes all ytdl
tool_register "ytdl_audio"       tool_ytdl_audio       '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"},"audio_format":{"type":"string","enum":["mp3","m4a","opus","aac","flac","wav","vorbis"],"description":"output audio format (default mp3)"},"dir":{"type":"string","description":"in-tree output dir (default: downloads/)"},"playlist":{"type":"boolean","description":"allow a playlist URL"},"playlist_max":{"type":"integer","description":"cap when playlist=true (<=50)"}},"required":["url"]}' writes all ytdl
tool_register "ytdl_subtitles"   tool_ytdl_subtitles   '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"},"lang":{"type":"string","description":"subtitle language (default en)"},"format":{"type":"string","enum":["srt","vtt","ass","lrc"],"description":"subtitle format (default srt)"},"auto":{"type":"boolean","description":"include auto-generated subs"},"dir":{"type":"string","description":"in-tree output dir"}},"required":["url"]}' writes all ytdl
tool_register "ytdl_transcript"  tool_ytdl_transcript  '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"},"lang":{"type":"string","description":"transcript language (default en)"},"dir":{"type":"string","description":"in-tree output dir"}},"required":["url"]}' writes all ytdl
tool_register "ytdl_llm_explain" tool_ytdl_llm_explain '{"type":"object","properties":{"url":{"type":"string","description":"the video/page URL"},"goal":{"type":"string","description":"what you want (e.g. smallest file, best quality, audio only)"}},"required":["url"]}' safe all ytdl mid
