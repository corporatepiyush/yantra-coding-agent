# workflows/doc.sh — Document workflows

_doc_extract() {
    local filepath="$1" ext mime
    [[ ! -f "$filepath" ]] && { printf 'file not found'; return 1; }
    ext=$(path_ext "$filepath")
    mime=$(file --brief --mime-type "$filepath" 2>/dev/null || printf 'unknown')
    case "$ext" in
        md|txt|rst|org) cat "$filepath" ;;
        json) jq '.' "$filepath" 2>/dev/null || cat "$filepath" ;;
        yaml|yml)
            if command -v yq &>/dev/null; then yq '.' "$filepath" 2>/dev/null || cat "$filepath"
            else cat "$filepath"; fi ;;
        csv|tsv) head -50 "$filepath" ;;
        parquet)
            if command -v duckdb &>/dev/null; then duckdb -c "SELECT * FROM read_parquet('$filepath') LIMIT 50;" 2>/dev/null
            else printf 'install duckdb for parquet'; fi ;;
        pdf)
            if command -v pdftotext &>/dev/null; then pdftotext "$filepath" - 2>/dev/null | head -200
            else printf 'install poppler for PDF'; fi ;;
        docx)
            if command -v pandoc &>/dev/null; then pandoc -f docx -t markdown "$filepath" 2>/dev/null | head -200
            else printf 'install pandoc for DOCX'; fi ;;
        *)
            local size
            size=$(path_size "$filepath")
            if (( size < 1048576 )); then head -200 "$filepath"
            else head -200 "$filepath"; fi ;;
    esac
}

wf_doc_extract() {
    local file="${INPUT_file:-}"
    val_required "$file" "INPUT_file" || return 1
    path_check_allowed "$file" || { emit_error "403" "path outside allowed directory: $file"; return 1; }
    local out
    out=$(_doc_extract "$file")
    printf '%s\n' "$out" >&2
    emit_ok "extracted $file"
}

# doc.scan-to-pdf — assemble scanned page images into one SEARCHABLE PDF. With
# .enhance (auto by default when OpenCV is present) each page is first run through
# opencv_document_scan — find the page, warp it flat, threshold to clean B/W — so
# a stack of phone photos of a form becomes a crisp, deskewed, OCR'd document.
# Composes opencv (optional) + img2pdf/imagemagick + tesseract/ocrmypdf.
wf_doc_scan_to_pdf() {
    local files="${INPUT_files:-}"
    val_required "$files" "INPUT_files" || return 1
    printf '%s' "$files" | jq -e 'type=="array" and length>0' >/dev/null 2>&1 || { emit_fail "INPUT_files must be a non-empty JSON array of image paths"; return 1; }
    local out="${INPUT_out:-${YCA_PROJECT_DIR}/scan_${EPOCHSECONDS}.pdf}"
    path_check_allowed "$out" || { emit_error "403" "path outside allowed directory: $out"; return 1; }

    local scanned="$files"
    if [[ "${INPUT_enhance:-auto}" != "false" ]] && command -v python3 &>/dev/null && python3 -c 'import cv2' 2>/dev/null; then
        emit_progress "enhance" "deskew + threshold each page" 20
        local -a outs=(); local f res sp
        while IFS= read -r f; do
            [[ -n "$f" ]] || continue
            res=$(tool_invoke opencv_document_scan "$(jq -n --arg f "$f" '{file:$f}')")
            printf '%s\n' "$res" >&2
            sp="${f%.*}_scan.png"
            [[ -f "$sp" ]] && outs+=("$sp") || outs+=("$f")
        done < <(printf '%s' "$files" | jq -r '.[]?' 2>/dev/null)
        (( ${#outs[@]} > 0 )) && scanned=$(printf '%s\n' "${outs[@]}" | jq -R . | jq -cs .)
    fi

    emit_progress "assemble" "images -> pdf" 55
    local combined
    combined=$(tool_invoke doc_images_to_pdf "$(jq -cn --argjson f "$scanned" --arg o "$out" '{files:$f,out:$o}')")
    printf '%s\n' "$combined" >&2
    [[ -f "$out" ]] || { emit_fail "image->pdf step produced no file (need img2pdf or imagemagick): $combined"; return 1; }
    emit_progress "ocr" "adding searchable text layer" 80
    tool_invoke doc_ocr_pdf "$(jq -cn --arg f "$out" '{file:$f}')" >&2
    emit_ok "scan-to-pdf complete: $out"
}

# doc.save_article — fetch a public web article and save a clean, offline,
# Kindle-friendly copy. The fetch reuses browse's SSRF-vetted, protocol-pinned
# core (_browse_fetch); pandoc converts the raw HTML to Markdown (default), EPUB,
# or PDF, prepending the source URL + date. curl + pandoc — "save this to read
# later." Writes into articles/ (or .dir), never clobbers.
wf_doc_save_article() {
    local raw="${INPUT_url:-}"; val_required "$raw" "INPUT_url" || { emit_fail "INPUT_url required"; return 1; }
    command -v pandoc &>/dev/null || { emit_fail "pandoc required — brew install pandoc"; return 1; }
    local fmt="${INPUT_format:-md}" ext to
    case "$fmt" in
        md|markdown) ext=md;   to=gfm ;;
        epub)        ext=epub; to=epub ;;
        pdf)         ext=pdf;  to=pdf ;;
        html)        ext=html; to=html ;;
        *) emit_fail "format must be md|epub|pdf|html"; return 1 ;;
    esac
    local dir; dir=$(_wf_media_outdir "${INPUT_dir:-$YCA_PROJECT_DIR/articles}") || { emit_fail "output dir not allowed/creatable (check .dir)"; return 1; }

    emit_progress "fetch" "downloading page" 30
    local html; html=$(_browse_fetch "$raw" "text/html,text/plain") || { emit_fail "$html"; return 1; }
    [[ -n "${html// }" ]] || { emit_fail "empty page — the site may be JS-only or blocking automated fetches"; return 1; }

    # Title -> filename + a readable header. Fall back to a timestamped slug.
    local title; title=$(printf '%s' "$html" | grep -oiE '<title[^>]*>[^<]*' | head -1 | sed -E 's/<title[^>]*>//I' | tr -d '\r\n')
    local slug; slug=$(printf '%s' "${title:-article}" | tr -cs 'A-Za-z0-9' '-' | sed -E 's/^-+//; s/-+$//' | cut -c1-80)
    [[ -z "$slug" ]] && slug="article-$(now_stamp)"
    local out="$dir/${slug}.${ext}"; [[ -e "$out" ]] && out="$dir/${slug}_$(now_stamp).${ext}"

    emit_progress "convert" "pandoc html -> $fmt" 70
    local tmp; tmp=$(path_temp_file yca-article .html)
    { printf '<!-- Saved by Yantra from %s on %s -->\n' "$raw" "$(date_now)"; printf '%s' "$html"; } > "$tmp"
    local perr
    if perr=$(pandoc "$tmp" -f html -t "$to" -o "$out" </dev/null 2>&1) && [[ -f "$out" ]]; then
        rm -f "$tmp"; emit_ok "saved article${title:+ \"$title\"}: $out"; return 0
    fi
    rm -f "$tmp"
    emit_fail "pandoc conversion to $fmt failed${perr:+: $(printf '%s' "$perr" | head -2)} (pdf output needs a LaTeX or wkhtmltopdf engine)"
    return 1
}

wf_register "doc.extract"      wf_doc_extract      1 safe   "" "Extract document content"
wf_register "doc.scan-to-pdf"  wf_doc_scan_to_pdf  1 writes "" "Scanned images -> deskewed, searchable PDF"
wf_register "doc.save_article" wf_doc_save_article 1 writes "curl" "Fetch a web article and save it offline (Markdown/EPUB/PDF)"
