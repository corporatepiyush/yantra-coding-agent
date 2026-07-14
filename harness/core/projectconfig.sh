# core/projectconfig.sh — yantra.config.json is the single source of truth.
#
# Precedence (highest wins):  CLI flag  >  env var  >  project file  >  global file  >  built-in default
#
#   • global file : $XDG_CONFIG_HOME/yantra/yantra.config.json  (or ~/.config/…)
#   • project file: <project>/yantra.config.json
# The project file overrides the global one. Neither is ever written to during a
# session — runtime changes (e.g. `tools enable ssh`) live in memory only. On
# startup, if the project has no file yet, we create one seeded with defaults so
# the user has something to edit.

# projectconfig_defaults — the built-in base config (also the auto-created template).
projectconfig_defaults() {
    jq -n --arg v "$YCA_CONFIG_VERSION" '{
        version: $v,
        providers: { think: [], build: [], tool: [] },
        routing:   { sticky: true, fallback: "down" },
        tools:     { enabled: ["core"], complexity_overrides: {} },
        safety:    { confirm_destructive: true },
        update:    { enabled: true, branch: "main" },
        log:       { level: "info" }
    }'
}

# projectconfig_paths — resolve global + project file locations (may not exist).
projectconfig_paths() {
    local cfg_home="${XDG_CONFIG_HOME:-$HOME/.config}"
    YCA_CONFIG_GLOBAL_PATH="${HARNESS_CONFIG_GLOBAL:-$cfg_home/yantra/yantra.config.json}"
    YCA_CONFIG_PROJECT_PATH="${HARNESS_CONFIG:-$YCA_PROJECT_DIR/yantra.config.json}"
}

# _pc_read_file PATH -> file contents if it is a valid JSON object, else '{}'.
_pc_read_file() {
    local f="$1"
    [[ -f "$f" ]] || { printf '{}'; return 0; }
    local body
    body=$(<"$f")
    if printf '%s' "$body" | jq -e 'type == "object"' >/dev/null 2>&1; then
        printf '%s' "$body"
    else
        log_warn "ignoring malformed config: $f (not a JSON object)"
        printf '{}'
    fi
}

# projectconfig_load — build the effective config and apply it to runtime.
projectconfig_load() {
    projectconfig_paths
    local defaults global project
    defaults=$(projectconfig_defaults)
    global=$(_pc_read_file "$YCA_CONFIG_GLOBAL_PATH")
    project=$(_pc_read_file "$YCA_CONFIG_PROJECT_PATH")

    # Auto-create the project file (seeded with defaults) if it is missing, so the
    # user has a documented starting point. Never overwrite an existing file.
    if [[ ! -f "$YCA_CONFIG_PROJECT_PATH" && -n "$YCA_PROJECT_DIR" ]]; then
        if printf '%s\n' "$defaults" > "$YCA_CONFIG_PROJECT_PATH" 2>/dev/null; then
            log_info "created default config: $YCA_CONFIG_PROJECT_PATH"
        fi
    fi

    # Deep-merge objects (arrays are replaced wholesale, so project providers
    # replace global providers rather than concatenating). project wins.
    YCA_CONFIG_JSON=$(jq -s '.[0] * .[1] * .[2]' \
        <(printf '%s' "$defaults") <(printf '%s' "$global") <(printf '%s' "$project") \
        2>/dev/null || printf '%s' "$defaults")

    projectconfig_apply
}

# _cfg FILTER [DEFAULT] — read a value from the effective config JSON.
_cfg() {
    local filter="$1" default="${2:-}" val
    val=$(printf '%s' "$YCA_CONFIG_JSON" | jq -r "$filter // empty" 2>/dev/null)
    printf '%s' "${val:-$default}"
}

# projectconfig_apply — push the effective config into runtime globals.
# env vars still win over file values (session override, never persisted).
declare -A YCA_COMPLEXITY_OVERRIDE=()
projectconfig_apply() {
    # Providers block → providers.sh consumes YCA_PROVIDERS_JSON.
    YCA_PROVIDERS_JSON=$(printf '%s' "$YCA_CONFIG_JSON" | jq -c '.providers // {}' 2>/dev/null || printf '{}')

    # Scalar knobs: env wins, else file, else the built-in default already in the global.
    YCA_SAFETY_CONFIRM="${HARNESS_SAFETY_CONFIRM:-$(_cfg '.safety.confirm_destructive' "$YCA_SAFETY_CONFIRM")}"
    YCA_UPDATE_ENABLED="${HARNESS_UPDATE_ENABLED:-$(_cfg '.update.enabled' "$YCA_UPDATE_ENABLED")}"
    YCA_UPDATE_BRANCH="${HARNESS_BRANCH:-$(_cfg '.update.branch' "$YCA_UPDATE_BRANCH")}"
    YCA_LOG_LEVEL="${HARNESS_LOG_LEVEL:-$(_cfg '.log.level' "$YCA_LOG_LEVEL")}"

    # Complexity overrides: name → high|mid|low (applied at registry lookup time).
    YCA_COMPLEXITY_OVERRIDE=()
    local k v
    while IFS=$'\t' read -r k v; do
        [[ -z "$k" ]] && continue
        YCA_COMPLEXITY_OVERRIDE[$k]="$v"
    done < <(printf '%s' "$YCA_CONFIG_JSON" | jq -r '(.tools.complexity_overrides // {}) | to_entries[] | "\(.key)\t\(.value)"' 2>/dev/null)
}

# projectconfig_enabled_categories — categories the config turns on at startup.
# Applied by main() after DB defaults so file + detected-language cats compose.
projectconfig_enabled_categories() {
    printf '%s' "$YCA_CONFIG_JSON" | jq -r '(.tools.enabled // []) | .[]' 2>/dev/null
}
