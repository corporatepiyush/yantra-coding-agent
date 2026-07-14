# workflows/media.sh — Task-level media pipelines: the things a NON-technical
# person actually asks for ("save this talk to listen offline", "just the 1:10–
# 3:05 clip", "burn captions in", "what does this hour-long video say?", "make
# these photos safe to post", "read this PDF to me"). Each chains 2+ of the deps
# Yantra already knows (yt-dlp, ffmpeg, whisper, imagemagick/ffmpeg, exiftool,
# opencv, poppler, the OS text-to-speech) into ONE action, so a small model calls
# one workflow instead of orchestrating four tools.
#
# House rules honored here:
#   • The risky NETWORK fetch always goes through the hardened ytdl_* / doc_* /
#     media_* TOOLS via tool_invoke (SSRF vetting, path fence, playlist caps,
#     consent) — the workflow never re-implements that.
#   • A direct ffmpeg/say/espeak call redirects stdin from /dev/null (ffmpeg also
#     gets -nostdin): run_workflow does NOT redirect stdin, and a stdin-reading
#     child would swallow the MCP JSON-RPC frame stream and end the session.
#   • Outputs land in a fenced, path-checked directory and never clobber blindly.
#   • These are `writes` (except media.summarize, which only reads + asks the
#     LLM): machine mode auto-denies them without -y, exactly like a write tool.

# ── shared helpers ───────────────────────────────────────────────────────────
# _wf_media_url RAW -> a validated, SSRF-vetted http(s) URL, or fail. Same trio
# the ytdl tools use (sanitize + lexical host block + resolve-and-vet), so a
# workflow that fetches directly is held to the same bar as the tools.
_wf_media_url() {
    local raw="$1" url host ip
    [[ -n "$raw" ]] || return 1
    url=$(sanitize_url "$raw") || return 1
    host=$(_browse_url_host "$url")
    _browse_blocked_host "$host" && return 1
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        _browse_ip_internal "$ip" && return 1
    done < <(_browse_resolve "$host")
    printf '%s' "$url"
}

# _wf_media_outdir [DIR] -> a fenced, existing output dir (default downloads/).
_wf_media_outdir() {
    local dir="${1:-$YCA_PROJECT_DIR/downloads}"
    path_check_allowed "$dir" 2>/dev/null || return 1
    path_ensure_dir "$dir" 2>/dev/null || return 1
    printf '%s' "$dir"
}

# _wf_media_have BIN HINT -> 0 if present, else emit_fail with an install hint.
_wf_media_have() { command -v "$1" &>/dev/null || { emit_fail "$1 not installed — $2"; return 1; }; }

# _wf_ffmpeg ARGS... — run ffmpeg with stdin closed (see header) and quietly.
_wf_ffmpeg() { ffmpeg -nostdin -hide_banner -y "$@" </dev/null 2>&1; }

# ── media.podcast — talk URL -> a loudness-normalized, tagged offline audio file.
# yt-dlp (vetted extract) + ffmpeg (EBU R128 loudnorm so every episode plays at
# the same volume) + the title/uploader tags a player needs. Two real deps, one
# ask: "save this to listen to later."
wf_media_podcast() {
    local raw="${INPUT_url:-}"; val_required "$raw" "INPUT_url" || { emit_fail "INPUT_url required"; return 1; }
    local url; url=$(_wf_media_url "$raw") || { emit_fail "INPUT_url must be a public http(s) URL (internal/loopback refused)"; return 1; }
    _wf_media_have yt-dlp "brew install yt-dlp" || return 1
    local dir; dir=$(_wf_media_outdir "${INPUT_dir:-}") || { emit_fail "download dir not allowed/creatable (check .dir)"; return 1; }
    local afmt="${INPUT_audio_format:-m4a}"
    case "$afmt" in mp3|m4a|opus|aac|flac) ;; *) emit_fail "audio_format must be mp3|m4a|opus|aac|flac"; return 1 ;; esac

    emit_progress "download" "extracting audio" 25
    local out; out=$(tool_invoke ytdl_audio "$(jq -n --arg u "$url" --arg a "$afmt" --arg d "$dir" '{url:$u,audio_format:$a,dir:$d}')")
    printf '%s\n' "$out" >&2
    local src; src=$(printf '%s' "$out" | grep -oE "${dir}/[^[:cntrl:]]+\.${afmt}" | head -1)
    [[ -n "$src" && -f "$src" ]] || { emit_fail "audio download produced no file: $(printf '%s' "$out" | tail -3)"; return 1; }

    # Title / artist for tags (best-effort — a failed lookup just leaves them blank).
    local info title uploader
    info=$(tool_invoke ytdl_info "$(jq -n --arg u "$url" '{url:$u}')" 2>/dev/null)
    title=$(printf '%s' "$info" | jq -r '.title // empty' 2>/dev/null)
    uploader=$(printf '%s' "$info" | jq -r '.uploader // .channel // empty' 2>/dev/null)

    if ! command -v ffmpeg &>/dev/null; then
        emit_ok "audio saved (ffmpeg absent, no loudness pass): $src"
        return 0
    fi
    emit_progress "normalize" "loudness + tags" 75
    local final="${src%.*}_podcast.${afmt}"
    [[ -e "$final" ]] && final="${src%.*}_podcast_$(now_stamp).${afmt}"
    local -a meta=()
    [[ -n "$title" ]]    && meta+=(-metadata "title=$title")
    [[ -n "$uploader" ]] && meta+=(-metadata "artist=$uploader")
    if _wf_ffmpeg -i "$src" -af "loudnorm=I=-16:TP=-1.5:LRA=11" -c:a aac -b:a 192k "${meta[@]}" "$final" | tail -4 >&2; then
        [[ -f "$final" ]] && { emit_ok "podcast ready (normalized${title:+, \"$title\"}): $final"; return 0; }
    fi
    emit_ok "audio saved (loudness pass failed, raw file kept): $src"
}

# ── media.clip — download ONLY a time range of a video, optionally shrink it.
# yt-dlp --download-sections fetches just the segment (no full download), then an
# optional media_compress pass targets an email-friendly size. "I only want 1:10
# to 3:05" in one call.
wf_media_clip() {
    local raw="${INPUT_url:-}"; val_required "$raw" "INPUT_url" || { emit_fail "INPUT_url required"; return 1; }
    local url; url=$(_wf_media_url "$raw") || { emit_fail "INPUT_url must be a public http(s) URL"; return 1; }
    local start="${INPUT_start:-}" end="${INPUT_end:-}"
    val_required "$start" "INPUT_start" || { emit_fail "INPUT_start required (e.g. 1:10 or 70)"; return 1; }
    val_required "$end" "INPUT_end" || { emit_fail "INPUT_end required (e.g. 3:05 or 185)"; return 1; }
    # Time specs are single argv tokens (no shell), but validate for correctness:
    # digits with optional :/. separators only.
    [[ "$start" =~ ^[0-9]+([:.][0-9]+)*$ && "$end" =~ ^[0-9]+([:.][0-9]+)*$ ]] \
        || { emit_fail "start/end must be time specs like 90 or 1:30 or 1:02:03"; return 1; }
    _wf_media_have yt-dlp "brew install yt-dlp" || return 1
    local dir; dir=$(_wf_media_outdir "${INPUT_dir:-}") || { emit_fail "download dir not allowed/creatable"; return 1; }

    emit_progress "download" "fetching section $start-$end" 40
    local out rc
    out=$(yt-dlp --download-sections "*${start}-${end}" --force-keyframes-at-cuts \
              -f 'bv*+ba/b' --no-playlist --restrict-filenames --no-overwrites --no-progress \
              -P "$dir" -o '%(title).120B.clip.%(ext)s' --no-simulate --print after_move:filepath \
              "$url" </dev/null 2>&1); rc=$?
    printf '%s\n' "$out" >&2
    local clip; clip=$(printf '%s' "$out" | grep -E "^${dir}/" | head -1)
    [[ $rc -eq 0 && -n "$clip" && -f "$clip" ]] || { emit_fail "clip download failed: $(printf '%s' "$out" | tail -3)"; return 1; }

    local target="${INPUT_target_mb:-}"
    if [[ -n "$target" && "$target" != "null" ]]; then
        emit_progress "compress" "target ${target}MB" 80
        local comp; comp=$(tool_invoke media_compress "$(jq -n --arg f "$clip" --argjson m "$target" '{file:$f,target_mb:$m}')")
        printf '%s\n' "$comp" >&2
        local small; small=$(printf '%s' "$comp" | grep -oE "${clip%.*}_min\.[A-Za-z0-9]+" | head -1)
        [[ -n "$small" && -f "$small" ]] && { emit_ok "clip ready (~${target}MB): $small"; return 0; }
    fi
    emit_ok "clip ready: $clip"
}

# ── media.hardsub — burn captions permanently into a local video. Uses a
# provided .srt, or generates one with media_subtitles (whisper) first, then a
# single ffmpeg subtitles= filter pass. "Put the captions on it" for a phone that
# won't show a sidecar track.
wf_media_hardsub() {
    local file="${INPUT_file:-}"; val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required (a local video)"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    [[ -f "$file" ]] || { emit_fail "file not found: $file"; return 1; }
    _wf_media_have ffmpeg "brew install ffmpeg" || return 1
    # Burning in captions needs the libass-backed `subtitles` filter — a minimal
    # ffmpeg build omits it. Detect it up front and say so, rather than let ffmpeg
    # fail with a cryptic "No option name" filtergraph parse error.
    ffmpeg -hide_banner -filters 2>/dev/null | grep -qE '(^| )subtitles ' \
        || { emit_fail "this ffmpeg build lacks the libass 'subtitles' filter — reinstall an ffmpeg with libass (brew reinstall ffmpeg)"; return 1; }

    local srt="${INPUT_srt:-}"
    if [[ -z "$srt" ]]; then
        emit_progress "transcribe" "generating captions (whisper)" 30
        local sub; sub=$(tool_invoke media_subtitles "$(jq -n --arg f "$file" '{file:$f}')")
        printf '%s\n' "$sub" >&2
        srt="${file%.*}.srt"
    fi
    path_check_allowed "$srt" || { emit_fail "subtitle path not allowed: $srt"; return 1; }
    [[ -f "$srt" ]] || { emit_fail "no subtitle file (pass .srt, or install whisper for auto-captions): $srt"; return 1; }

    # Escape the path for ffmpeg's subtitles filter: backslash, quote, colon.
    local esc; esc=$(printf '%s' "$srt" | sed -e 's/\\/\\\\/g' -e "s/'/\\\\'/g" -e 's/:/\\:/g')
    local out="${file%.*}_sub.mp4"; [[ -e "$out" ]] && out="${file%.*}_sub_$(now_stamp).mp4"
    emit_progress "burn" "rendering hardsubs" 70
    if _wf_ffmpeg -i "$file" -vf "subtitles='${esc}'" -c:a copy "$out" | tail -5 >&2 && [[ -f "$out" ]]; then
        emit_ok "captions burned in: $out"
    else
        emit_fail "hardsub render failed (see log above)"; return 1
    fi
}

# ── media.summarize — "what does this video/talk say?" URL -> ytdl_transcript;
# local media -> media_transcribe (whisper); then the LLM condenses it to key
# points. Read-only + one LLM call, so this one is `safe`.
wf_media_summarize() {
    local raw="${INPUT_url:-}" file="${INPUT_file:-}" text=""
    if [[ -n "$raw" ]]; then
        local url; url=$(_wf_media_url "$raw") || { emit_fail "INPUT_url must be a public http(s) URL"; return 1; }
        emit_progress "transcript" "fetching transcript" 40
        text=$(tool_invoke ytdl_transcript "$(jq -n --arg u "$url" '{url:$u}')")
        case "$text" in 'no transcript'*|'url required'*|'refusing'*|'invalid'*|'') emit_fail "no transcript available for that URL"; return 1 ;; esac
    elif [[ -n "$file" ]]; then
        path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
        [[ -f "$file" ]] || { emit_fail "file not found: $file"; return 1; }
        emit_progress "transcribe" "transcribing (whisper)" 40
        tool_invoke media_transcribe "$(jq -n --arg f "$file" '{file:$f}')" >&2
        local txt="${file%.*}.txt"
        [[ -f "$txt" ]] && text=$(<"$txt") || { emit_fail "transcription produced no text (is whisper installed?)"; return 1; }
    else
        emit_fail "INPUT_url or INPUT_file required"; return 1
    fi
    [[ -n "${text// }" ]] || { emit_fail "empty transcript"; return 1; }

    emit_progress "summarize" "asking the model" 80
    local sys='ROLE: Media summarizer. The text below is an auto-generated transcript of a talk/video (timestamps may be stripped; expect ASR errors and repeated lines). Produce, in order:
- TITLE: a one-line best guess at the subject.
- OVERVIEW: 2-3 sentences on what it covers.
- KEY POINTS: 5-10 bullets of the substantive content, in the order presented.
- TAKEAWAYS: concrete conclusions, figures, names, or action items — kept exact.
Use ONLY what the transcript says; never invent. If it is too garbled to summarize, say so.'
    local summary; summary=$(llm_analyze "$sys" "$text")
    printf '%s\n' "$summary" >&2
    emit_ok "summary complete"
}

# ── media.share_photos — make a folder of photos safe + light to send: strip
# EXIF/GPS, downscale, optionally blur faces, then bundle to one archive.
# exiftool/ffmpeg + imagemagick/ffmpeg + opencv + tar. "Make these OK to post."
wf_media_share_photos() {
    local dir="${INPUT_dir:-${INPUT_path:-}}"; val_required "$dir" "INPUT_dir" || { emit_fail "INPUT_dir required (a folder of photos)"; return 1; }
    path_check_allowed "$dir" || { emit_fail "path not allowed: $dir"; return 1; }
    [[ -d "$dir" ]] || { emit_fail "not a directory: $dir"; return 1; }
    local width; width=$(int_guard "${INPUT_width:-1600}" 1600)
    local blur="${INPUT_blur_faces:-false}"

    local -a imgs=(); local f
    while IFS= read -r f; do imgs+=("$f"); done < <(find "$dir" -maxdepth 1 -type f \( \
        -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' -o -iname '*.webp' -o -iname '*.tiff' \) 2>/dev/null | sort)
    (( ${#imgs[@]} == 0 )) && { emit_fail "no images (jpg/png/heic/webp/tiff) in $dir"; return 1; }
    (( ${#imgs[@]} > 100 )) && { emit_fail "refused: ${#imgs[@]} images exceed the cap of 100 (share a smaller batch)"; return 1; }

    local safe="$dir/shareable"; path_ensure_dir "$safe"
    emit_progress "process" "cleaning ${#imgs[@]} photo(s)" 30
    local n=0 base clean resized final
    for f in "${imgs[@]}"; do
        base=$(basename "$f")
        # strip metadata -> *_clean.<ext> (sibling), then resize -> *_<w>w.<ext>.
        tool_invoke media_strip_metadata "$(jq -n --arg f "$f" '{file:$f}')" >/dev/null 2>&1
        clean="${f%.*}_clean.${f##*.}"; [[ -f "$clean" ]] || clean="$f"
        tool_invoke media_resize "$(jq -n --arg f "$clean" --argjson w "$width" '{file:$f,width:$w}')" >/dev/null 2>&1
        resized="${clean%.*}_${width}w.${clean##*.}"; [[ -f "$resized" ]] || resized="$clean"
        final="$resized"
        if [[ "$blur" == "true" ]]; then
            tool_invoke opencv_blur_faces "$(jq -n --arg f "$resized" '{file:$f}')" >/dev/null 2>&1
            local red="${resized%.*}_redacted.${resized##*.}"; [[ -f "$red" ]] && final="$red"
        fi
        cp -- "$final" "$safe/$base" 2>/dev/null && (( n++ ))
        # Delete ONLY the intermediates we created (the _clean/_resized/_redacted
        # siblings). NEVER remove the user's original: when strip or resize
        # degrades and falls back to "$f", clean/resized/final alias the source —
        # rm'ing them here would destroy the original photo.
        local _p
        for _p in "$clean" "$resized" "$final"; do
            [[ "$_p" != "$f" && -f "$_p" ]] && rm -f "$_p" 2>/dev/null
        done
    done
    (( n == 0 )) && { emit_fail "produced no shareable copies"; return 1; }

    emit_progress "bundle" "archiving" 85
    local bundle; bundle=$(tool_invoke fs_archive "$(jq -n --arg p "$safe" --arg o "$dir/shareable_$(now_stamp).tar.gz" '{path:$p,file:$o}')")
    printf '%s\n' "$bundle" >&2
    emit_ok "$n photo(s) cleaned$([[ "$blur" == "true" ]] && printf ' and face-blurred') into $safe/ (and archived)"
}

# ── media.audiobook — read a document aloud into one audio file. doc_extract
# (poppler/pandoc) -> the OS text-to-speech (macOS `say`, Linux `espeak-ng`) ->
# ffmpeg to a portable m4a. "Read this PDF to me."
wf_media_audiobook() {
    local file="${INPUT_file:-}"; val_required "$file" "INPUT_file" || { emit_fail "INPUT_file required (pdf/txt/docx/md)"; return 1; }
    path_check_allowed "$file" || { emit_fail "path not allowed: $file"; return 1; }
    [[ -f "$file" ]] || { emit_fail "file not found: $file"; return 1; }

    emit_progress "extract" "reading document" 25
    local text; text=$(tool_invoke doc_extract "$(jq -n --arg f "$file" '{file:$f}')")
    [[ -n "${text// }" ]] || { emit_fail "no text extracted from $file"; return 1; }
    # Cap the spoken length — a whole book is hours of synthesis; take the first
    # ~40k chars and say so, rather than run unbounded.
    local capped="$text" note=""
    if (( ${#text} > 40000 )); then capped="${text:0:40000}"; note=" (first 40k chars)"; fi

    local out="${file%.*}.m4a"; [[ -e "$out" ]] && out="${file%.*}_audiobook_$(now_stamp).m4a"
    local tmp; tmp=$(path_temp_file yca-tts .txt); printf '%s' "$capped" > "$tmp"

    emit_progress "speak" "synthesizing speech" 60
    if command -v say &>/dev/null; then           # macOS
        local -a voice=(); [[ -n "${INPUT_voice:-}" ]] && voice=(-v "$INPUT_voice")
        if say "${voice[@]}" -o "$out" --file-format=m4af --data-format=aac -f "$tmp" </dev/null 2>&1 >&2 && [[ -f "$out" ]]; then
            rm -f "$tmp"; emit_ok "audiobook ready${note}: $out"; return 0
        fi
    elif command -v espeak-ng &>/dev/null || command -v espeak &>/dev/null; then   # Linux
        local eng; eng=$(command -v espeak-ng || command -v espeak)
        local wav="${out%.m4a}.wav"
        if "$eng" -f "$tmp" -w "$wav" </dev/null 2>&1 >&2 && [[ -f "$wav" ]]; then
            if command -v ffmpeg &>/dev/null; then _wf_ffmpeg -i "$wav" -c:a aac -b:a 96k "$out" >&2 && rm -f "$wav"; else out="$wav"; fi
            rm -f "$tmp"; emit_ok "audiobook ready${note}: $out"; return 0
        fi
    else
        rm -f "$tmp"; emit_fail "no text-to-speech backend — macOS has \`say\` built in; Linux: apt install espeak-ng"; return 1
    fi
    rm -f "$tmp"; emit_fail "speech synthesis failed"; return 1
}

# ── Register (writes, except summarize which only reads + calls the LLM) ──────
wf_register "media.podcast"      wf_media_podcast      1 writes "yt-dlp" "Talk URL -> loudness-normalized, tagged offline audio"
wf_register "media.clip"         wf_media_clip         1 writes "yt-dlp" "Download only a time range of a video (optionally shrink it)"
wf_register "media.hardsub"      wf_media_hardsub      1 writes "ffmpeg" "Burn captions permanently into a local video (.srt or whisper)"
wf_register "media.summarize"    wf_media_summarize    1 safe   ""       "Transcribe a video/talk (URL or file) and summarize it" mid
wf_register "media.share_photos" wf_media_share_photos 1 writes ""       "Strip EXIF, downscale, optionally blur faces, and bundle photos to share"
wf_register "media.audiobook"    wf_media_audiobook    1 writes ""       "Read a document aloud into one audio file (say / espeak-ng)"
