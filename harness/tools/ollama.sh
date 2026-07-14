# tools/ollama.sh — Ollama / local-LLM tools: manage local models (list/pull/run/
# show/ps/stop), advanced ops (create/cp/rm/push/embed/chat/raw API), and
# maintenance (doctor/version/serve-status/disk/prune/logs), plus model-file &
# notebook inspection and endpoint tests. Helps a junior run local LLMs without
# deep MLOps knowledge. Category: ollama.

_ollama_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# _ollama_strip — the ollama CLI paints a progress spinner (CSI escapes + braille
# glyphs + carriage returns) even when stdout is a pipe, which pollutes tool
# output. Strip ANSI/CSI sequences and braille spinner glyphs (U+2800..U+28FF)
# and CRs, leaving real text (incl. other unicode) intact. Pure sed+tr, no
# perl/python; LC_ALL=C makes the byte ranges match regardless of locale.
_ollama_strip() {
    LC_ALL=C sed -e $'s/\x1b\\[[0-9;?]*[a-zA-Z]//g' -e $'s/\xe2[\xa0-\xa3][\x80-\xbf]//g' | tr -d '\r'
}

# _ollama_api_err RESP — echo the API error message if the JSON has an `.error`
# field (Ollama returns HTTP 200 with {"error":...} for bad model / unsupported
# op), else nothing. Lets callers turn a soft error into a real failure.
_ollama_api_err() { printf '%s' "$1" | jq -r 'if type=="object" then (.error // empty) else empty end' 2>/dev/null; }

# _ollama_read_ok PATH — path guard for model/inspection files. Allows the
# project dir (path_check_allowed) OR a known model/cache directory, since model
# files legitimately live outside the project (~/.ollama, $OLLAMA_MODELS, …).
_ollama_read_ok() {
    local p="$1" d
    path_check_allowed "$p" 2>/dev/null && return 0
    for d in "${OLLAMA_MODELS:-$HOME/.ollama/models}" "$HOME/.ollama" "$HOME/models" "$HOME/.cache/huggingface" "$HOME/.cache/lm-studio"; do
        [[ "$p" == "$d"/* ]] && return 0
    done
    return 1
}
_ollama_path_msg() { printf 'path not allowed: %s\n(allowed: the project dir, or a model dir: ~/.ollama, $OLLAMA_MODELS, ~/models, ~/.cache/huggingface)' "$1"; }

# run — one-shot prompt against a local ollama model.
tool_ollama_run() {
    command -v ollama &>/dev/null || { _ollama_missing ollama "brew install ollama"; return 1; }
    local model="$1"; [[ -n "$model" ]] || { printf 'model name required'; return 1; }
    local prompt; prompt=$(tool_arg content "$(tool_arg description '')")
    [[ -n "$prompt" ]] || { printf 'prompt required (use .content)'; return 1; }
    printf '%s' "$prompt" | ollama run "$model" 2>&1 | _ollama_strip | head -60
}

# model_info — inspect a model file's metadata (gguf/safetensors/onnx).
tool_ollama_model_info() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'model file required'; return 1; }
    _ollama_read_ok "$file" || { _ollama_path_msg "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    local size; size=$(path_size "$file" 2>/dev/null || printf '?')
    printf 'file: %s\nsize: %s bytes\ntype: %s\n' "$file" "$size" "$(path_ext "$file")"
    case "$(path_ext "$file")" in
        gguf)  command -v gguf-dump &>/dev/null && gguf-dump "$file" 2>&1 | head -40 || printf '(install gguf tooling for header details)\n' ;;
        safetensors) _ollama_safetensors_keys "$file" ;;
        onnx)  # ONNX is protobuf; without a lib we surface readable tensor/op
               # names via `strings` as a best-effort summary (no python dep).
               command -v strings &>/dev/null \
                 && strings "$file" 2>/dev/null | grep -Ei '(input|output|conv|gemm|matmul|relu|softmax|weight|bias)' | sort -u | head -30 \
                 || printf '(install binutils `strings` for an onnx summary)\n' ;;
        *) : ;;
    esac
}

# _ollama_safetensors_keys FILE — list tensor names from a .safetensors header
# without any python runtime. Format: 8-byte little-endian header length, then
# that many bytes of JSON. We read the length with `od`, slice the JSON with
# `dd`, and pull keys with `jq`.
_ollama_safetensors_keys() {
    local file="$1"
    command -v jq &>/dev/null || { printf '(install jq to inspect safetensors)\n'; return 0; }
    local n
    n=$(od -An -N8 -tu8 "$file" 2>/dev/null | tr -d ' ')
    [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 && n < 100000000 )) || { printf '(unreadable safetensors header)\n'; return 0; }
    dd if="$file" bs=1 skip=8 count="$n" 2>/dev/null \
        | jq -r 'keys_unsorted | map(select(. != "__metadata__")) | .[0:30] | .[]' 2>/dev/null \
        | head -30 || printf '(unreadable safetensors header)\n'
}

# notebook — convert a Jupyter notebook to a readable script/markdown.
tool_ollama_notebook() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'notebook (.ipynb) required'; return 1; }
    _ollama_read_ok "$file" || { _ollama_path_msg "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    if command -v jupyter &>/dev/null; then
        jupyter nbconvert --to script --stdout "$file" 2>/dev/null | head -200
    else
        # jq fallback: dump code cells.
        jq -r '.cells[] | select(.cell_type=="code") | .source | join("")' "$file" 2>/dev/null | head -200 \
            || printf '(install jupyter for full conversion)'
    fi
}

# endpoint_test — sanity-check each configured LLM provider tier.
tool_ollama_endpoint_test() {
    command -v curl &>/dev/null || { _ollama_missing curl "brew install curl"; return 1; }
    if [[ "$YCA_HAVE_LLM" != "1" ]]; then
        printf 'No LLM provider configured. Add one under "providers" in %s or set HARNESS_LLM_URL.\n' "${YCA_CONFIG_PROJECT_PATH:-yantra.config.json}"
        return 1
    fi
    local tier url model token
    for tier in think build tool; do
        IFS=$'\t' read -r url model token < <(provider_resolve "$tier" 2>/dev/null)
        [[ -z "$url" ]] && { printf '%-6s: (no provider)\n' "$tier"; continue; }
        printf '%-6s: %s (model: %s)\n' "$tier" "$url" "$model"
        curl -sS --max-time 10 -H @<(printf 'Authorization: Bearer %s\n' "$token") "$url/models" 2>&1 \
            | jq -r '.data[]?.id // .' 2>/dev/null | head -10 \
            || printf '  (no /models response — check the URL/token)\n'
    done
}

# llm_prompt_review — critique a prompt template for robustness.
tool_ollama_llm_prompt_review() {
    local file="$1" content
    if [[ -f "$file" ]]; then
        path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed'; return 1; }
        content=$(<"$file")
    else
        content=$(tool_arg content "$file")
    fi
    [[ -n "$content" ]] || { printf 'prompt file or .content required'; return 1; }
    local system_prompt='You are a prompt engineer. Review the prompt/template below for: clear role and task, explicit output format, grounding/anti-hallucination instructions, injection resistance (untrusted input handling), few-shot quality, and token efficiency. Report concrete improvements with a rewritten example.'
    llm_analyze "$system_prompt" "$content"
}

tool_ollama_doctor() {
    local out="" t
    if [[ "$YCA_HAVE_LLM" == "1" ]]; then
        local url; url=$(provider_resolve tool 2>/dev/null | cut -f1)
        out+="LLM providers: configured (tool-tier: ${url:-?})\n"
    else
        out+="LLM providers: none configured (LLM-backed tools unavailable)\n"
    fi
    for t in ollama jupyter gguf-dump; do
        out+="$t: $(command -v "$t" &>/dev/null && printf 'ok' || printf 'not installed')\n"
    done
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
# ── The local ollama daemon (NOT the configured LLM provider tiers) ──────────
_ollama_host() { printf '%s' "${OLLAMA_HOST:-http://localhost:11434}"; }

# _ollama_gen_extra — build the tunable extras (options{} + format) from the
# tool's raw args, to merge into an /api/chat or /api/generate body. Users may
# pass a whole `options` object (any Ollama option, incl. new ones) and/or the
# common scalars as top-level shortcuts; a top-level `format` ("json" or a JSON
# schema object) enables structured/constrained output. Emits {} when none set,
# so callers can always `+ $x` safely. Unknown keys are ignored by Ollama.
_ollama_gen_extra() {
    local out
    out=$(printf '%s' "${YCA_TOOL_ARGS_JSON:-$YCA_EMPTY_JSON}" | jq -c '
        . as $root
        | (($root.options // {})
          + (reduce ("temperature","top_k","top_p","min_p","repeat_penalty",
                     "presence_penalty","frequency_penalty","num_ctx","num_predict",
                     "num_keep","seed","stop","tfs_z","typical_p","mirostat",
                     "mirostat_tau","mirostat_eta") as $k
                ({}; if ($root[$k] // null) != null then . + {($k): $root[$k]} else . end))
        ) as $o
        | {}
          + (if ($o|length) > 0 then {options:$o} else {} end)
          + (if ($root.format // null) != null then {format:$root.format} else {} end)
    ' 2>/dev/null)
    # Emit exactly once. Guard against a bad/empty jq result so the caller's
    # `--argjson` always receives a single valid object.
    [[ "$out" == \{* ]] && printf '%s' "$out" || printf '{}'
}

# embed — embedding vector for text via the local daemon's /api/embeddings.
tool_ollama_embed() {
    command -v curl &>/dev/null || { _ollama_missing curl "brew install curl"; return 1; }
    local model="$1"; [[ -n "$model" ]] || { printf 'model name required (e.g. nomic-embed-text)'; return 1; }
    local text; text=$(tool_arg content "$(tool_arg prompt '')")
    [[ -n "$text" ]] || { printf 'text required (.content)'; return 1; }
    local resp; resp=$(curl -sS --max-time 30 "$(_ollama_host)/api/embeddings" \
        -d "$(jq -n --arg m "$model" --arg p "$text" '{model:$m,prompt:$p}')" 2>&1) \
        || { printf 'request failed: %s' "$resp"; return 1; }
    local e; e=$(_ollama_api_err "$resp"); [[ -n "$e" ]] && { printf 'ollama error: %s' "$e"; return 1; }
    # Emit the FULL vector as JSON so it's usable downstream (RAG, similarity,
    # dedup). The old output was "dim: N + first 8 floats" — the vector was
    # discarded, which blocked every embedding use case.
    printf '%s' "$resp" | jq -c --arg m "$model" 'if .embedding then {model:$m,dim:(.embedding|length),embedding:.embedding} else . end' 2>/dev/null || printf '%s' "$resp"
}

# ollama_extract — pull schema-constrained JSON out of text. Routes through the tiered
# provider (llm_analyze) and CONSTRAINS the output with response_format, so it
# works local or paid and returns guaranteed JSON (not merely asked-for).
tool_ollama_extract() {
    local content schema instr
    content=$(tool_arg content "$(tool_arg text '')"); [[ -n "$content" ]] || { printf 'content required (.content)'; return 1; }
    schema=$(tool_arg schema); instr=$(tool_arg instruction 'Extract the key fields as JSON.')
    local sys="You extract structured data and return ONLY valid JSON. $instr Use only facts present in the input; use null for anything absent — never invent values."
    if [[ -n "$schema" ]]; then llm_analyze "$sys" "$content" 2048 mid "$schema"
    else llm_analyze "$sys" "$content" 2048 mid json; fi
}

# ── RAG (retrieval) over a DuckDB vector store ───────────────────────────────
# DuckDB is already a dependency: it persists to a file, has native
# list_cosine_similarity, and reads many source formats — so no hand-rolled
# cosine and no new heavy dep. Store: chunks(source, idx, text, embedding DOUBLE[]).
_rag_db() { printf '%s' "${YANTRA_RAG_DB:-$YCA_PROJECT_DIR/.yantra-rag.duckdb}"; }

# _rag_embed MODEL TEXT -> embedding as a JSON array (= a valid DuckDB list
# literal), or fail. Uses tool_ollama_embed (which now returns the full vector).
_rag_embed() {
    local model="$1" text="$2" out vec
    out=$(YCA_TOOL_ARGS_JSON="$(jq -cn --arg c "$text" '{content:$c}')" tool_ollama_embed "$model" 2>&1) || return 1
    vec=$(printf '%s' "$out" | jq -c '.embedding // empty' 2>/dev/null)
    [[ -n "$vec" ]] || return 1
    printf '%s' "$vec"
}

# _rag_search DB QVEC K -> top-K chunks by cosine similarity to QVEC (a JSON
# list). Split out so the DuckDB store + similarity is testable with fixed
# vectors (no embed model needed). QVEC is numeric-only (no injection surface).
_rag_search() {
    local db="$1" qvec="$2" k="$3"
    [[ "$k" =~ ^[0-9]+$ ]] || k=5
    duckdb "$db" "SELECT source, idx, round(list_cosine_similarity(embedding, ${qvec}::DOUBLE[]), 4) AS score, left(text, 240) AS preview FROM chunks ORDER BY score DESC LIMIT ${k};" 2>&1
}

# ollama_rag_index — chunk + embed a file into the DuckDB vector store.
tool_ollama_rag_index() {
    command -v duckdb &>/dev/null || { printf 'duckdb required (brew install duckdb)'; return 1; }
    local file model; file=$(tool_arg file "${1:-}"); model=$(tool_arg model nomic-embed-text)
    [[ -n "$file" ]] || { printf 'file required (.file)'; return 1; }
    path_check_allowed "$file" || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    local text
    if declare -F tool_doc_extract >/dev/null 2>&1 && [[ "$file" =~ \.(pdf|docx|odt|html?|epub|rtf)$ ]]; then
        text=$(YCA_TOOL_ARGS_JSON='{}' tool_doc_extract "$file" 2>/dev/null)
    else
        text=$(<"$file")
    fi
    [[ -n "$text" ]] || { printf 'no text extracted from %s' "$file"; return 1; }
    local db nd idx=0 chunk vec; db=$(_rag_db); nd=$(path_temp_file yca-rag .ndjson)
    while IFS= read -r chunk; do
        [[ -z "${chunk// }" ]] && continue
        vec=$(_rag_embed "$model" "$chunk") || continue
        jq -cn --arg s "$file" --argjson i "$idx" --arg t "$chunk" --argjson e "$vec" \
            '{source:$s,idx:$i,text:$t,embedding:$e}' >> "$nd"
        (( idx++ ))
    done < <(printf '%s' "$text" | fold -s -w 1500)
    (( idx == 0 )) && { rm -f "$nd"; printf 'no chunks embedded — is the embed model "%s" pulled and ollama running?' "$model"; return 1; }
    duckdb "$db" "CREATE TABLE IF NOT EXISTS chunks(source VARCHAR, idx INTEGER, text VARCHAR, embedding DOUBLE[]); INSERT INTO chunks SELECT source, idx, text, embedding::DOUBLE[] FROM read_json_auto('$nd');" 2>&1
    rm -f "$nd"
    printf 'indexed %d chunk(s) from %s into %s' "$idx" "$file" "$db"
}

# ollama_rag_query — semantic (top-k) search over the RAG index.
tool_ollama_rag_query() {
    command -v duckdb &>/dev/null || { printf 'duckdb required'; return 1; }
    local query model k; query=$(tool_arg query "$(tool_arg content '')"); model=$(tool_arg model nomic-embed-text)
    k=$(int_guard "$(tool_arg k 5)" 5); (( k > 50 )) && k=50; (( k < 1 )) && k=1
    [[ -n "$query" ]] || { printf 'query required (.query)'; return 1; }
    local db; db=$(_rag_db)
    [[ -f "$db" ]] || { printf 'no RAG index yet — run ollama_rag_index first'; return 1; }
    local qvec; qvec=$(_rag_embed "$model" "$query") || { printf 'could not embed the query (is ollama + "%s" running?)' "$model"; return 1; }
    _rag_search "$db" "$qvec" "$k"
}

# chat — one user turn via /api/chat (stream off); returns the assistant text.
tool_ollama_chat() {
    command -v curl &>/dev/null || { _ollama_missing curl "brew install curl"; return 1; }
    local model="$1"; [[ -n "$model" ]] || { printf 'model name required'; return 1; }
    local msg; msg=$(tool_arg content "$(tool_arg prompt '')")
    [[ -n "$msg" ]] || { printf 'message required (.content)'; return 1; }
    local extra; extra=$(_ollama_gen_extra)
    local body; body=$(jq -cn --arg m "$model" --arg c "$msg" --argjson x "$extra" \
        '{model:$m,stream:false,messages:[{role:"user",content:$c}]} + $x')
    local resp; resp=$(curl -sS --max-time "${YCA_LLM_TIMEOUT:-120}" "$(_ollama_host)/api/chat" \
        -d "$body" 2>&1) \
        || { printf 'request failed: %s' "$resp"; return 1; }
    local e; e=$(_ollama_api_err "$resp"); [[ -n "$e" ]] && { printf 'ollama error: %s' "$e"; return 1; }
    # Prefer the answer; if a thinking model returned only reasoning (empty
    # content, e.g. num_predict too small), surface that with a hint.
    local out; out=$(printf '%s' "$resp" | jq -r '
        if (.message.content // "") != "" then .message.content
        elif (.message.thinking // "") != "" then "[reasoning only — raise num_predict for an answer]\n" + .message.thinking
        else . end' 2>/dev/null) || out="$resp"
    printf '%s' "$out"
}

# api_generate — raw /api/generate completion (stream off).
tool_ollama_api_generate() {
    command -v curl &>/dev/null || { _ollama_missing curl "brew install curl"; return 1; }
    local model="$1"; [[ -n "$model" ]] || { printf 'model name required'; return 1; }
    local prompt; prompt=$(tool_arg content "$(tool_arg prompt '')")
    [[ -n "$prompt" ]] || { printf 'prompt required (.content)'; return 1; }
    local extra; extra=$(_ollama_gen_extra)
    local body; body=$(jq -cn --arg m "$model" --arg p "$prompt" --argjson x "$extra" \
        '{model:$m,prompt:$p,stream:false} + $x')
    local resp; resp=$(curl -sS --max-time "${YCA_LLM_TIMEOUT:-120}" "$(_ollama_host)/api/generate" \
        -d "$body" 2>&1) \
        || { printf 'request failed: %s' "$resp"; return 1; }
    local e; e=$(_ollama_api_err "$resp"); [[ -n "$e" ]] && { printf 'ollama error: %s' "$e"; return 1; }
    local out; out=$(printf '%s' "$resp" | jq -r '
        if (.response // "") != "" then .response
        elif (.thinking // "") != "" then "[reasoning only — raise num_predict for an answer]\n" + .thinking
        else . end' 2>/dev/null) || out="$resp"
    printf '%s' "$out"
}

# serve_status — is the ollama daemon reachable?
tool_ollama_serve_status() {
    command -v curl &>/dev/null || { _ollama_missing curl "brew install curl"; return 1; }
    local host; host=$(_ollama_host)
    local v; v=$(curl -sS --max-time 5 "$host/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
    if [[ -n "$v" ]]; then printf 'ollama daemon: UP at %s (version %s)' "$host" "$v"
    else printf 'ollama daemon: DOWN or unreachable at %s\n(start it with: ollama serve)' "$host"; return 1; fi
}

# version — client + daemon version.
tool_ollama_version() {
    local out=""
    if command -v ollama &>/dev/null; then out+="client: $(ollama --version 2>&1 | head -1)\n"; else out+="client: (ollama not installed)\n"; fi
    if command -v curl &>/dev/null; then
        local v; v=$(curl -sS --max-time 5 "$(_ollama_host)/api/version" 2>/dev/null | jq -r '.version // empty' 2>/dev/null)
        out+="daemon: ${v:-unreachable}\n"
    fi
    printf '%b' "$out"
}

# disk — per-model sizes + total models-dir footprint.
tool_ollama_disk_usage() {
    command -v ollama &>/dev/null || { _ollama_missing ollama "brew install ollama"; return 1; }
    printf 'Models (name  size):\n'
    ollama list 2>/dev/null | awk 'NR>1{printf "  %-40s %s %s\n",$1,$3,$4}'
    local dir="${OLLAMA_MODELS:-$HOME/.ollama/models}"
    if [[ -d "$dir" ]]; then
        printf '\nModels dir: %s\n' "$dir"
        du -sh "$dir" 2>/dev/null | awk '{printf "  total on disk: %s\n",$1}'
    fi
}

# logs — tail the ollama server log (best-effort; location varies by OS).
tool_ollama_logs() {
    local n; n=$(tool_arg lines 40); [[ "$n" =~ ^[0-9]+$ ]] || n=40
    local f
    for f in "$HOME/.ollama/logs/server.log" "$HOME/.ollama/logs/serve-headless.log" "$HOME/Library/Logs/Ollama/server.log" "/var/log/ollama.log"; do
        [[ -f "$f" ]] && { printf 'log: %s\n' "$f"; tail -n "$n" "$f" 2>/dev/null; return 0; }
    done
    printf 'no ollama log file found (checked ~/.ollama/logs, ~/Library/Logs/Ollama, /var/log).\nIf started via `ollama serve`, logs print to that terminal.'
}

# ── Register (category: ollama) ──────────────────────────────────────────────
# Pure `ollama <verb>` passthroughs (models/ps/stop/show/pull/cp/rm/push/create)
# were removed — the always-on `bash` tool runs them directly, and the ones with
# consequences stay gated there. What remains encodes real work: model-file
# header parsing, notebook conversion, the HTTP API with option merging, RAG, and
# the endpoint/serve/disk/logs aggregates.
tool_register "ollama_run"              tool_ollama_run              '{"type":"object","properties":{"target":{"type":"string","description":"model name"},"content":{"type":"string","description":"prompt"}},"required":["target","content"]}' safe all ollama
tool_register "ollama_model_info"       tool_ollama_model_info       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all ollama
tool_register "ollama_notebook"         tool_ollama_notebook         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all ollama
tool_register "ollama_endpoint_test"    tool_ollama_endpoint_test    '{"type":"object","properties":{}}' safe all ollama
tool_register "ollama_llm_prompt_review" tool_ollama_llm_prompt_review '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"content":{"type":"string","description":"the file content to write"}}}' safe all ollama mid
tool_register "ollama_doctor"           tool_ollama_doctor           '{"type":"object","properties":{}}' safe all ollama
tool_register "ollama_embed"         tool_ollama_embed         '{"type":"object","properties":{"target":{"type":"string","description":"embedding model"},"content":{"type":"string","description":"the file content to write"}},"required":["target","content"]}' safe all ollama
tool_register "ollama_extract"           tool_ollama_extract           '{"description":"Extract schema-constrained JSON from text (structured output via response_format)","type":"object","properties":{"content":{"type":"string","description":"the file content to write"},"schema":{"type":"string","description":"optional JSON schema string"},"instruction":{"type":"string","description":"the instruction"}},"required":["content"]}' safe all ollama mid
tool_register "ollama_rag_index"         tool_ollama_rag_index         '{"description":"Chunk + embed a file into a DuckDB vector store","type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"model":{"type":"string","description":"the model name"}},"required":["file"]}' writes all ollama
tool_register "ollama_rag_query"         tool_ollama_rag_query         '{"description":"Semantic (top-k) search over the RAG index","type":"object","properties":{"query":{"type":"string","description":"the search or lookup query"},"model":{"type":"string","description":"the model name"},"k":{"type":"integer","description":"number of nearest results to return"}},"required":["query"]}' safe all ollama
tool_register "ollama_chat"          tool_ollama_chat          '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"content":{"type":"string","description":"the file content to write"},"temperature":{"type":"number","description":"sampling temperature (0-2)"},"top_k":{"type":"integer","description":"top-k sampling cutoff"},"top_p":{"type":"number","description":"nucleus sampling probability (0-1)"},"min_p":{"type":"number","description":"minimum probability cutoff"},"repeat_penalty":{"type":"number","description":"penalty applied to repeated tokens"},"num_ctx":{"type":"integer","description":"context window size in tokens"},"num_predict":{"type":"integer","description":"maximum number of tokens to generate"},"seed":{"type":"integer","description":"random seed for reproducible output"},"stop":{"type":"array","items":{"type":"string"},"description":"stop sequences that end generation"},"format":{"description":"\"json\" or a JSON schema object for constrained output"},"options":{"type":"object","description":"any Ollama options, merged over the shortcuts above"}},"required":["target","content"]}' safe all ollama
tool_register "ollama_api_generate"  tool_ollama_api_generate  '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"},"content":{"type":"string","description":"the file content to write"},"temperature":{"type":"number","description":"sampling temperature (0-2)"},"top_k":{"type":"integer","description":"top-k sampling cutoff"},"top_p":{"type":"number","description":"nucleus sampling probability (0-1)"},"min_p":{"type":"number","description":"minimum probability cutoff"},"repeat_penalty":{"type":"number","description":"penalty applied to repeated tokens"},"num_ctx":{"type":"integer","description":"context window size in tokens"},"num_predict":{"type":"integer","description":"maximum number of tokens to generate"},"seed":{"type":"integer","description":"random seed for reproducible output"},"stop":{"type":"array","items":{"type":"string"},"description":"stop sequences that end generation"},"format":{"description":"\"json\" or a JSON schema object for constrained output"},"options":{"type":"object","description":"any Ollama options, merged over the shortcuts above"}},"required":["target","content"]}' safe all ollama
# Maintenance.
tool_register "ollama_serve_status"  tool_ollama_serve_status  '{"type":"object","properties":{}}' safe all ollama
tool_register "ollama_version"       tool_ollama_version       '{"type":"object","properties":{}}' safe all ollama
tool_register "ollama_disk_usage"          tool_ollama_disk_usage          '{"type":"object","properties":{}}' safe all ollama
tool_register "ollama_logs"          tool_ollama_logs          '{"type":"object","properties":{"lines":{"type":"integer","description":"number of lines to return"}}}' safe all ollama
