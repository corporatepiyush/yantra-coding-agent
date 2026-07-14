#!/usr/bin/env bash
# Test: Media & Documents depth act-half. New tools (media_compress/crop/rotate/
# subtitles/watermark_logo, doc_compress/ocr_pdf/images_to_pdf) are registered
# with correct danger tokens; every media/doc WRITE tool is consent-gated in
# machine mode; outputs are path-fenced + no-clobber; format args can't smuggle
# path separators; doc_extract supports offset paging; media_transcribe is
# retagged writes. All checks are OFFLINE — they exercise the guard/validation
# paths that run before ffmpeg/gs/tesseract/pandoc/whisper are ever invoked.
set -uo pipefail
HARNESS="$1"; TMP="$2"
YCA_DIR="$(cd "$(dirname "$HARNESS")" && pwd)"
OUT=$(bash "$YCA_DIR/tests/test_scripts/media_doc_body.sh" "$YCA_DIR" "$TMP" 2>&1) || { echo "$OUT"; exit 1; }
echo "$OUT" | grep -q "media_doc_body OK" || { echo "$OUT"; exit 1; }
echo "media_doc OK"
exit 0
