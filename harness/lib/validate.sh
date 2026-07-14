# lib/15-validate.sh — Input validation utilities

# val_required VALUE NAME -> error if empty
val_required() {
    local val="$1" name="$2"
    [[ -z "$val" ]] && { log_error "$name is required"; return 1; }
    return 0
}

# val_is_int VALUE [NAME]
val_is_int() {
    math_is_int "$1" || { log_error "${2:-value} must be an integer (got: $1)"; return 1; }
}

# val_is_number VALUE [NAME]
val_is_number() {
    math_is_number "$1" || { log_error "${2:-value} must be a number (got: $1)"; return 1; }
}

# val_in_range VALUE MIN MAX [NAME]
val_in_range() {
    local val="$1" lo="$2" hi="$3" name="${4:-value}"
    val_is_number "$val" "$name" || return 1
    math_between "$val" "$lo" "$hi" || { log_error "$name must be between $lo and $hi"; return 1; }
}

# val_in_list VALUE LIST... -> 0 if VALUE matches any of LIST
val_in_list() {
    local val="$1"; shift
    local item
    for item in "$@"; do
        [[ "$val" == "$item" ]] && return 0
    done
    log_error "value must be one of: $* (got: $val)"
    return 1
}

# val_file_exists PATH
val_file_exists() {
    [[ -f "$1" ]] || { log_error "file not found: $1"; return 1; }
}

# val_dir_exists PATH
val_dir_exists() {
    [[ -d "$1" ]] || { log_error "directory not found: $1"; return 1; }
}

# val_path_safe PATH -> 0 if within allowed paths
val_path_safe() {
    path_check_allowed "$1" || { log_error "path outside allowed directory: $1"; return 1; }
}

# val_command_exists CMD...
val_command_exists() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    log_error "missing required commands: ${missing[*]}"
    return 1
}

# val_port NUMBER
val_port() {
    val_is_int "$1" "port" || return 1
    val_in_range "$1" 1 65535 "port" || return 1
}

# val_url URL -> basic URL format check
val_url() {
    [[ "$1" =~ ^https?://[a-zA-Z0-9.-]+ ]] || { log_error "invalid URL: $1"; return 1; }
}

# val_email EMAIL
val_email() {
    [[ "$1" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]] || { log_error "invalid email: $1"; return 1; }
}

# val_branch_name NAME -> valid git branch name
val_branch_name() {
    local name="$1"
    [[ -z "$name" ]] && { log_error "branch name required"; return 1; }
    [[ "$name" =~ [\ \~\^\:\?\*\[\]\\] ]] && { log_error "invalid branch name: $name"; return 1; }
    [[ "$name" == .* || "$name" == *.* ]] && { log_error "branch name cannot start/end with dot: $name"; return 1; }
    return 0
}

# val_workflow_id ID -> valid workflow id (category.action)
val_workflow_id() {
    [[ "$1" =~ ^[a-z][a-z0-9-]*\.[a-z][a-z0-9-]*$ ]] || { log_error "invalid workflow id: $1"; return 1; }
}

# val_choice INPUT DEFAULT CHOICES... -> echoes chosen value or default
# For [Y]es [n]o [e]dit style prompts
val_choice() {
    local input="$1" default="$2"; shift 2
    [[ -z "$input" ]] && { printf '%s' "$default"; return 0; }
    local choice lower_input
    lower_input=$(str_lower "$input")
    for choice in "$@"; do
        local lower_choice
        lower_choice=$(str_lower "$choice")
        # Match first char or full word
        [[ "$lower_input" == "${lower_choice:0:1}" || "$lower_input" == "$lower_choice" ]] && { printf '%s' "$choice"; return 0; }
    done
    printf '%s' "$default"
}
