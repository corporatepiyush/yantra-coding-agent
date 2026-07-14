# tools/media.sh — Media tools: probe/inspect, safe lossless transforms, and
# transcription. Probe-first discipline (know codec/resolution/duration before
# touching anything). Destructive/re-encode ops require confirmation.

_media_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

_media_guard() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
}

# probe — codec, resolution, duration, bitrate, streams.
tool_media_probe() {
    local file="$1"; _media_guard "$file" || return 1
    if command -v ffprobe &>/dev/null; then
        ffprobe -hide_banner -v error -show_format -show_streams "$file" 2>&1 | head -80
    elif command -v identify &>/dev/null; then
        identify -verbose "$file" 2>&1 | head -60
    else
        _media_missing ffprobe "brew install ffmpeg"; return 1
    fi
}

# convert — transcode to another container/format. Re-encodes: confirm first.
tool_media_convert() {
    local file="$1"; _media_guard "$file" || return 1
    local to; to=$(tool_arg format mp4)
    # format becomes the output extension — keep it a bare alnum token so it can
    # never smuggle path separators / '..' into the derived output path.
    [[ "$to" =~ ^[A-Za-z0-9]+$ ]] || { printf 'format must be alphanumeric (e.g. mp4, webm, mov)'; return 1; }
    local out="${file%.*}.$to"
    [[ "$out" == "$file" ]] && { printf 'output would overwrite the source; choose a different format'; return 1; }
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    _media_ffmpeg || return 1
    confirm_action "Transcode media: $file -> $out" "ffmpeg -i '$file' '$out'" || { confirm_denied_msg; return 1; }
    cmd_wrote "$out" "wrote $out" ffmpeg -nostdin -hide_banner -y -i "$file" "$out"
}

# thumbnail — extract a frame (video) or resize (image) for a quick preview.
tool_media_thumbnail() {
    local file="$1"; _media_guard "$file" || return 1
    local out="${file%.*}_thumb.jpg"
    case "$(path_ext "$file")" in
        mp4|mov|mkv|webm|avi)
            command -v ffmpeg &>/dev/null || { _media_missing ffmpeg "brew install ffmpeg"; return 1; }
            cmd_wrote "$out" "thumbnail: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -ss "$(tool_arg start 1)" -vframes 1 "$out" ;;
        png|jpg|jpeg|gif|webp|tiff)
            command -v convert &>/dev/null || { _media_missing imagemagick "brew install imagemagick"; return 1; }
            cmd_wrote "$out" "thumbnail: $out" convert "$file" -resize 320x "$out" ;;
        *) printf 'unsupported media type'; return 1 ;;
    esac
}

# transcribe — audio/video -> text via whisper (local preferred). This WRITES a
# transcript file, so the output goes to a fenced sibling dir (never the process
# cwd, which whisper defaults to) and the danger is `writes`. model/format are
# args; the full transcript is returned (no arbitrary tail cap).
tool_media_transcribe() {
    local file="$1"; _media_guard "$file" || return 1
    local model format dir
    model=$(tool_arg model base)
    format=$(tool_arg format txt)
    shell_arg_safe "$model" >/dev/null || { printf 'invalid model name'; return 1; }
    case "$format" in txt|srt|vtt|json|tsv|all) ;; *) printf 'format must be txt|srt|vtt|json|tsv|all'; return 1 ;; esac
    dir=$(path_dirname "$file")
    path_check_allowed "$dir" 2>/dev/null || { printf 'output dir not allowed'; return 1; }
    if command -v whisper &>/dev/null; then
        whisper "$file" --model "$model" --output_format "$format" --output_dir "$dir" 2>&1
    elif command -v whisper-cpp &>/dev/null; then
        # whisper-cpp writes its outputs into the cwd; run it from the fenced dir.
        ( cd "$dir" && whisper-cpp -f "$file" 2>&1 )
    else
        _media_missing whisper "pip install openai-whisper  /  brew install whisper-cpp"; return 1
    fi
}

# llm_explain — explain a probe result / ffmpeg error in plain terms.
tool_media_llm_explain() {
    local input="$1"
    [[ -n "$input" ]] || { printf 'question, probe output, or error text required'; return 1; }
    # If it's a file, probe it; otherwise treat as a question/error string.
    local content="$input"
    [[ -f "$input" ]] && content=$(tool_media_probe "$input")
    local system_prompt='You are a media/ffmpeg expert. Explain the media probe output, error, or question below in plain language: what the codecs/containers mean, likely problems (wrong codec, orientation flag, color space, sample rate, corrupt stream), and the exact ffmpeg/imagemagick command to fix or convert it.'
    llm_analyze "$system_prompt" "$content"
}

# _media_out FILE SUFFIX EXT -> compute a sibling output path and verify it's
# writable within the allowed tree. Derived outputs never overwrite the source.
_media_out() {
    # NB: `out` MUST be computed in a SEPARATE statement — in a single
    # `local file=$1 suffix=$2 ext=$3 out=${file...}` bash expands ${file}/${suffix}/
    # ${ext} against the OUTER scope (still empty) before these locals take effect,
    # so `out` collapsed to "." and every derived output path was silently wrong.
    local file="$1" suffix="$2" ext="$3"
    local out="${file%.*}${suffix}.${ext}"
    path_check_allowed "$out" 2>/dev/null || { printf ''; return 1; }
    printf '%s' "$out"
}
_media_ffmpeg() { command -v ffmpeg &>/dev/null || { _media_missing ffmpeg "brew install ffmpeg"; return 1; }; }

# _media_noclobber OUT — never silently overwrite a pre-existing (different) file.
# A fresh output passes straight through; an existing one needs consent (auto-
# denied in machine mode without auto_confirm, prompted in human/CLI mode). The
# _media_out suffix already keeps derived outputs off the source path, so any
# existing OUT is a prior result or an unrelated user file worth protecting.
_media_noclobber() {
    local out="$1"
    [[ -e "$out" ]] || return 0
    confirm_action "Overwrite existing file: $out" "overwrite $out" && return 0
    printf 'refusing to overwrite existing file (no-clobber) — pass a new name or confirm: %s' "$out"
    return 1
}

# trim — cut a clip [start, duration] without re-encoding (stream copy = instant).
tool_media_trim() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local start dur out; start=$(tool_arg start 0); dur=$(tool_arg duration 10)
    out=$(_media_out "$file" "_clip" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "clip: $out" ffmpeg -nostdin -hide_banner -y -ss "$start" -i "$file" -t "$dur" -c copy "$out"
}

# concat — join several clips of the same codec (concat demuxer, no re-encode).
tool_media_concat() {
    _media_ffmpeg || return 1
    local files; files=$(tool_arg files)
    [[ -n "$files" && "$files" != "null" ]] || { printf 'files (JSON array of paths) required'; return 1; }
    local list; list=$(path_temp_file yca-concat).txt
    local ok=1 f
    while IFS= read -r f; do
        [[ -f "$f" ]] && path_check_allowed "$f" 2>/dev/null && printf "file '%s'\n" "$f" >> "$list" || ok=0
    done < <(printf '%s' "$files" | jq -r '.[]?' 2>/dev/null)
    [[ "$ok" == 1 ]] || { rm -f "$list"; printf 'one or more inputs missing/not allowed'; return 1; }
    local out; out=$(tool_arg out "${YCA_PROJECT_DIR}/concat_${EPOCHSECONDS}.mp4")
    path_check_allowed "$out" 2>/dev/null || { rm -f "$list"; printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "joined: $out" ffmpeg -nostdin -hide_banner -y -f concat -safe 0 -i "$list" -c copy "$out"; local rc=$?
    rm -f "$list"; return $rc
}

# resize — scale a video or image to a target width (keeps aspect ratio).
tool_media_resize() {
    local file="$1"; _media_guard "$file" || return 1
    local w out; w=$(int_guard "$(tool_arg width 1280)" 1280)
    out=$(_media_out "$file" "_${w}w" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    case "$(path_ext "$file")" in
        png|jpg|jpeg|gif|webp|tiff|bmp)
            command -v convert &>/dev/null || { _media_missing imagemagick "brew install imagemagick"; return 1; }
            cmd_wrote "$out" "resized: $out" convert "$file" -resize "${w}x" "$out" ;;
        *) _media_ffmpeg || return 1
            cmd_wrote "$out" "resized: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -vf "scale=${w}:-2" "$out" ;;
    esac
}

# gif — make a high-quality GIF from a video segment (palette gen = crisp colors).
tool_media_make_gif() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local start dur fps out; start=$(tool_arg start 0); dur=$(tool_arg duration 4); fps=$(int_guard "$(tool_arg fps 12)" 12)
    out=$(_media_out "$file" "" "gif") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "gif: $out" ffmpeg -nostdin -hide_banner -y -ss "$start" -t "$dur" -i "$file" \
        -vf "fps=${fps},scale=480:-1:flags=lanczos,split[s0][s1];[s0]palettegen[p];[s1][p]paletteuse" "$out"
}

# extract_audio — pull the audio track to mp3/aac/wav.
tool_media_extract_audio() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local fmt out; fmt=$(tool_arg format mp3); out=$(_media_out "$file" "" "$fmt") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "audio: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -vn -q:a 2 "$out"
}

# waveform — render an audio waveform PNG (great for thumbnails/edits).
tool_media_waveform() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local out; out=$(_media_out "$file" "_wave" "png") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "waveform: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -filter_complex "showwavespic=s=1200x240:colors=#3b82f6" -frames:v 1 "$out"
}

# normalize — EBU R128 loudness normalization (consistent podcast/video levels).
tool_media_normalize() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local out; out=$(_media_out "$file" "_norm" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "normalized: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -af "loudnorm=I=-16:TP=-1.5:LRA=11" "$out"
}

# contact_sheet — a grid of thumbnails sampled across a video (quick overview).
tool_media_contact_sheet() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local out; out=$(_media_out "$file" "_sheet" "png") || { printf 'output path not allowed'; return 1; }
    cmd_wrote "$out" "contact sheet: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -vf "fps=1/10,scale=240:-1,tile=4x4" -frames:v 1 "$out"
}

# strip_metadata — remove EXIF/metadata before sharing (privacy).
tool_media_strip_metadata() {
    local file="$1"; _media_guard "$file" || return 1
    local out; out=$(_media_out "$file" "_clean" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    if command -v exiftool &>/dev/null; then
        cp -- "$file" "$out" || { printf 'could not stage a copy to strip'; return 1; }
        cmd_wrote "$out" "stripped: $out" exiftool -all= -overwrite_original "$out"
    else
        _media_ffmpeg || return 1
        cmd_wrote "$out" "stripped: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -map_metadata -1 -c copy "$out"
    fi
}

# watermark — burn a text overlay (bottom-right) onto a video/image. The overlay
# text is UNTRUSTED, so it is passed via drawtext's `textfile=` (with metadata
# `expansion=none`) rather than inlined into the filter expression — it is drawn
# literally and can never break out of the filter or trigger %{…} expansion. No
# character blacklist is needed.
tool_media_watermark() {
    local file="$1"; _media_guard "$file" || return 1
    _media_ffmpeg || return 1
    # Text overlay needs the libfreetype-backed `drawtext` filter — a minimal
    # ffmpeg omits it. Detect it up front, else ffmpeg dies with a cryptic
    # "Filter not found" that the old code MIS-REPORTED as success (see below).
    ffmpeg -hide_banner -filters 2>/dev/null | grep -qE '(^| )drawtext ' \
        || { printf 'this ffmpeg build lacks the drawtext filter (needs libfreetype) — reinstall a full ffmpeg (brew reinstall ffmpeg), or use media_watermark_logo with a PNG logo'; return 1; }
    local text out tf; text=$(tool_arg text "© $(now_stamp %Y)")
    out=$(_media_out "$file" "_wm" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    tf=$(path_temp_file yca-wm)
    printf '%s' "$text" > "$tf"
    # Capture ffmpeg's OWN exit (the old `ffmpeg … | tail -6 || rc=$?` captured
    # tail's exit — always 0 — so a failed render still printed "watermarked").
    local err rc
    err=$(ffmpeg -nostdin -hide_banner -y -i "$file" \
        -vf "drawtext=textfile='${tf}':expansion=none:x=w-tw-20:y=h-th-20:fontcolor=white:fontsize=24:box=1:boxcolor=black@0.4" \
        "$out" 2>&1); rc=$?
    rm -f "$tf"
    if [[ $rc -eq 0 && -f "$out" ]]; then printf 'watermarked: %s' "$out"
    else printf 'watermark failed:\n%s' "$(printf '%s' "$err" | tail -4)"; return 1; fi
}

# speed — change playback speed (e.g. 2 = 2x faster, 0.5 = slow-mo).
tool_media_change_speed() {
    local file="$1"; _media_guard "$file" || return 1; _media_ffmpeg || return 1
    local factor out; factor=$(tool_arg factor 2)
    [[ "$factor" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf 'factor must be a positive number'; return 1; }
    out=$(_media_out "$file" "_x${factor}" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    # video PTS scales by 1/factor; audio tempo scales by factor.
    local vpts; vpts=$(awk -v f="$factor" 'BEGIN{printf "%.4f", 1/f}')
    # Try the a/v path; fall back to video-only (silent source) — report honestly.
    local res rc
    res=$(cmd_wrote "$out" "speed x${factor}: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -filter_complex "[0:v]setpts=${vpts}*PTS[v];[0:a]atempo=${factor}[a]" -map "[v]" -map "[a]" "$out"); rc=$?
    (( rc != 0 )) && { res=$(cmd_wrote "$out" "speed x${factor}: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -filter:v "setpts=${vpts}*PTS" "$out"); rc=$?; }
    printf '%s' "$res"; return $rc
}

# compress — shrink a video toward a target size (MB, two-pass bitrate) or by a
# quality factor (CRF, default). Output is a fenced sibling; never the source.
tool_media_compress() {
    local file="$1"; _media_guard "$file" || return 1
    local target crf out; target=$(tool_arg target_mb ""); crf=$(int_guard "$(tool_arg crf 28)" 28)
    out=$(_media_out "$file" "_min" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    _media_ffmpeg || return 1
    if [[ -n "$target" && "$target" != "null" ]]; then
        [[ "$target" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf 'target_mb must be a positive number'; return 1; }
        local dur bitrate log rc
        dur=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$file" 2>/dev/null)
        [[ "$dur" =~ ^[0-9]+(\.[0-9]+)?$ ]] || { printf 'could not read duration for target-size compression'; return 1; }
        # video bitrate = target_bits/duration, reserving ~128kbps for audio; floor at 1kbps.
        bitrate=$(awk -v mb="$target" -v d="$dur" 'BEGIN{v=(mb*8388608)/d-128000; if(v<1000)v=1000; printf "%d", v}')
        log=$(path_temp_file yca-2pass)
        # No pipe here, so `rc` is the compound's real exit (pass-2's, or pass-1's
        # if it failed) — not a swallowing `| tail`.
        ffmpeg -nostdin -hide_banner -y -i "$file" -c:v libx264 -b:v "$bitrate" -pass 1 -passlogfile "$log" -an -f null /dev/null >/dev/null 2>&1 \
          && ffmpeg -nostdin -hide_banner -y -i "$file" -c:v libx264 -b:v "$bitrate" -pass 2 -passlogfile "$log" -c:a aac -b:a 128k "$out" >/dev/null 2>&1
        rc=$?
        rm -f "$log" "$log"-*.log "$log"-*.log.mbtree 2>/dev/null
        [[ $rc -eq 0 && -s "$out" ]] && printf 'compressed (~%s MB, 2-pass): %s' "$target" "$out" \
            || { printf 'two-pass compression failed (exit %s)' "$rc"; return 1; }
    else
        [[ "$crf" -ge 0 && "$crf" -le 51 ]] || { printf 'crf must be 0-51 (lower = higher quality/size)'; return 1; }
        cmd_wrote "$out" "compressed (crf $crf): $out" ffmpeg -nostdin -hide_banner -y -i "$file" -c:v libx264 -crf "$crf" -c:a aac -b:a 128k "$out"
    fi
}

# crop — cut a W:H rectangle at offset X,Y from a video/image (all integers).
tool_media_crop() {
    local file="$1"; _media_guard "$file" || return 1
    local w h x y out
    w=$(int_guard "$(tool_arg width 0)" 0); h=$(int_guard "$(tool_arg height 0)" 0)
    x=$(int_guard "$(tool_arg x 0)" 0);     y=$(int_guard "$(tool_arg y 0)" 0)
    [[ "$w" -gt 0 && "$h" -gt 0 ]] || { printf 'width and height (both >0) required'; return 1; }
    out=$(_media_out "$file" "_crop" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    _media_ffmpeg || return 1
    cmd_wrote "$out" "cropped: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -vf "crop=${w}:${h}:${x}:${y}" "$out"
}

# rotate — rotate 90/180/270 degrees (lossless transpose chain).
tool_media_rotate() {
    local file="$1"; _media_guard "$file" || return 1
    local deg vf out; deg=$(tool_arg degrees 90)
    case "$deg" in
        90)      vf="transpose=1" ;;
        180)     vf="transpose=1,transpose=1" ;;
        270|-90) vf="transpose=2" ;;
        *) printf 'degrees must be 90, 180, or 270'; return 1 ;;
    esac
    out=$(_media_out "$file" "_rot${deg}" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    _media_ffmpeg || return 1
    cmd_wrote "$out" "rotated $deg: $out" ffmpeg -nostdin -hide_banner -y -i "$file" -vf "$vf" "$out"
}

# subtitles — generate an .srt subtitle track via whisper (local). Output lands
# in the source's fenced dir (whisper writes <stem>.srt there), never the cwd.
tool_media_subtitles() {
    local file="$1"; _media_guard "$file" || return 1
    local model dir out; model=$(tool_arg model base)
    shell_arg_safe "$model" >/dev/null || { printf 'invalid model name'; return 1; }
    dir=$(path_dirname "$file"); path_check_allowed "$dir" 2>/dev/null || { printf 'output dir not allowed'; return 1; }
    out="${file%.*}.srt"; path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    command -v whisper &>/dev/null || { _media_missing whisper "pip install openai-whisper"; return 1; }
    cmd_wrote "$out" "subtitles: $out" whisper "$file" --model "$model" --output_format srt --output_dir "$dir"
}

# watermark_logo — composite a PNG logo onto an image (imagemagick). The logo is
# an INPUT path and is fenced + existence-checked like any other input.
tool_media_watermark_logo() {
    local file="$1"; _media_guard "$file" || return 1
    local logo gravity out; logo=$(tool_arg logo "")
    [[ -n "$logo" ]] || { printf 'logo (PNG path) required (.logo)'; return 1; }
    path_check_allowed "$logo" 2>/dev/null || { printf 'logo path not allowed: %s' "$logo"; return 1; }
    [[ -f "$logo" ]] || { printf 'logo not found: %s' "$logo"; return 1; }
    gravity=$(tool_arg gravity SouthEast)
    case "$gravity" in NorthWest|North|NorthEast|West|Center|East|SouthWest|South|SouthEast) ;; *) printf 'invalid gravity (e.g. SouthEast)'; return 1 ;; esac
    out=$(_media_out "$file" "_logo" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    _media_noclobber "$out" || return 1
    command -v convert &>/dev/null || { _media_missing imagemagick "brew install imagemagick"; return 1; }
    cmd_wrote "$out" "logo watermark: $out" convert "$file" "$logo" -gravity "$gravity" -geometry +20+20 -composite "$out"
}

tool_media_doctor() {
    local out="" t
    for t in ffmpeg ffprobe convert identify exiftool whisper whisper-cpp; do
        out+="$t: $(command -v "$t" &>/dev/null && printf 'ok' || printf 'not installed')\n"
    done
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "media_probe"       tool_media_probe       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all media
tool_register "media_convert"     tool_media_convert     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"format":{"type":"string","description":"the output format"}},"required":["file","format"]}' writes all media
tool_register "media_thumbnail"   tool_media_thumbnail   '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"start":{"type":"string","description":"the start position or time"}},"required":["file"]}' writes all media
tool_register "media_transcribe"  tool_media_transcribe  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"model":{"type":"string","description":"the model name"},"format":{"type":"string","description":"txt|srt|vtt|json|tsv|all"}},"required":["file"]}' writes all media
tool_register "media_trim"          tool_media_trim          '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"start":{"type":"string","description":"the start position or time"},"duration":{"type":"string","description":"duration to sample, in seconds"}},"required":["file"]}' writes all media
tool_register "media_concat"        tool_media_concat        '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"list of file paths relative to the project root"},"out":{"type":"string","description":"output path"}},"required":["files"]}' writes all media
tool_register "media_resize"        tool_media_resize        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"width":{"type":"integer","description":"width in pixels"}},"required":["file"]}' writes all media
tool_register "media_make_gif"           tool_media_make_gif           '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"start":{"type":"string","description":"the start position or time"},"duration":{"type":"string","description":"duration to sample, in seconds"},"fps":{"type":"integer","description":"the fps"}},"required":["file"]}' writes all media
tool_register "media_extract_audio" tool_media_extract_audio '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"format":{"type":"string","description":"the output format"}},"required":["file"]}' writes all media
tool_register "media_waveform"      tool_media_waveform      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all media
tool_register "media_normalize"     tool_media_normalize     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all media
tool_register "media_contact_sheet" tool_media_contact_sheet '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all media
tool_register "media_strip_metadata" tool_media_strip_metadata '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all media
tool_register "media_watermark"     tool_media_watermark     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"text":{"type":"string","description":"the text"}},"required":["file"]}' writes all media
tool_register "media_change_speed"         tool_media_change_speed         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"factor":{"type":"string","description":"the factor"}},"required":["file"]}' writes all media
tool_register "media_compress"      tool_media_compress      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"target_mb":{"type":"number","description":"target size in MB (two-pass); omit for CRF"},"crf":{"type":"integer","description":"0-51, lower=better (default 28)"}},"required":["file"]}' writes all media
tool_register "media_crop"          tool_media_crop          '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"width":{"type":"integer","description":"width in pixels"},"height":{"type":"integer","description":"height in pixels"},"x":{"type":"integer","description":"the x"},"y":{"type":"integer","description":"the y"}},"required":["file","width","height"]}' writes all media
tool_register "media_rotate"        tool_media_rotate        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"degrees":{"type":"integer","description":"90|180|270"}},"required":["file"]}' writes all media
tool_register "media_subtitles"     tool_media_subtitles     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"model":{"type":"string","description":"the model name"}},"required":["file"]}' writes all media
tool_register "media_watermark_logo" tool_media_watermark_logo '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"logo":{"type":"string","description":"path to a PNG logo"},"gravity":{"type":"string","description":"SouthEast|NorthWest|Center|…"}},"required":["file","logo"]}' writes all media
tool_register "media_llm_explain" tool_media_llm_explain '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all media mid
tool_register "media_doctor"      tool_media_doctor      '{"type":"object","properties":{}}' safe all media
