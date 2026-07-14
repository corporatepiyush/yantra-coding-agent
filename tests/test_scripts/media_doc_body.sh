#!/usr/bin/env bash
# tests/test_scripts/media_doc_body.sh — the Media & Documents depth act-half.
# OFFLINE by design: ffmpeg/ghostscript/tesseract/pandoc/whisper/imagemagick are
# usually absent in CI, so every assertion exercises a GUARD / VALIDATION path
# that runs BEFORE the external tool is invoked (registration danger tokens, the
# machine-mode consent gate, output path-fencing, no-clobber, format validation,
# and doc_extract paging). Args: $1=YCA_DIR $2=TMP
set -Euo pipefail; export YCA_DIR="$1" YCA_PROJECT_DIR="$2"; source "$YCA_DIR/harness/main.sh" 2>/dev/null; YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json; YCA_CAT_ENABLED[media]=1; YCA_CAT_ENABLED[doc]=1; fail(){ echo "FAIL: $1"; exit 1; }

SB="$YCA_PROJECT_DIR"
danger_of(){ local info="${YCA_TOOL_REGISTRY[$1]:-}"; [[ -n "$info" ]] || { printf '__unregistered__'; return; }; local _f dg; IFS='|' read -r _f dg _ <<< "$info"; printf '%s' "$dg"; }

# ── 1. Registration: new tools exist, schemas parse, danger tokens correct ─────
NEW_TOOLS="media_compress media_crop media_rotate media_subtitles media_watermark_logo \
doc_compress doc_ocr_pdf doc_images_to_pdf"
for t in $NEW_TOOLS; do
    [[ -n "${YCA_TOOL_REGISTRY[$t]:-}" ]] || fail "$t not registered"
    printf '%s' "${YCA_TOOL_SCHEMAS[$t]:-}" | jq -e . >/dev/null 2>&1 || fail "$t has an unparseable schema"
done

# ── _media_out / _doc_out derive the sibling path CORRECTLY. Regression for the
# `local file=$1 suffix=$2 ext=$3 out=${file…}` bash gotcha: bash expanded the
# derived path against the still-empty OUTER scope, collapsing EVERY media/doc
# output path to "." — so watermark/resize/crop/rotate/pdf_split/ocr_pdf all wrote
# to a broken path. (Exposed by driving the media tools with a local model.)
[[ "$(_media_out "$SB/clip.mp4" "_wm" "mp4")" == "$SB/clip_wm.mp4" ]] \
    || fail "_media_out derived a wrong output path: $(_media_out "$SB/clip.mp4" "_wm" "mp4") (want $SB/clip_wm.mp4)"
[[ "$(_doc_out "$SB/a.pdf" "_ocr" "pdf")" == "$SB/a_ocr.pdf" ]] \
    || fail "_doc_out derived a wrong output path: $(_doc_out "$SB/a.pdf" "_ocr" "pdf") (want $SB/a_ocr.pdf)"

# writes: every media/doc write tool (incl. the retagged transcribe + convert).
for t in media_transcribe media_convert media_watermark media_compress media_crop \
         media_rotate media_subtitles media_watermark_logo \
         doc_convert doc_compress doc_ocr_pdf doc_images_to_pdf; do
    [[ "$(danger_of "$t")" == "writes" ]] || fail "$t should be danger=writes (got: $(danger_of "$t"))"
done
# The transcribe retag is the headline fix: safe -> writes (it writes a transcript).
[[ "$(danger_of media_transcribe)" == "writes" ]] || fail "media_transcribe must be retagged safe->writes"

# safe: pure readers stay ungated.
for t in media_probe doc_extract doc_ocr doc_pdf_info; do
    [[ "$(danger_of "$t")" == "safe" ]] || fail "$t should be danger=safe (got: $(danger_of "$t"))"
done

# ── 2. Machine-mode consent gate: write tools auto-deny (json, no auto_confirm) ─
YCA_AUTO_CONFIRM=false
for t in media_transcribe media_convert media_watermark media_compress media_crop \
         media_rotate media_subtitles media_watermark_logo \
         doc_convert doc_compress doc_ocr_pdf doc_images_to_pdf; do
    out=$(tool_dispatch "$t" '{}' 2>&1) || true
    echo "$out" | grep -qiE 'cancel|confirm' || fail "$t is not consent-gated on dispatch (got: $out)"
done

# ── 3. doc_extract paging: offset is accepted and applied; default keeps line 1 ─
printf 'L1\nL2\nL3\nL4\nL5\n' > "$SB/lines.txt"
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/lines.txt" '{file:$f,offset:"2",max_lines:"2"}')" tool_doc_extract "$SB/lines.txt" 2>&1 || true)
echo "$out" | grep -q 'L3' || fail "doc_extract offset did not reach line 3 (got: $out)"
if echo "$out" | grep -q 'L1'; then fail "doc_extract offset did not skip line 1 (got: $out)"; fi
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/lines.txt" '{file:$f}')" tool_doc_extract "$SB/lines.txt" 2>&1 || true)
echo "$out" | grep -q 'L1' || fail "doc_extract without offset dropped the first line (got: $out)"

# ── 4. doc_convert: no-clobber, output==source refusal, output path-fencing ────
printf '# Title\nbody\n' > "$SB/report.md"
printf 'OLD' > "$SB/report.html"          # a pre-existing DIFFERENT file
YCA_AUTO_CONFIRM=false
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/report.md" '{file:$f,format:"html"}')" tool_doc_convert "$SB/report.md" 2>&1 || true)
echo "$out" | grep -qiE 'no-clobber|overwrite' || fail "doc_convert silently clobbered an existing sibling (got: $out)"
[[ "$(<"$SB/report.html")" == "OLD" ]] || fail "doc_convert overwrote report.html despite no-clobber"
# format==source-ext would overwrite the source itself: refused up front.
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/report.md" '{file:$f,format:"md"}')" tool_doc_convert "$SB/report.md" 2>&1 || true)
echo "$out" | grep -qi 'overwrite the source' || fail "doc_convert allowed output==source (got: $out)"
# a non-alnum format can't smuggle path separators into the derived out path.
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/report.md" '{file:$f,format:"../evil"}')" tool_doc_convert "$SB/report.md" 2>&1 || true)
echo "$out" | grep -qi 'alphanumeric' || fail "doc_convert accepted a path-bearing format (got: $out)"
# with consent the no-clobber releases (must NOT still report no-clobber).
YCA_AUTO_CONFIRM=true
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/report.md" '{file:$f,format:"html"}')" tool_doc_convert "$SB/report.md" 2>&1 || true)
if echo "$out" | grep -qi 'no-clobber'; then fail "doc_convert still refused with auto_confirm (got: $out)"; fi
YCA_AUTO_CONFIRM=false

# ── 5. Output path-fencing: an out outside YCA_SAFETY_PATHS is refused ─────────
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/a.png" --arg o "/etc/evil_$$.pdf" '{files:[$f],out:$o}')" tool_doc_images_to_pdf 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "doc_images_to_pdf accepted an out outside the fence (got: $out)"

# ── 6. Input path-fencing (media): a logo / source outside the fence is refused ─
touch "$SB/photo.png"
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/photo.png" '{file:$f,logo:"/etc/hosts"}')" tool_media_watermark_logo "$SB/photo.png" 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "media_watermark_logo accepted a logo outside the fence (got: $out)"
out=$(YCA_TOOL_ARGS_JSON='{"file":"/etc/hosts"}' tool_media_compress "/etc/hosts" 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "media_compress accepted an input outside the fence (got: $out)"

# ── 7. media_convert: no-clobber + format validation (mirrors doc_convert) ─────
touch "$SB/song.wav"
printf 'OLD' > "$SB/song.mp3"
YCA_AUTO_CONFIRM=false
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/song.wav" '{file:$f,format:"mp3"}')" tool_media_convert "$SB/song.wav" 2>&1 || true)
echo "$out" | grep -qiE 'no-clobber|overwrite' || fail "media_convert silently clobbered an existing sibling (got: $out)"
[[ "$(<"$SB/song.mp3")" == "OLD" ]] || fail "media_convert overwrote song.mp3 despite no-clobber"
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/song.wav" '{file:$f,format:"a b"}')" tool_media_convert "$SB/song.wav" 2>&1 || true)
echo "$out" | grep -qi 'alphanumeric' || fail "media_convert accepted a non-alnum format (got: $out)"

# ── 8. media_watermark: the fragile char-blacklist is GONE (text passed safely) ─
# Text with quotes/colon/percent used to be rejected outright; it must now flow to
# the (absent-in-CI) ffmpeg step via a textfile, never a blacklist refusal.
touch "$SB/clip.mp4"
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/clip.mp4" --arg t 'a: b% "c" 100%' '{file:$f,text:$t}')" tool_media_watermark "$SB/clip.mp4" 2>&1 || true)
if echo "$out" | grep -qi 'may not contain'; then fail "media_watermark still uses a character blacklist (got: $out)"; fi

# ── 9. media_transcribe writes to a FENCED dir, and refuses an out-of-fence src ─
out=$(YCA_TOOL_ARGS_JSON='{"file":"/etc/hosts"}' tool_media_transcribe "/etc/hosts" 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "media_transcribe accepted a source outside the fence (got: $out)"
# an invalid output format is rejected before any external call.
out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg f "$SB/clip.mp4" '{file:$f,format:"exe"}')" tool_media_transcribe "$SB/clip.mp4" 2>&1 || true)
echo "$out" | grep -qi 'format must be' || fail "media_transcribe accepted an invalid format (got: $out)"

# ── 10. doc.scan-to-pdf workflow is registered as a writes composite ───────────
[[ -n "${YCA_WF_REGISTRY[doc.scan-to-pdf]:-}" ]] || fail "doc.scan-to-pdf workflow not registered"
IFS='|' read -r _wf _tier _wd _rest <<< "${YCA_WF_REGISTRY[doc.scan-to-pdf]}"
[[ "$_wd" == "writes" ]] || fail "doc.scan-to-pdf should be danger=writes (got: $_wd)"

echo "media_doc_body OK"
