# lib/constants.sh — Global constants and defaults
# Loaded first. No dependencies on other harness files.

readonly YCA_VERSION="1.0.0"
readonly YCA_SPEC_VERSION="2.0"
readonly YCA_MIN_BASH="5.3"
readonly YCA_CONFIG_VERSION="1"

# Globals (mutable at runtime)
YCA_DIR="${YCA_DIR:-}"
YCA_PID="$$"
YCA_SEQ=0
YCA_CLEANUP_CALLED=0
YCA_AUTO_CONFIRM=false

# ─── Complexity → LLM tier ──────────────────────────────────────────────────
# Every tool and workflow carries a complexity. It decides which LLM provider
# tier (if any) a call routes to:
#   high → think  (largest model; open-ended reasoning, the agent loop)
#   mid  → build  (medium model; dynamic/LLM-backed tools & workflows)
#   low  → tool   (static tool/workflow; no LLM needed)
# low never touches an LLM, so a low call works with zero providers configured.
readonly YCA_COMPLEXITY_DEFAULT="low"
readonly YCA_TIER_THINK="think"
readonly YCA_TIER_BUILD="build"
readonly YCA_TIER_TOOL="tool"
# Tier fall-down order when the preferred tier has no reachable provider.
readonly YCA_TIER_ORDER="think build tool"

# ─── Config (yantra.config.json is the single source of truth) ──────────────
# Built-in defaults are the base. A global file and a project file layer on top
# (project wins). env/CLI are session-only overrides that are NEVER written back.
YCA_CONFIG_JSON="{}"          # merged effective config (defaults ← global ← project)
YCA_PROVIDERS_JSON='{}'       # {think:[...],build:[...],tool:[...]} provider lists
YCA_CONFIG_GLOBAL_PATH=""     # resolved global config path (may not exist)
YCA_CONFIG_PROJECT_PATH=""    # resolved project config path (may not exist)

# ─── LLM knobs (per-provider model overrides these fallbacks) ───────────────
YCA_LLM_MODEL="${HARNESS_LLM_MODEL:-llama3.1}"     # fallback model if a provider omits one
YCA_LLM_TIMEOUT="${HARNESS_LLM_TIMEOUT:-120}"
YCA_LLM_MAX_RETRIES="${HARNESS_LLM_RETRIES:-3}"
YCA_LLM_MAX_ITERS="${HARNESS_LLM_MAX_ITERS:-20}"
# Sampling temperature for the agent loop. Empty = omit the field (endpoint/model
# default applies). Local models often default high (gemma4 ships temperature 1),
# which makes tool-calling flaky — set 0.2–0.3 for agent work on local models.
YCA_LLM_TEMPERATURE="${HARNESS_LLM_TEMPERATURE:-}"
# Cap on the agent-loop conversation size (bytes of messages JSON). Older tool
# outputs are elided (not dropped) past this, so a long run can't grow the
# in-process history without bound. Sized for the 8-32K windows of the small
# local models this project prioritizes (~256 KiB ≈ 64K tokens), NOT the frontier
# 4 MiB that defect j flagged; override up for large-context hosts.
YCA_LLM_MAX_CONTEXT_BYTES="${HARNESS_LLM_MAX_CONTEXT_BYTES:-262144}"
YCA_API_TOKEN="${HARNESS_API_TOKEN:-}"             # fallback token if a provider omits one
# The per-turn reminder died with the agent loop (MCP-only amendment). Its
# grounding rules survive as the MCP prompt "grounding" (agent_turn_reminder in
# core/llm.sh, served by prompts/get). HARNESS_TURN_REMINDER now only triggers
# a deprecation notice at boot (playbook M4).

# ─── Provider runtime state (populated by core/providers.sh) ────────────────
declare -A YCA_TIER_ACTIVE_URL=()   # tier → currently selected (sticky) provider URL
declare -A YCA_URL_DEAD=()          # URL → 1 once found network-unreachable this session
# Complexity of the call currently being dispatched. Set by tool_dispatch /
# run_workflow / the agent loop; read by llm_call/llm_analyze to pick a tier.
YCA_CALL_COMPLEXITY="$YCA_COMPLEXITY_DEFAULT"

# ─── Misc runtime knobs ─────────────────────────────────────────────────────
YCA_UI_MODE="auto"
YCA_ROLE=""
YCA_PROJECT_DIR=""
YCA_UPDATE_ENABLED="${HARNESS_UPDATE_ENABLED:-true}"
YCA_UPDATE_GIT_URL="${HARNESS_UPDATE_GIT_URL:-https://github.com/corporatepiyush/yantra-coding-agent.git}"
YCA_UPDATE_BRANCH="${HARNESS_BRANCH:-main}"
YCA_SAFETY_CONFIRM="${HARNESS_SAFETY_CONFIRM:-true}"
YCA_SAFETY_PATHS=""
YCA_LOG_LEVEL="${HARNESS_LOG_LEVEL:-info}"
YCA_HEARTBEAT_INTERVAL="${HARNESS_HEARTBEAT_INTERVAL:-5}"
YCA_HEARTBEAT_TIMEOUT="${HARNESS_HEARTBEAT_TIMEOUT:-10}"

# Tool category gates: 1=on, 0=off. Core (5 tools) always on.
declare -A YCA_CAT_DEFAULT=(
    [core]=1     # read, write, edit, bash, browse, batch
    [ssh]=0      [docker]=0 [kubernetes]=0 [helm]=0
    [pg]=0       [mysql]=0  [redis]=0
    [fs]=0       [perf]=0   [net]=0        [sec]=0
    [quality]=0  [ci]=0     [fw]=0        [doc]=0   [data]=0
    [media]=0    [ollama]=0 [monitor]=0   [s3]=0    [adk]=0   [brew]=0   [kg]=0   [localdb]=0
    [git]=0      [opencv]=0    [cua]=0   [ytdl]=0
    # Language categories
    [nodejs]=0   [python]=0 [rust]=0      [golang]=0 [ccpp]=0
    [java]=0     [kotlin]=0 [scala]=0     [ruby]=0   [php]=0
)
declare -A YCA_CAT_ENABLED
declare -A YCA_CAT_LABEL=(
    [core]="Core (read/write/edit/bash/browse/batch)"
    [ssh]="SSH/Remote"           [docker]="Docker"
    [kubernetes]="Kubernetes"    [helm]="Helm"
    [pg]="PostgreSQL"            [mysql]="MySQL/MariaDB"  [redis]="Redis"
    [fs]="Filesystem & Search"   [perf]="Performance"    [net]="Network"
    [sec]="Security"             [quality]="Code Quality" [ci]="CI/CD"
    [fw]="Firewall"              [doc]="Documents"       [data]="Data (duckdb)"
    [media]="Media"            [ollama]="Ollama / Local LLM"
    [monitor]="Agent Monitor"  [s3]="S3 Storage"       [adk]="ADK Features"
    [brew]="Homebrew (macOS/Linux)"  [kg]="Code Knowledge Graph"
    [localdb]="Local SQLite scratch DB"
    [git]="Git (read-only introspection)"
    [opencv]="Computer Vision (OpenCV 4.13)"
    [cua]="Computer Use (screen/mouse/keyboard driver)"
    [ytdl]="YouTube & media downloader (yt-dlp)"
    [nodejs]="Node.js/TypeScript" [python]="Python"      [rust]="Rust"
    [golang]="Go"                [ccpp]="C/C++"          [java]="Java"
    [kotlin]="Kotlin"            [scala]="Scala"         [ruby]="Ruby"
    [php]="PHP"
)

# State
# Protocol output fd. emit() writes frames here. main() dups the real stdout to
# fd 9 and points this at it, so run_workflow can safely redirect a workflow's
# own stray stdout to stderr without clobbering the protocol stream. Defaults to
# 1 so emit still works if the process didn't go through main() (e.g. a unit
# test sourcing the harness).
YCA_OUT_FD=1
# Whether at least one LLM provider URL is configured. Computed at startup by
# providers_detect(); gates the friendly "AI is on/off" notice and the ready frame.
YCA_HAVE_LLM=0
YCA_CURRENT_WORKFLOW=""
YCA_EXEC_MODE=false
# `yantra <category> <call> …` CLI mode (set in main() when argv[0] is not a flag).
YCA_SUBCOMMAND=false
declare -a YCA_SUBCOMMAND_ARGS=()
YCA_INPUT_JSON=""
YCA_UPDATE_PID=""
YCA_HEARTBEAT_PID=""
declare -A YCA_CACHED_TOOLS_JSON_BY_AGENT=()  # per-agent tools JSON cache (set -u safe)
# Empty-object default for `${var:-$YCA_EMPTY_JSON}`. A literal `${var:-{}}`
# MISPARSES: bash ends the `:-` word at the first `}`, so the default becomes `{`
# and the trailing `}` is appended to the value — corrupting a non-empty JSON arg
# into `…}}`. Using a brace-free variable as the default avoids the misparse.
YCA_EMPTY_JSON='{}'
YCA_DB_PATH=""
# SQLite busy_timeout (ms) applied to EVERY connection via lib/sql.sh `_sqlite`.
# busy_timeout is a PER-CONNECTION setting (unlike journal_mode=WAL, which is
# persisted in the db file), so without this each ad-hoc sqlite3 call defaults to
# a 0ms timeout and fails instantly under contention from parallel sub-agents
# sharing the same db. With it, a concurrent writer waits for the lock instead.
YCA_SQLITE_BUSY_TIMEOUT="${HARNESS_SQLITE_BUSY_TIMEOUT:-10000}"
