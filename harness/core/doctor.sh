# core/doctor.sh — Dependency manifest and version checking

declare -A YCA_DEP_MANIFEST
declare -A YCA_DEP_STATUS
# Recommended MINIMUM versions, refreshed 2026-07-08 from the Homebrew stable
# release of each formula (verified with `brew info --json=v2`, major.minor).
# Languages pin to their latest LTS line where one exists — node@24 (npm is
# what node 24 bundles), openjdk@25 — and latest stable otherwise (Python, Go,
# Rust, Ruby, PHP have no LTS track). Advisory floors: doctor flags OUTDATED
# and offers `brew upgrade`, but never blocks. version_ge compares with
# `sort -V`, so two-component floors like 3.10 and 0.11 order correctly.
# Keep in sync with docs/DEPENDENCIES.md.
declare -A YCA_DEP_MINVER=(
    [bash]=5.3      [jq]=1.8        [git]=2.55      [curl]=8.21     [sqlite3]=3.53
    [rg]=15.1       [sd]=1.1        [ast-grep]=0.44 [duckdb]=1.5    [pandoc]=3.10
    [gh]=2.96       [shellcheck]=0.11 [hadolint]=2.14 [gitleaks]=8.30 [semgrep]=1.168
    [yq]=4.53       [ffmpeg]=8.1    [docker]=29.6   [kubectl]=1.36  [helm]=4.2
    [node]=24.0     [npm]=11.0      [python3]=3.14  [go]=1.26       [cargo]=1.96
    [ruby]=4.0      [php]=8.5       [java]=25       [cmake]=4.3
)

doctor_init_manifest() {
    # format: purpose|level|install_hint
    YCA_DEP_MANIFEST[bash]="runtime|core|already installed"
    YCA_DEP_MANIFEST[curl]="HTTP/LLM|core|apt install curl / brew install curl"
    YCA_DEP_MANIFEST[sqlite3]="datastore|core|apt install sqlite3 / brew install sqlite"
    YCA_DEP_MANIFEST[jq]="JSON|core|apt install jq / brew install jq"
    YCA_DEP_MANIFEST[git]="vcs|feature|apt install git / brew install git"
    YCA_DEP_MANIFEST[rg]="search|feature|apt install ripgrep / brew install ripgrep"
    YCA_DEP_MANIFEST[sd]="replace|feature|cargo install sd"
    YCA_DEP_MANIFEST[ast-grep]="structural|feature|cargo install ast-grep"
    YCA_DEP_MANIFEST[duckdb]="data|feature|brew install duckdb"
    YCA_DEP_MANIFEST[pandoc]="docs|feature|brew install pandoc"
    YCA_DEP_MANIFEST[pdftotext]="pdf|feature|apt install poppler-utils / brew install poppler"
    YCA_DEP_MANIFEST[semgrep]="security|feature|pip install semgrep"
    YCA_DEP_MANIFEST[ollama]="local-ai|feature|brew install ollama"
    YCA_DEP_MANIFEST[ffmpeg]="media|feature|brew install ffmpeg"
    YCA_DEP_MANIFEST[exiftool]="media-meta|feature|brew install exiftool"
    YCA_DEP_MANIFEST[gh]="pr|feature|brew install gh"
    YCA_DEP_MANIFEST[shellcheck]="shell-lint|feature|brew install shellcheck"
    YCA_DEP_MANIFEST[hadolint]="dockerfile-lint|feature|brew install hadolint"
    YCA_DEP_MANIFEST[gitleaks]="secrets|feature|brew install gitleaks"
    YCA_DEP_MANIFEST[fdupes]="dups|feature|brew install fdupes"
    YCA_DEP_MANIFEST[docker]="containers|feature|brew install docker"
    YCA_DEP_MANIFEST[kubectl]="k8s|feature|brew install kubectl"
    YCA_DEP_MANIFEST[helm]="helm|feature|brew install helm"
    YCA_DEP_MANIFEST[kubeconform]="k8s-validate|feature|brew install kubeconform"
    # CI/CD tools (ci category)
    YCA_DEP_MANIFEST[act]="ci-local|feature|brew install act"
    YCA_DEP_MANIFEST[actionlint]="ci-lint|feature|brew install actionlint"
    YCA_DEP_MANIFEST[yamllint]="yaml-lint|feature|pip install yamllint"
    # Media tools (media category)
    YCA_DEP_MANIFEST[ffprobe]="media-probe|feature|brew install ffmpeg"
    YCA_DEP_MANIFEST[imagemagick]="images|feature|brew install imagemagick"
    YCA_DEP_MANIFEST[whisper]="transcribe|feature|pip install openai-whisper"
    # Media downloader (ytdl category)
    YCA_DEP_MANIFEST[yt-dlp]="youtube-dl|feature|brew install yt-dlp / pip install -U yt-dlp"
    # Computer-use / CUA category — OS-specific screen+input backends. Which one
    # is needed depends on the display server (see lib/os.sh os_display_server):
    # macOS→cliclick, X11→xdotool+scrot/maim, Wayland→grim+wtype/ydotool.
    YCA_DEP_MANIFEST[cliclick]="cua-input-macos|feature|brew install cliclick"
    YCA_DEP_MANIFEST[xdotool]="cua-input-x11|feature|apt install xdotool / brew install xdotool"
    YCA_DEP_MANIFEST[scrot]="cua-shot-x11|feature|apt install scrot"
    YCA_DEP_MANIFEST[maim]="cua-shot-x11|feature|apt install maim"
    YCA_DEP_MANIFEST[grim]="cua-shot-wayland|feature|apt install grim"
    YCA_DEP_MANIFEST[wtype]="cua-input-wayland|feature|apt install wtype"
    YCA_DEP_MANIFEST[ydotool]="cua-input-wayland|feature|apt install ydotool (needs ydotoold + /dev/uinput)"
    YCA_DEP_MANIFEST[tesseract]="cua-ocr|feature|brew install tesseract / apt install tesseract-ocr"
    # Doc/data tools
    YCA_DEP_MANIFEST[yq]="yaml|feature|brew install yq"
    YCA_DEP_MANIFEST[psql]="postgres|feature|brew install libpq"
    YCA_DEP_MANIFEST[mysql]="mysql|feature|brew install mysql"
    YCA_DEP_MANIFEST[redis-cli]="redis|feature|brew install redis"
    # Languages
    YCA_DEP_MANIFEST[node]="nodejs|feature|brew install node"
    YCA_DEP_MANIFEST[npm]="nodejs|feature|installed with node"
    YCA_DEP_MANIFEST[pnpm]="nodejs|feature|npm install -g pnpm"
    YCA_DEP_MANIFEST[yarn]="nodejs|feature|npm install -g yarn"
    YCA_DEP_MANIFEST[python3]="python|feature|brew install python3"
    YCA_DEP_MANIFEST[pip]="python|feature|installed with python3"
    YCA_DEP_MANIFEST[cargo]="rust|feature|curl --proto =https --tlsv1.2 -sSf sh.rustup.rs | sh"
    YCA_DEP_MANIFEST[go]="golang|feature|brew install go"
    YCA_DEP_MANIFEST[gcc]="ccpp|feature|brew install gcc"
    YCA_DEP_MANIFEST[clang]="ccpp|feature|brew install llvm"
    YCA_DEP_MANIFEST[cmake]="ccpp|feature|brew install cmake"
    YCA_DEP_MANIFEST[make]="ccpp|feature|brew install make"
    YCA_DEP_MANIFEST[java]="java|feature|brew install openjdk"
    YCA_DEP_MANIFEST[mvn]="java|feature|brew install maven"
    YCA_DEP_MANIFEST[gradle]="java|feature|brew install gradle"
    YCA_DEP_MANIFEST[kotlinc]="kotlin|feature|brew install kotlin"
    YCA_DEP_MANIFEST[sbt]="scala|feature|brew install sbt"
    YCA_DEP_MANIFEST[ruby]="ruby|feature|brew install ruby"
    YCA_DEP_MANIFEST[bundle]="ruby|feature|gem install bundler"
    YCA_DEP_MANIFEST[php]="php|feature|brew install php"
    YCA_DEP_MANIFEST[composer]="php|feature|brew install composer"
}

doctor_check_one() {
    # Separate lines: a same-line `local name="$1" info="${arr[$name]}"` would
    # index the array with the CALLER's `name`, not this local (see
    # doctor_brew_formula). Callers that loop over a differently-named var (e.g.
    # `b`) would otherwise misread the manifest.
    local name="$1"
    local info="${YCA_DEP_MANIFEST[$name]:-}"
    [[ -z "$info" ]] && return 0
    local purpose level install_hint
    IFS='|' read -r purpose level install_hint <<< "$info"
    if ! command -v "$name" &>/dev/null; then
        YCA_DEP_STATUS[$name]="MISSING|$purpose|$install_hint"
        return 1
    fi
    YCA_DEP_STATUS[$name]="OK|$purpose|present"
    return 0
}

# doctor_probe_all — populate YCA_DEP_STATUS for every known dep WITHOUT logging.
# Returns the number missing. Used at startup so we show a calm one-line summary
# (startup_deps_notice) instead of a scary per-tool dump; the full list stays
# available on demand via the `doctor` workflow.
doctor_probe_all() {
    local missing=0 name
    for name in "${!YCA_DEP_MANIFEST[@]}"; do
        doctor_check_one "$name" || {
            [[ "${YCA_DEP_STATUS[$name]%%|*}" == "MISSING" ]] && ((missing++))
        }
    done
    return $missing
}

doctor_check_all() {
    local missing=0 name
    for name in "${!YCA_DEP_MANIFEST[@]}"; do
        doctor_check_one "$name" || {
            local kind="${YCA_DEP_STATUS[$name]%%|*}"
            [[ "$kind" == "MISSING" ]] && ((missing++))
        }
        local status="${YCA_DEP_STATUS[$name]:-}"
        local kind="${status%%|*}"
        [[ "$kind" == "MISSING" ]] && logmsg "$(c_fail "$SYM_FAIL") $name — ${YCA_DEP_MANIFEST[$name]##*|}  [MISSING]"
    done
    return $missing
}

# doctor_brew_formula NAME -> the brew formula for a dep, mined from its install
# hint (e.g. "apt install ripgrep / brew install ripgrep" -> "ripgrep"). Falls
# back to the binary name. Empty if the tool isn't brew-installable (pip/npm/…).
doctor_brew_formula() {
    # NOTE: declare on separate lines. `local name="$1" hint="${arr[$name]}"`
    # resolves $name in the hint to the *caller's* (often global loop) `name`,
    # not the local just assigned — a subtle bug that made every formula resolve
    # to the same wrong value.
    local name="$1"
    local hint="${YCA_DEP_MANIFEST[$name]##*|}"
    printf '%s' "$hint" | grep -oE 'brew install [A-Za-z0-9._+-]+' | head -1 | awk '{print $3}'
}

# doctor_offer_install BIN... — the "just fix it for me" path. In the human REPL
# we explain, ask once (plain y/n), and install brew-installable tools via
# Homebrew (auto-installing Homebrew itself if needed). Tools that need pip/npm/
# cargo are listed with their exact command. Re-probes afterwards. Returns 0 if
# everything asked-for is now present.
doctor_offer_install() {
    local bins=("$@"); [[ ${#bins[@]} -eq 0 ]] && return 0
    local brewable=() manual=() b f hint
    for b in "${bins[@]}"; do
        f=$(doctor_brew_formula "$b")
        hint="${YCA_DEP_MANIFEST[$b]##*|}"
        if [[ -n "$f" ]]; then brewable+=("$f"); else manual+=("$b — $hint"); fi
    done
    if [[ ${#manual[@]} -gt 0 ]]; then
        logmsg "$(c_info 'Some tools need their own installer:')"
        local m; for m in "${manual[@]}"; do logmsg "  $(c_dim "• $m")"; done
    fi
    [[ ${#brewable[@]} -eq 0 ]] && return 1
    logmsg "$(c_info "These can be installed for you with Homebrew: ${brewable[*]}")"
    local ans
    ans=$(prompt_user "install" "y" "Install them now? (Homebrew will be set up if needed) [Y/n]") || return 1
    case "${ans,,}" in
        n|no) logmsg "$(c_dim "Skipped. You can install later with: brew install ${brewable[*]}")"; return 1 ;;
    esac
    os_pkg_install "${brewable[@]}" || { logmsg "$(c_fail 'Install failed — see messages above.')"; return 1; }
    for b in "${bins[@]}"; do doctor_check_one "$b" 2>/dev/null || true; done   # re-probe
    logmsg "$(c_ok "$SYM_OK Done. Re-checked the tools.")"
    return 0
}

# doctor_check_needs BINS — gate a workflow/tool on its required binaries.
# Human mode: offer to install what's missing, re-check, and let the action
# proceed if it's now satisfied. Otherwise (or in json mode) emit ONE friendly,
# actionable error carrying the exact install command so a client/user can act.
doctor_check_needs() {
    local missing=() bin
    for bin in $1; do
        [[ -z "$bin" ]] && continue
        # Lazily probe a dep whose status hasn't been populated yet (e.g. the CLI
        # subcommand path skips the bulk doctor_probe_all for speed). command -v
        # is cheap, so this keeps the needs-gate correct without the full sweep.
        [[ -z "${YCA_DEP_STATUS[$bin]:-}" ]] && { doctor_check_one "$bin" || true; }
        [[ "${YCA_DEP_STATUS[$bin]:-}" != OK* ]] && missing+=("$bin")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0

    if [[ "$YCA_UI_MODE" == "human" ]]; then
        logmsg "$(c_warn "$SYM_WARN This action needs a tool that isn't installed: ${missing[*]}")"
        doctor_offer_install "${missing[@]}"
        local still=()
        for bin in "${missing[@]}"; do [[ "${YCA_DEP_STATUS[$bin]:-}" != OK* ]] && still+=("$bin"); done
        [[ ${#still[@]} -eq 0 ]] && return 0
        missing=("${still[@]}")
    fi

    # Build the install command from brew formulas (falling back to the raw hint).
    local formulas=() b f
    for b in "${missing[@]}"; do f=$(doctor_brew_formula "$b"); [[ -n "$f" ]] && formulas+=("$f"); done
    local install_cmd=""; [[ ${#formulas[@]} -gt 0 ]] && install_cmd="brew install ${formulas[*]}"
    local human="This action needs: ${missing[*]} (not installed)."
    [[ -n "$install_cmd" ]] && human+=" Install with: $install_cmd"
    emit error "$(jq -n --arg m "$human" --argjson miss "$(json_arr "${missing[@]}")" --arg inst "$install_cmd" \
        '{code:"deps_missing",message:$m,missing:$miss,install:$inst,installable:($inst|length>0)}')"
    return 1
}

# doctor_install_missing — install ALL currently-missing brew-installable deps.
# Backs the `doctor.install` workflow and the REPL `install-deps` command.
doctor_install_missing() {
    doctor_probe_all || true
    local missing=() name
    for name in "${!YCA_DEP_STATUS[@]}"; do
        [[ "${YCA_DEP_STATUS[$name]%%|*}" == "MISSING" ]] && missing+=("$name")
    done
    if [[ ${#missing[@]} -eq 0 ]]; then logmsg "$(c_ok "$SYM_OK All known tools are already installed.")"; return 0; fi
    doctor_offer_install "${missing[@]}"
}

# doctor_sqlite_info — the datastore engine is whichever `sqlite3` is first on
# PATH, and that varies per machine and per shell (e.g. macOS ships one build at
# /usr/bin/sqlite3 while Homebrew's — often newer — shadows it). Feature
# availability follows the RESOLVED binary, not any pinned version, so report
# the path, the version, and probe the optional capabilities the harness can
# exploit. Advisory only; never blocks.
doctor_sqlite_info() {
    local bin ver
    bin=$(command -v sqlite3 2>/dev/null) || return 0
    ver=$(sqlite3 -version 2>/dev/null | awk '{print $1}')
    local jsonb="no" subsec="no"
    [[ "$(sqlite3 :memory: "SELECT jsonb('{}') IS NOT NULL;" 2>/dev/null)" == "1" ]] && jsonb="yes"
    [[ -n "$(sqlite3 :memory: "SELECT unixepoch('subsec');" 2>/dev/null)" ]] && subsec="yes"
    log_kv "sqlite3" "$ver at $bin (jsonb: $jsonb, subsec time: $subsec)"
}

doctor_report() {
    local count=0 pass=0 fail=0 name
    for name in "${!YCA_DEP_MANIFEST[@]}"; do
        doctor_check_one "$name" 2>/dev/null || true
        local status="${YCA_DEP_STATUS[$name]:-}"
        local kind="${status%%|*}"
        count=$((count+1))
        if [[ "$kind" == "OK" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
    done
    doctor_sqlite_info
    # T9: profile configured LLM providers (metered ones are NEVER contacted) and
    # capture the connected host's capabilities; surface both in the report.
    doctor_profile_providers 2>/dev/null || true
    logmsg "$(doctor_print_profiles 2>/dev/null)"
    emit result "$(jq -n --argjson c "$count" --argjson p "$pass" --argjson f "$fail" \
        --argjson prof "$(profiles_json 2>/dev/null || echo '{}')" \
        '{ok:true,summary:("checked "+($c|tostring)+" deps: "+($p|tostring)+" ok, "+($f|tostring)+" issues"),data:{checked:$c,ok:$p,issues:$f,profiles:$prof}}')"
}

doctor_install_hint() {
    local name="$1"
    local info="${YCA_DEP_MANIFEST[$name]:-}"
    printf '%s' "${info##*|}"
}

# doctor_tool_version NAME -> best-effort installed semver (e.g. "14.1.0"), empty
# if it can't be determined. Handles the tools that don't use `--version`.
doctor_tool_version() {
    local name="$1" out=""
    command -v "$name" &>/dev/null || return 1
    case "$name" in
        go)      out=$(go version 2>/dev/null) ;;
        kubectl) out=$(kubectl version --client 2>/dev/null | head -1) ;;
        java)    out=$(java -version 2>&1 | head -1) ;;
        docker)  out=$(docker --version 2>/dev/null) ;;
        # helm 4 dropped --version; `version --short` works on 3 and 4.
        helm)    out=$(helm version --short 2>/dev/null | head -1) ;;
        # shellcheck's first line is a title; the version is on line 2.
        shellcheck) out=$(shellcheck --version 2>/dev/null | grep -i '^version:' | head -1) ;;
        *)       out=$("$name" --version 2>&1 | head -1) ;;
    esac
    printf '%s' "$out" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1
}

# doctor_versions_report — compare installed vs. recommended-minimum versions and
# emit a friendly table (to stderr) plus a result frame. Never blocks; OUTDATED
# is advisory, and in the human REPL we offer a one-shot `brew upgrade`.
doctor_versions_report() {
    local rows=("TOOL|INSTALLED|MIN(2026-07)|STATUS") name minv cur
    local ok=0 outdated=0 missing=0 stale=()
    for name in $(printf '%s\n' "${!YCA_DEP_MINVER[@]}" | sort); do
        minv="${YCA_DEP_MINVER[$name]}"
        if ! command -v "$name" &>/dev/null; then
            rows+=("$name|—|$minv|not installed"); ((missing++)); continue
        fi
        cur=$(doctor_tool_version "$name")
        if [[ -z "$cur" ]]; then
            rows+=("$name|?|$minv|installed (version unreadable)"); ((ok++)); continue
        fi
        if version_ge "$cur" "$minv"; then
            rows+=("$name|$cur|$minv|ok"); ((ok++))
        else
            rows+=("$name|$cur|$minv|OUTDATED"); ((outdated++)); stale+=("$name")
        fi
    done
    printf '%s\n' "${rows[@]}" | column -t -s'|' >&2
    if [[ "$YCA_UI_MODE" == "human" && ${#stale[@]} -gt 0 ]]; then
        local formulas=() b f
        for b in "${stale[@]}"; do f=$(doctor_brew_formula "$b"); [[ -n "$f" ]] && formulas+=("$f"); done
        if [[ ${#formulas[@]} -gt 0 ]]; then
            local ans
            ans=$(prompt_user "upgrade" "y" "Upgrade the outdated tools with Homebrew now? [Y/n]") || ans=n
            case "${ans,,}" in n|no) : ;; *) os_brew_ensure && HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade "${formulas[@]}" 2>&1 | tail -8 >&2 ;; esac
        fi
    fi
    emit result "$(jq -n --argjson ok "$ok" --argjson out "$outdated" --argjson miss "$missing" \
        '{ok:true,summary:("versions — \($ok) ok, \($out) outdated, \($miss) missing"),data:{ok:$ok,outdated:$out,missing:$miss}}')"
}
