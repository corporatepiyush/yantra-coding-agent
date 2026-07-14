# tools/brew.sh — Homebrew tools (macOS + Linux unified package manager)
# Homebrew is auto-installed on first use via os_brew_ensure().
#
# Read-only passthroughs (list/search/info/outdated/deps/uses/services list…)
# were removed: they were 1:1 aliases of a `brew <verb>` the always-on `bash`
# tool runs directly. What stays earns its place — the install/uninstall/upgrade/
# cleanup verbs carry consent gates and previews, `ensure` bootstraps Homebrew
# itself, and `status` aggregates several brew queries into one health summary.

# ── Helpers ──────────────────────────────────────────────────────────────────
_brew_missing() { printf 'Homebrew not installed.\nCall brew_ensure to install it, or run:\n  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'; }

# ── Tools ────────────────────────────────────────────────────────────────────

# brew_ensure — install Homebrew if missing (macOS + Linux). Idempotent.
tool_brew_ensure() {
    os_brew_ensure
}

# brew_install — install one or more formulae/casks. arg1=name (formula or space-separated list).
tool_brew_install() {
    local formula="$1"
    [[ -n "$formula" ]] || { printf 'formula name required (use .name)'; return 1; }
    os_brew_ensure || return 1
    confirm_action "brew install $formula" "installs: $formula" || { confirm_denied_msg; return 1; }
    HOMEBREW_NO_AUTO_UPDATE=1 brew install $formula 2>&1
}

# brew_uninstall — remove a formula/cask. arg1=name.
tool_brew_uninstall() {
    local formula="$1"
    [[ -n "$formula" ]] || { printf 'formula name required'; return 1; }
    command -v brew &>/dev/null || { _brew_missing; return 1; }
    confirm_action "brew uninstall $formula" "removes: $formula" || { confirm_denied_msg; return 1; }
    brew uninstall "$formula" 2>&1
}

# brew_upgrade — upgrade a formula (or --all for everything). arg1=name (optional).
tool_brew_upgrade() {
    command -v brew &>/dev/null || { _brew_missing; return 1; }
    local formula="${1:-}"
    if [[ -z "$formula" || "$formula" == "--all" ]]; then
        confirm_action "brew upgrade (ALL formulae)" "upgrades everything" || { confirm_denied_msg; return 1; }
        brew upgrade 2>&1
    else
        confirm_action "brew upgrade $formula" "upgrades: $formula" || { confirm_denied_msg; return 1; }
        brew upgrade "$formula" 2>&1
    fi
}

# brew_cleanup — remove old versions + cache (frees disk). arg1=target (optional: --prune=N days).
tool_brew_cleanup() {
    command -v brew &>/dev/null || { _brew_missing; return 1; }
    confirm_action "brew cleanup" "removes old versions + stale cache" || { confirm_denied_msg; return 1; }
    local target="${1:-}"
    brew cleanup $target 2>&1
}

# brew_status — harness doctor: brew version, prefix, tap list, last update, status.
tool_brew_status() {
    command -v brew &>/dev/null || { printf 'Homebrew: NOT INSTALLED\nrun: brew_ensure'; return 0; }
    local out=""
    out+="Homebrew: $(brew --version 2>&1 | head -1)\n"
    out+="Prefix: $(brew --prefix 2>&1)\n"
    out+="Cellar: $(brew --cellar 2>&1)\n"
    out+="Taps: $(brew tap 2>&1 | wc -l | tr -d ' ') taps\n"
    out+="Installed: $(brew list --formula 2>/dev/null | wc -l | tr -d ' ') formulae, $(brew list --cask 2>/dev/null | wc -l | tr -d ' ') casks\n"
    out+="Outdated: $(HOMEBREW_NO_AUTO_UPDATE=1 brew outdated 2>/dev/null | wc -l | tr -d ' ')\n"
    printf '%b' "$out"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "brew_ensure"            tool_brew_ensure            '{"type":"object","properties":{}}' writes all brew
tool_register "brew_install"           tool_brew_install           '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' writes all brew
tool_register "brew_uninstall"         tool_brew_uninstall         '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' destructive all brew
tool_register "brew_upgrade"           tool_brew_upgrade           '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}}}' writes all brew
tool_register "brew_cleanup"           tool_brew_cleanup           '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' writes all brew
tool_register "brew_status"            tool_brew_status            '{"type":"object","properties":{}}' safe all brew
