#!/usr/bin/env bash
# core/budget.sh — T10 tool-result budgets + spill-to-file, and the silent-
# truncation detector for Yantra's own llm_analyze calls.
#
# The server cannot know the host model's context window, so an oversized tool
# result is written to a per-session spill file and the model is handed a short
# inline preview plus a pointer (an MCP resource link over MCP; a path notice on
# CLI/NDJSON). The host fetches the bulk only if it needs it — the biggest
# untapped token saver. Fixes defect j: the 1 MiB / 4 MiB frontier-sized caps
# are gone; the default result cap is sized for an 8-32K local context.

: "${YCA_RESULT_CAP:=8192}"          # bytes; results over this spill to a file
: "${YCA_RESULT_PREVIEW:=600}"       # chars of inline preview kept with a spill
: "${YCA_SPILL_RETENTION_DAYS:=7}"   # GC spilled files older than this at boot

# _spill_dir -> the per-session spill directory (created on demand). Lives under
# the project so it shares the project's lifecycle; files OUTLIVE the call (the
# host may fetch the link later) but are GC'd by age at boot.
_spill_dir() {
    local base="${YCA_PROJECT_DIR:-$PWD}/.harness_results"
    local sess="${YCA_SESSION_ID:-$$}"
    local d="$base/$sess"
    [[ -d "$d" ]] || mkdir -p "$d" 2>/dev/null
    printf '%s' "$d"
}

# _utf8_trim TEXT NCHARS -> the first NCHARS characters, never cutting a UTF-8
# codepoint. Bash slices by character in a UTF-8 locale; the iconv pass drops any
# trailing partial sequence so the result is always valid UTF-8 even under LANG=C.
_utf8_trim() {
    local text="$1" n="$2" cut
    cut="${text:0:$n}"
    if command -v iconv >/dev/null 2>&1; then
        cut=$(printf '%s' "$cut" | iconv -f UTF-8 -t UTF-8 -c 2>/dev/null) || cut="${text:0:$n}"
    fi
    printf '%s' "$cut"
}

# spill_write TEXT -> writes TEXT to a fresh spill file; prints its id (basename).
# On write failure (disk full, read-only) prints nothing and returns 1 — the
# caller must surface a named error, never a dangling link.
spill_write() {
    local text="$1" dir id path
    dir=$(_spill_dir)
    [[ -d "$dir" ]] || return 1
    id="r${EPOCHSECONDS}_$$_${RANDOM}.txt"
    path="$dir/$id"
    printf '%s' "$text" > "$path" 2>/dev/null || { rm -f "$path" 2>/dev/null; return 1; }
    printf '%s' "$id"
}

# spill_path ID -> absolute path for a spill id (no existence guarantee).
spill_path() { printf '%s/%s' "$(_spill_dir)" "$1"; }

# spill_read ID -> the spilled bytes, or rc 1 (clean not-found) if GC'd/absent.
# Searches ALL session dirs, so a link still resolves after the host reconnects
# (a new process) — until the file ages out. The id is validated against a strict
# pattern first so a crafted "id" can never traverse out of the results tree.
spill_read() {
    local id="$1" base="${YCA_PROJECT_DIR:-$PWD}/.harness_results" p
    [[ "$id" =~ ^r[0-9]+_[0-9]+_[0-9]+\.txt$ ]] || return 1
    [[ -d "$base" ]] || return 1
    p=$(find "$base" -type f -name "$id" 2>/dev/null | head -1)
    [[ -n "$p" && -f "$p" ]] || return 1
    cat "$p" 2>/dev/null
}

# spill_gc -> remove spill files older than the retention window. Called at boot.
spill_gc() {
    local base="${YCA_PROJECT_DIR:-$PWD}/.harness_results"
    [[ -d "$base" ]] || return 0
    find "$base" -type f -mtime "+${YCA_SPILL_RETENTION_DAYS}" -delete 2>/dev/null || true
    # prune now-empty session dirs
    find "$base" -type d -empty -delete 2>/dev/null || true
}

# result_over_cap TEXT -> 0 if TEXT exceeds the result cap (byte length).
result_over_cap() { [[ "${#1}" -gt "$YCA_RESULT_CAP" ]]; }

# result_budget TEXT -> for the CLI/NDJSON surfaces: pass small results through
# unchanged; spill a large one and return a preview + a path notice. On the MCP
# surface this is a no-op (mcp_tools_call builds a resource link from the raw
# result instead). A spill that fails to write degrades to an in-band notice
# with the byte count — never a broken link.
result_budget() {
    local text="$1"
    [[ "$YCA_UI_MODE" == "mcp" ]] && { printf '%s' "$text"; return 0; }
    result_over_cap "$text" || { printf '%s' "$text"; return 0; }
    local id preview bytes="${#text}"
    preview=$(_utf8_trim "$text" "$YCA_RESULT_PREVIEW")
    if id=$(spill_write "$text"); then
        printf '%s\n… [truncated: full %s-byte result saved to %s]' \
            "$preview" "$bytes" "$(spill_path "$id")"
    else
        printf '%s\n… [truncated: %s-byte result; could not spill to disk]' "$preview" "$bytes"
    fi
}

# ── Silent-truncation detector (F1) ─────────────────────────────────────────
# llm_check_truncation SENT_CHARS RESP — warn (once, loudly) when the provider's
# reported prompt token count is far below what we sent, which means the engine
# silently cut the prompt from the FRONT (dropping the system prompt / tool
# defs). The classic Ollama /v1 num_ctx=4096 default. Tolerance guards against a
# false alarm from the crude chars/4 estimate.
: "${YCA_TRUNC_TOLERANCE:=60}"   # warn only if reported < this % of estimate
llm_check_truncation() {
    local sent_chars="$1" resp="$2"
    local reported est
    reported=$(printf '%s' "$resp" | jq -r '.usage.prompt_tokens // .prompt_eval_count // 0' 2>/dev/null)
    [[ "$reported" =~ ^[0-9]+$ ]] || return 0
    (( reported > 0 )) || return 0           # no usage reported → can't tell
    est=$(( sent_chars / 4 ))
    (( est > 500 )) || return 0              # tiny prompts can't be meaningfully truncated
    if (( reported * 100 < est * YCA_TRUNC_TOLERANCE )); then
        log_warn "silent context truncation likely: sent ~${est} tokens but the model reports only ${reported} prompt tokens. The engine cut the prompt from the front (system prompt + tool defs lost). Fix: raise the model context window — Ollama: set num_ctx (e.g. \"options\":{\"num_ctx\":8192}) or a larger model; the /v1 endpoint IGNORES per-request num_ctx."
        return 1
    fi
    return 0
}
