# main.sh — Main orchestrator (sources everything, dispatches)

# ─── Source lib/ (foundational utilities, no deps) ───
# constants.sh must load first (defines globals used by others)
source "$YCA_DIR/harness/lib/constants.sh"
for _f in "$YCA_DIR/harness/lib/"*.sh; do
    [[ "$_f" == */constants.sh ]] && continue
    [[ -f "$_f" ]] && source "$_f"
done

# ─── Detect Bash version (after lib is sourced) ───
_yca_bash_init
_yca_require_bash

# ─── Source core/ (infrastructure) ───
# Load in order: validate first (used by tools), then tools/workflows
for _f in "$YCA_DIR/harness/core/validate.sh"; do
    [[ -f "$_f" ]] && source "$_f"
done
for _f in "$YCA_DIR/harness/core/"*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done

# ─── Source commands/ ───
for _f in "$YCA_DIR/harness/commands/"*.sh; do
    [[ -f "$_f" ]] && source "$_f"
done

# ─── Register tools + workflows (sources tools/, langs/, workflows/) ───
source "$YCA_DIR/harness/register.sh"

# ─── Register cleanup trap ───
cleanup_register_trap

# ─── Main entry ───
# Yantra is a pure MCP server (owner amendment, 2026-07-13).
# The CLI subcommand surface, interactive REPL, NDJSON stdio surface, roles,
# and the agent loop were removed. Removed flags fail loudly with their MCP
# replacement (playbook M4) — never a silent no-op.

_mcp_only_usage() {
    cat <<'EOF'
yantra-coding-agent — MCP tool server (stdio)

Usage: yantra-mcp-server.sh [options]
  (no arguments)        run the MCP server on stdio — point an MCP host here
  --ui mcp              same (kept for existing host configs)
  --project DIR         serve this project directory (default: cwd)
  -y, --yes             pre-consent writes-class tools for this session
                        (otherwise consent = MCP elicitation, deny fallback)
  --enable CAT          enable a tool category at boot (also: enable_category)
  --disable CAT         disable a tool category at boot
  --version             print version
  -h, --help            this text

Removed surfaces → replacements:
  yantra <category> <call>   → tools/call over MCP
  --ui json (NDJSON)         → MCP JSON-RPC over stdio
  interactive REPL           → any MCP host
  --role / --workflow / the agent loop → the MCP host owns the loop;
                               workflows are tools named wf__<id>
EOF
}

main() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ui)
                if [[ "${2:-}" != "mcp" ]]; then
                    logmsg "removed: '--ui ${2:-}'. Yantra is MCP-only — the NDJSON and human surfaces are gone; connect an MCP host over stdio (docs/AGENT_GUIDE.md)."
                    exit 64
                fi
                shift 2 ;;
            -y|--yes|--auto-confirm) YCA_AUTO_CONFIRM=true; shift ;;
            --project) YCA_PROJECT_DIR="${2:-}"; shift 2 ;;
            --enable)  YCA_ENABLE_CAT="${2:-}"; shift 2 ;;
            --disable) YCA_DISABLE_CAT="${2:-}"; shift 2 ;;
            --version) printf '%s\n' "$YCA_VERSION"; exit 0 ;;
            -h|--help) _mcp_only_usage; exit 0 ;;
            --role|--role=*|--workflow|--workflow=*)
                logmsg "removed: '$1'. The reasoning loop belongs to the MCP host; workflows are MCP tools named wf__<id>."
                exit 64 ;;
            *)
                logmsg "removed: '$1'. The CLI subcommand surface is gone — Yantra is a pure MCP server; use tools/call over MCP (docs/AGENT_GUIDE.md)."
                exit 64 ;;
        esac
    done

    # Removed config keys warn once, never silently no-op (M4).
    [[ -n "${HARNESS_TURN_REMINDER:-}" ]] && \
        logmsg "deprecated: HARNESS_TURN_REMINDER has no effect — the loop moved to the MCP host; the grounding rules are the MCP prompt 'grounding'."

    # Set project dir
    YCA_PROJECT_DIR="${YCA_PROJECT_DIR:-$(pwd)}"
    YCA_PROJECT_DIR=$(path_resolve "$YCA_PROJECT_DIR")
    export YCA_PROJECT_DIR
    YCA_SAFETY_PATHS="$YCA_PROJECT_DIR"

    # Run WITH the project as the working directory. A host launches us with
    # --project <repo>, and a model working "inside" that repo naturally uses
    # project-relative paths — `read {"path":"Cargo.toml"}`, `bash {"command":"ls"}`.
    # Without this cd, $PWD stayed wherever the process was spawned (outside the
    # fence), so bash returned "cwd not allowed" and every relative path resolved
    # against the wrong directory — an agent driving a real project was dead on
    # arrival (observed: a local model burned 6 turns before finding a tool that
    # cd's internally). Every harness-internal path uses $YCA_DIR / $YCA_PROJECT_DIR
    # (both absolute), so this only affects tool-facing relative paths — the point.
    cd "$YCA_PROJECT_DIR" 2>/dev/null || true

    YCA_UI_MODE="mcp"

    # Preserve the real stdout on fd 9 and route protocol frames there. The
    # MCP wf__ bridge (_mcp_run_workflow) still retargets this fd to capture a
    # workflow's emit() frames while quarantining its stray stdout to stderr.
    exec 9>&1
    YCA_OUT_FD=9

    db_init                       # seeds in-memory category gates (cat_init_defaults)
    spill_gc 2>/dev/null || true  # T10: GC spilled result files older than retention

    # yantra.config.json is the single source of truth. Load global+project files
    # (creating a default project file if absent) and apply them to runtime.
    projectconfig_load
    local _cat
    for _cat in $(projectconfig_enabled_categories); do
        _cat=$(str_lower "$_cat")
        [[ -n "${YCA_CAT_DEFAULT[$_cat]:-}" ]] && YCA_CAT_ENABLED[$_cat]=1
    done

    tools_autodetect_enable        # runtime-enable detected-language tool categories
    config_resolve

    # Normalize LLM providers (applies HARNESS_LLM_URL env override) and decide
    # whether any LLM tier is configured — the *_llm_* tools still call out.
    providers_load
    providers_detect

    doctor_init_manifest

    # Apply --enable/--disable from the launch flags. Passing the flag IS the
    # operator's consent, and boot happens before the JSON-RPC stream starts —
    # route the workflow's frames to stderr so stdout stays protocol-pure.
    if [[ -n "${YCA_ENABLE_CAT:-}" || -n "${YCA_DISABLE_CAT:-}" ]]; then
        local _saved_auto="$YCA_AUTO_CONFIRM" _saved_fd="$YCA_OUT_FD"
        YCA_AUTO_CONFIRM=true YCA_OUT_FD=2
        [[ -n "${YCA_ENABLE_CAT:-}" ]] && { wf_tools_enable "$YCA_ENABLE_CAT" || true; }
        [[ -n "${YCA_DISABLE_CAT:-}" ]] && { wf_tools_disable "$YCA_DISABLE_CAT" || true; }
        YCA_AUTO_CONFIRM="$_saved_auto" YCA_OUT_FD="$_saved_fd"
    fi

    # Probe dependencies SILENTLY (populates status; full list via wf__doctor).
    doctor_probe_all || true
    scan_project "$YCA_PROJECT_DIR"

    # Background update check
    if [[ "$YCA_UPDATE_ENABLED" == "true" ]]; then
        update_check &
        YCA_UPDATE_PID=$!
    fi

    # mcp.sh is sourced at startup (defines functions only); the loop runs here.
    mcp_loop
}
