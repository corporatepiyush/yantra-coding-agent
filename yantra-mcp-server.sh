#!/usr/bin/env bash
#      __   __     _    _   _ _____ ____      _
#      \ \ / /    / \  | \ | |_   _|  _ \    / \      YANTRA CODING AGENT
#       \ V /    / _ \ |  \| | | | | |_) |  / _ \     deterministic-first
#        | |    / ___ \| |\  | | | |  _ <  / ___ \    11 languages · dual-mode
#        |_|   /_/   \_\_| \_| |_| |_| \_\/_/   \_\
#
#  MCP tool server for multi-language orgs managing many projects.
#  Single entry point; modular under harness/. Config: yantra.config.json.
#
#  Yantra is a pure MCP server (JSON-RPC 2.0 over stdio). Point an MCP host
#  (Claude Desktop, an Ollama-driving CLI host) at this script; the host owns
#  the conversation and the reasoning loop, Yantra owns the tools, workflows
#  (as tools named wf__<id>), consent gating, discovery, plans, and budgets.
#
#  Usage:
#    bash yantra-mcp-server.sh              # MCP server on stdio (default)
#    bash yantra-mcp-server.sh -y           # …with writes pre-consented
#    bash yantra-mcp-server.sh --help       # options + removed-surface map
#
set -Euo pipefail
shopt -s extglob nullglob globstar 2>/dev/null || true

# ─── Bash 5.3+ hard requirement (must be first) ────────────────────────────
# This check runs BEFORE sourcing harness/, and is written to parse under an
# OLD shell (macOS ships Bash 3.2 at /bin/bash). Several harness modules use
# Bash 5.3-only syntax — e.g. the `${| ...; }` no-fork command substitution in
# harness/lib/bash53.sh — which older shells cannot even *parse*. That parse
# failure would pre-empt the friendly check in _yca_require_bash and dump a
# cryptic error instead. So we gate here, using only Bash 3.2-safe constructs.
_yca_major="${BASH_VERSINFO[0]:-0}"
_yca_minor="${BASH_VERSINFO[1]:-0}"
if [ "$_yca_major" -lt 5 ] || { [ "$_yca_major" -eq 5 ] && [ "$_yca_minor" -lt 3 ]; }; then
    printf 'ERROR: Yantra Coding Agent requires Bash 5.3+ (running under %s.%s).\n' "$_yca_major" "$_yca_minor" >&2
    printf '  macOS: brew install bash    (then invoke with %s)\n' "$(command -v bash 2>/dev/null || printf '/opt/homebrew/bin/bash')" >&2
    printf '  Linux: install or build Bash >= 5.3.\n' >&2
    exit 3
fi
unset _yca_major _yca_minor

# Determine script directory (works with symlinks)
YCA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export YCA_DIR

# Source the main orchestrator (which sources everything else)
source "$YCA_DIR/harness/main.sh"

# Run
main "$@"
