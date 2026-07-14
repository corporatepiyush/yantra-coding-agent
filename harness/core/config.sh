# core/config.sh — Session config store.
# yantra.config.json (loaded by core/projectconfig.sh) is the single source of
# truth. Anything set here is a SESSION-ONLY override: it lives in memory and is
# never written back to the JSON file or the DB.

declare -A YCA_SESSION_CONFIG=()

# config_resolve — finalize a few derived globals after the config file is applied.
config_resolve() {
    YCA_SAFETY_PATHS="${YCA_SAFETY_PATHS:-$YCA_PROJECT_DIR}"
}

# config_get KEY -> session override value (empty if unset).
config_get() {
    printf '%s' "${YCA_SESSION_CONFIG[$1]:-}"
}

# config_set KEY VALUE — set a session-only override (not persisted).
config_set() {
    YCA_SESSION_CONFIG[$1]="$2"
}

# config_show — print session overrides as key|value lines.
config_show() {
    local k
    for k in "${!YCA_SESSION_CONFIG[@]}"; do
        printf '%s|%s\n' "$k" "${YCA_SESSION_CONFIG[$k]}"
    done | sort
}

config_detect_sed() {
    if command -v sd &>/dev/null; then printf 'sd'
    elif sed --version 2>&1 | grep -q GNU; then printf 'sed -i'
    else printf 'sed -i '\'''
    fi
}
