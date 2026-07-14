# tools/doc.sh — Document tools: extract text from any format + LLM-backed
# summarize / README / docstring generation. Lets a junior turn a PDF/DOCX/
# spec into something actionable, and produce docs a senior would write.

_doc_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

_doc_guard() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
}

# extract — pull plain text out of md/txt/pdf/docx/csv/json/yaml/html. Paged via
# offset (lines to skip) + max_lines (default 2000, was a hard head -100…400 cap
# that silently truncated real documents). For PDFs, `page` (N or N-M) restricts
# extraction to a page range.
tool_doc_extract() {
    local file="$1"; _doc_guard "$file" || return 1
    local offset max_lines start page
    offset=$(int_guard "$(tool_arg offset 0)" 0)
    max_lines=$(int_guard "$(tool_arg max_lines 2000)" 2000)
    start=$((offset + 1))
    page=$(tool_arg page "")
    case "$(path_ext "$file")" in
        md|txt|rst|org|adoc) tail -n +"$start" "$file" | head -n "$max_lines" ;;
        json)  { jq '.' "$file" 2>/dev/null || cat "$file"; } | tail -n +"$start" | head -n "$max_lines" ;;
        yaml|yml) { command -v yq &>/dev/null && yq '.' "$file" 2>/dev/null || cat "$file"; } | tail -n +"$start" | head -n "$max_lines" ;;
        csv|tsv) tail -n +"$start" "$file" | head -n "$max_lines" ;;
        pdf)
            command -v pdftotext &>/dev/null || { _doc_missing pdftotext "brew install poppler"; return 1; }
            local -a prange=()
            if [[ -n "$page" && "$page" != "null" ]]; then
                [[ "$page" =~ ^[0-9]+(-[0-9]+)?$ ]] || { printf 'page must be N or N-M'; return 1; }
                prange=(-f "${page%-*}" -l "${page#*-}")
            fi
            pdftotext -layout "${prange[@]}" "$file" - 2>/dev/null | tail -n +"$start" | head -n "$max_lines" ;;
        docx)  command -v pandoc &>/dev/null || { _doc_missing pandoc "brew install pandoc"; return 1; }
            pandoc -f docx -t markdown "$file" 2>/dev/null | tail -n +"$start" | head -n "$max_lines" ;;
        html|htm) { if command -v pandoc &>/dev/null; then pandoc -f html -t markdown "$file" 2>/dev/null; else sed 's/<[^>]*>//g' "$file"; fi; } | tail -n +"$start" | head -n "$max_lines" ;;
        *)     tail -n +"$start" "$file" | head -n "$max_lines" ;;
    esac
}

# convert — pandoc format conversion (md->pdf/html/docx, etc). The output was
# silently overwriting whatever sibling already sat at <stem>.<format>; it is now
# path-fenced and no-clobber (an existing target needs consent).
tool_doc_convert() {
    local file="$1"; _doc_guard "$file" || return 1
    local to; to=$(tool_arg format html)
    # format becomes the output extension — keep it a bare alnum token.
    [[ "$to" =~ ^[A-Za-z0-9]+$ ]] || { printf 'format must be alphanumeric (e.g. html, pdf, docx)'; return 1; }
    local out="${file%.*}.$to"
    [[ "$out" == "$file" ]] && { printf 'output would overwrite the source; choose a different format'; return 1; }
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    _doc_noclobber "$out" || return 1
    command -v pandoc &>/dev/null || { _doc_missing pandoc "brew install pandoc"; return 1; }
    pandoc "$file" -o "$out" 2>&1 && printf 'converted %s -> %s' "$file" "$out"
}

# llm_summarize — extract then summarize a document to key points.
tool_doc_llm_summarize() {
    local file="$1"; _doc_guard "$file" || return 1
    local text; text=$(tool_doc_extract "$file")
    local system_prompt='ROLE: Document summarizer. Summarize the extracted document below faithfully.

Output exactly these sections, in order:
- TITLE: the document title/subject in one line.
- TYPE: what kind of document (spec / report / README / paper / contract / manual / slide deck / …).
- OVERVIEW: 2-3 sentences on purpose and main thesis.
- KEY POINTS: 5-8 bullets of substantive content, in document order; name the section/heading each comes from where the document has headings.
- TAKEAWAYS: conclusions, decisions, figures, dates, names, or action items — kept EXACT.

Faithfulness rules (strict): use ONLY content present in the document; never add outside knowledge or infer beyond the text; keep names, numbers, and dates exact (do not round or paraphrase). If the text is truncated or garbled, say so instead of guessing. No preamble before TITLE and no meta commentary after TAKEAWAYS.'
    llm_analyze "$system_prompt" "$text"
}

# llm_web_summarize — fetch a URL and summarize its main content. Reuses
# tool_browse (SSRF guards + tag stripping), then hands the noisy extracted text
# to the model with a header that tells it to discard page boilerplate. Small
# local models summarize web pages poorly without this instruction — the raw
# text is full of nav menus, cookie banners, and inline script fragments.
tool_doc_llm_web_summarize() {
    local url="$1"; [[ -n "$url" ]] || { printf 'url required (.url)'; return 1; }
    local text; text=$(tool_browse "$url")
    # tool_browse returns a short refusal/error string on failure (no page body).
    case "$text" in
        'refusing to fetch'*|'invalid or unsafe url'*|'curl required'*|'')
            printf 'could not fetch %s: %s' "$url" "${text:-empty response}"; return 1 ;;
    esac
    local system_prompt='ROLE: Web page summarizer. The text below was auto-extracted from a web page and is NOISY — it interleaves the real article with navigation menus, breadcrumbs, cookie/consent banners, ads, "related articles" and "you may also like" lists, comment sections, login/subscribe prompts, and stray JavaScript/CSS. First mentally SEPARATE the main article/body from that boilerplate; summarize ONLY the main content.

Output exactly these sections, in order:
- TITLE: the article/page title in one line.
- TYPE: what kind of page this is (news article / reference / tutorial / API docs / product page / blog / forum thread / …).
- OVERVIEW: 2-3 sentences on what it covers and its central claim or purpose.
- KEY POINTS: 5-8 bullets of the substantive content, in the article'"'"'s own order. Where the page has headings/sections, name the section a point comes from.
- TAKEAWAYS: concrete conclusions, figures, dates, names, or action items — kept EXACT (do not round or paraphrase numbers).

Faithfulness rules (strict):
- Use ONLY facts present in the extracted text. Never add outside knowledge, and never infer beyond what is written.
- If a fact is ambiguous or the extraction looks truncated/garbled, say so rather than guessing.
- If the extracted text is mostly navigation/boilerplate, or is a login/paywall/error/consent wall, or looks like a JS-only shell with no real article, DO NOT fabricate a summary — state plainly that the main content was not retrievable (and that a JS-rendering fetch may be needed).
- Keep it tight and plainly worded; no preamble before TITLE and no meta commentary after TAKEAWAYS.'
    llm_analyze "$system_prompt" "$text"
}

# llm_readme — generate a README from project structure + entry files.
tool_doc_llm_readme() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    path_check_allowed "$dir" 2>/dev/null || { printf 'path not allowed'; return 1; }
    local tree manifests entry
    tree=$(find "$dir" -maxdepth 2 -type f -not -path '*/.git/*' -not -path '*/node_modules/*' 2>/dev/null | head -60)
    manifests=""
    local m
    for m in package.json pyproject.toml Cargo.toml go.mod pom.xml composer.json Gemfile; do
        [[ -f "$dir/$m" ]] && manifests+="=== $m ===
$(head -40 "$dir/$m")

"
    done
    entry=$(find "$dir" -maxdepth 2 \( -name 'main.*' -o -name 'index.*' -o -name 'app.*' -o -name '__main__.py' \) -not -path '*/node_modules/*' 2>/dev/null | head -3)
    local combined
    combined=$(printf 'PROJECT: %s\n\n=== FILE TREE ===\n%s\n\n=== MANIFESTS ===\n%s\n=== ENTRY POINTS ===\n%s' \
        "$(basename "$dir")" "$tree" "$manifests" "$entry")
    local system_prompt='You are writing a README.md for this project. Produce Markdown with: title, one-line description, badges placeholder, Features, Requirements, Installation, Usage (with a runnable example), Project structure, and Contributing. Infer language/toolchain from the manifests. Do NOT invent features not evidenced by the files — mark uncertain sections with TODO.'
    llm_analyze "$system_prompt" "$combined"
}

# llm_docstring — draft docstrings/comments for a source file (proposal only).
tool_doc_llm_docstring() {
    local file="$1"; _doc_guard "$file" || return 1
    local content; content=$(<"$file")
    local system_prompt='You are documenting source code. For each public function/class/method in the file below, propose a docstring/comment in the language and style already used in the file (detect it). Output a list of {symbol, line, proposed_docstring}. Do NOT rewrite the code. Do NOT document trivial getters. Base every description on what the code actually does.'
    llm_analyze "$system_prompt" "$content"
}

# pdf_info — page count + metadata.
tool_doc_pdf_info() {
    local file="$1"; _doc_guard "$file" || return 1
    command -v pdfinfo &>/dev/null && { pdfinfo "$file" 2>&1; return 0; }
    command -v qpdf &>/dev/null && { printf 'pages: %s\n' "$(qpdf --show-npages "$file" 2>/dev/null)"; return 0; }
    _doc_missing pdfinfo "brew install poppler"; return 1
}

# pdf_merge — combine several PDFs into one.
tool_doc_pdf_merge() {
    local files; files=$(tool_arg files)
    [[ -n "$files" && "$files" != "null" ]] || { printf 'files (JSON array of pdf paths) required'; return 1; }
    local out; out=$(tool_arg out "${YCA_PROJECT_DIR}/merged_${EPOCHSECONDS}.pdf")
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    local -a paths=(); local f
    while IFS= read -r f; do
        [[ -f "$f" ]] && path_check_allowed "$f" 2>/dev/null && paths+=("$f") || { printf 'input missing/not allowed: %s' "$f"; return 1; }
    done < <(printf '%s' "$files" | jq -r '.[]?' 2>/dev/null)
    [[ ${#paths[@]} -ge 2 ]] || { printf 'need >=2 pdfs'; return 1; }
    if command -v pdfunite &>/dev/null; then pdfunite "${paths[@]}" "$out" 2>&1 && printf 'merged: %s' "$out"
    elif command -v qpdf &>/dev/null; then qpdf --empty --pages "${paths[@]}" -- "$out" 2>&1 && printf 'merged: %s' "$out"
    else _doc_missing pdfunite "brew install poppler (pdfunite) or qpdf"; return 1; fi
}

# pdf_split — extract a page range into a new PDF.
tool_doc_pdf_split() {
    local file="$1"; _doc_guard "$file" || return 1
    local range; range=$(tool_arg pages "1-1")
    [[ "$range" =~ ^[0-9]+(-[0-9]+)?$ ]] || { printf 'pages must be N or N-M'; return 1; }
    local out; out=$(_doc_out "$file" "_p${range}" pdf) || { printf 'output path not allowed'; return 1; }
    if command -v qpdf &>/dev/null; then qpdf "$file" --pages "$file" "$range" -- "$out" 2>&1 && printf 'split: %s' "$out"
    elif command -v pdfseparate &>/dev/null; then
        local first="${range%-*}" last="${range#*-}"
        pdfseparate -f "$first" -l "$last" "$file" "${out%.pdf}_%d.pdf" 2>&1 && printf 'split pages %s' "$range"
    else _doc_missing qpdf "brew install qpdf"; return 1; fi
}

# ocr — image/scanned-PDF → text via tesseract. Paged via offset + max_lines
# (default 2000, was a hard head -400 cap).
tool_doc_ocr() {
    local file="$1"; _doc_guard "$file" || return 1
    local lang offset max_lines start; lang=$(tool_arg lang eng)
    case "$(str_lower "$lang")" in *[^a-z+]*) printf 'invalid lang'; return 1 ;; esac
    offset=$(int_guard "$(tool_arg offset 0)" 0); start=$((offset + 1))
    max_lines=$(int_guard "$(tool_arg max_lines 2000)" 2000)
    command -v tesseract &>/dev/null || { _doc_missing tesseract "brew install tesseract"; return 1; }
    tesseract "$file" stdout -l "$lang" 2>/dev/null | tail -n +"$start" | head -n "$max_lines" || printf '(no text recognized)'
}

# images — extract embedded images from a PDF.
tool_doc_extract_images() {
    local file="$1"; _doc_guard "$file" || return 1
    command -v pdfimages &>/dev/null || { _doc_missing pdfimages "brew install poppler"; return 1; }
    local dest; dest=$(tool_arg out "${YCA_PROJECT_DIR}/pdf_images_${EPOCHSECONDS}")
    path_check_allowed "$dest" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    path_ensure_dir "$dest"
    pdfimages -all "$file" "$dest/img" 2>&1 && printf 'extracted images to %s (%s files)' "$dest" "$(find "$dest" -type f | wc -l | tr -d ' ')"
}

# _doc_out FILE SUFFIX EXT -> sibling output path, path-checked.
_doc_out() {
    # `out` on its own line — see the note in media.sh _media_out: a single
    # `local file=$1 … out=${file…}` expands the derived path against the still-
    # empty outer scope, collapsing every output path to ".".
    local file="$1" suffix="$2" ext="$3"
    local out="${file%.*}${suffix}.${ext}"
    path_check_allowed "$out" 2>/dev/null || { printf ''; return 1; }
    printf '%s' "$out"
}

# _doc_noclobber OUT — never silently overwrite a pre-existing (different) file.
# Fresh output passes through; an existing one needs consent (auto-denied in
# machine mode without auto_confirm, prompted in human/CLI mode).
_doc_noclobber() {
    local out="$1"
    [[ -e "$out" ]] || return 0
    confirm_action "Overwrite existing file: $out" "overwrite $out" && return 0
    printf 'refusing to overwrite existing file (no-clobber) — pass a new name or confirm: %s' "$out"
    return 1
}

# compress — shrink a PDF via Ghostscript's -dPDFSETTINGS presets. Output is a
# fenced sibling; the source is never touched.
tool_doc_compress() {
    local file="$1"; _doc_guard "$file" || return 1
    [[ "$(path_ext "$file")" == "pdf" ]] || { printf 'compress expects a .pdf'; return 1; }
    local quality out; quality=$(tool_arg quality ebook)
    case "$quality" in screen|ebook|printer|prepress|default) ;; *) printf 'quality must be screen|ebook|printer|prepress|default'; return 1 ;; esac
    out=$(_doc_out "$file" "_compressed" pdf) || { printf 'output path not allowed'; return 1; }
    _doc_noclobber "$out" || return 1
    command -v gs &>/dev/null || { _doc_missing gs "brew install ghostscript"; return 1; }
    cmd_wrote "$out" "compressed ($quality): $out" \
        gs -sDEVICE=pdfwrite -dCompatibilityLevel=1.4 -dPDFSETTINGS="/$quality" \
           -dNOPAUSE -dQUIET -dBATCH -sOutputFile="$out" "$file"
}

# ocr_pdf — produce a SEARCHABLE PDF (text layer over the scan). Prefers ocrmypdf;
# falls back to tesseract's `pdf` config, which is multipage for a PDF/TIFF input.
tool_doc_ocr_pdf() {
    local file="$1"; _doc_guard "$file" || return 1
    local lang out; lang=$(tool_arg lang eng)
    case "$(str_lower "$lang")" in *[^a-z+]*) printf 'invalid lang'; return 1 ;; esac
    out=$(_doc_out "$file" "_ocr" pdf) || { printf 'output path not allowed'; return 1; }
    _doc_noclobber "$out" || return 1
    if command -v ocrmypdf &>/dev/null; then
        cmd_wrote "$out" "searchable pdf: $out" ocrmypdf -l "$lang" --force-ocr "$file" "$out"
    elif command -v tesseract &>/dev/null; then
        # tesseract appends .pdf to the stem, so hand it the stem, not the full path.
        cmd_wrote "$out" "searchable pdf: $out" tesseract "$file" "${out%.pdf}" -l "$lang" pdf
    else
        _doc_missing ocrmypdf "pip install ocrmypdf  /  brew install tesseract"; return 1
    fi
}

# images_to_pdf — combine images into one PDF (img2pdf is lossless; imagemagick
# is the fallback). Both the output and every input image are path-fenced.
tool_doc_images_to_pdf() {
    local files; files=$(tool_arg files)
    [[ -n "$files" && "$files" != "null" ]] || { printf 'files (JSON array of image paths) required'; return 1; }
    local out; out=$(tool_arg out "${YCA_PROJECT_DIR}/images_${EPOCHSECONDS}.pdf")
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    _doc_noclobber "$out" || return 1
    local -a paths=(); local f
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        [[ -f "$f" ]] && path_check_allowed "$f" 2>/dev/null && paths+=("$f") || { printf 'input missing/not allowed: %s' "$f"; return 1; }
    done < <(printf '%s' "$files" | jq -r '.[]?' 2>/dev/null)
    [[ ${#paths[@]} -ge 1 ]] || { printf 'need >=1 image'; return 1; }
    if command -v img2pdf &>/dev/null; then cmd_wrote "$out" "pdf: $out" img2pdf "${paths[@]}" -o "$out"
    elif command -v convert &>/dev/null; then cmd_wrote "$out" "pdf: $out" convert "${paths[@]}" "$out"
    else _doc_missing img2pdf "pip install img2pdf  /  brew install imagemagick"; return 1; fi
}

tool_doc_doctor() {
    local out="" t
    for t in pandoc pdftotext pdfinfo pdfunite pdfimages pdfseparate qpdf tesseract ocrmypdf img2pdf gs yq wkhtmltopdf; do
        out+="$t: $(command -v "$t" &>/dev/null && printf 'ok' || printf 'not installed')\n"
    done
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "doc_extract"        tool_doc_extract        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all doc
tool_register "doc_convert"        tool_doc_convert        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"format":{"type":"string","description":"the output format"}},"required":["file","format"]}' writes all doc
tool_register "doc_pdf_info"       tool_doc_pdf_info       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all doc
tool_register "doc_pdf_merge"      tool_doc_pdf_merge      '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"list of file paths relative to the project root"},"out":{"type":"string","description":"output path"}},"required":["files"]}' writes all doc
tool_register "doc_pdf_split"      tool_doc_pdf_split      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"pages":{"type":"string","description":"the pages"}},"required":["file","pages"]}' writes all doc
tool_register "doc_ocr"            tool_doc_ocr            '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"lang":{"type":"string","description":"the programming language"}},"required":["file"]}' safe all doc
tool_register "doc_extract_images"         tool_doc_extract_images         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"out":{"type":"string","description":"output path"}},"required":["file"]}' writes all doc
tool_register "doc_compress"       tool_doc_compress       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"quality":{"type":"string","description":"screen|ebook|printer|prepress|default"}},"required":["file"]}' writes all doc
tool_register "doc_ocr_pdf"        tool_doc_ocr_pdf        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"lang":{"type":"string","description":"the programming language"}},"required":["file"]}' writes all doc
tool_register "doc_images_to_pdf"  tool_doc_images_to_pdf  '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"list of file paths relative to the project root"},"out":{"type":"string","description":"output path"}},"required":["files"]}' writes all doc
tool_register "doc_llm_summarize"  tool_doc_llm_summarize  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all doc mid
tool_register "doc_llm_web_summarize" tool_doc_llm_web_summarize '{"type":"object","properties":{"url":{"type":"string","description":"http(s) URL to fetch and summarize"}},"required":["url"]}' safe all doc mid
tool_register "doc_llm_readme"     tool_doc_llm_readme     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all doc mid
tool_register "doc_llm_docstring"  tool_doc_llm_docstring  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all doc mid
tool_register "doc_doctor"         tool_doc_doctor         '{"type":"object","properties":{}}' safe all doc
