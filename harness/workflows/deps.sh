# workflows/deps.sh — Dependency workflows

wf_deps_install() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *node*)   cmd="npm install" ;;
        *python*) cmd="pip install -r requirements.txt 2>/dev/null || pip install -e ." ;;
        *rust*)   cmd="cargo fetch" ;;
        *go*)     cmd="go mod download" ;;
        *ruby*)   cmd="bundle install" ;;
        *php*)    cmd="composer install" ;;
        *java*)   cmd="mvn install -DskipTests 2>/dev/null || gradle build" ;;
        *) emit_fail "no package manager detected"; return 1 ;;
    esac
    emit_progress "deps" "$cmd"
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" '{ok:($rc==0),summary:"deps installed"'})"
}

# deps.add — toolchain-aware add-a-dependency. Detects the primary language and
# dispatches to the matching per-language *_dep_add tool via tool_invoke (which
# runs the tool's own name validation + consent gate). Input: package.
wf_deps_add() {
    local pkg kind primary tool
    pkg="${INPUT_package:-}"
    [[ -n "$pkg" ]] || { emit_fail "package required (input: package)"; return 1; }
    kind=$(toolchain_detect)
    primary="${kind%% *}"
    case "$primary" in
        node|typescript) tool="nodejs_dep_add" ;;
        python)          tool="python_dep_add" ;;
        rust)            tool="rust_dep_add" ;;
        go)              tool="go_dep_add" ;;
        c-cpp)           tool="ccpp_dep_add" ;;
        ruby)            tool="ruby_dep_add" ;;
        php)             tool="php_dep_add" ;;
        java)            tool="java_dep_add" ;;
        scala)           tool="scala_dep_add" ;;
        kotlin)          tool="kotlin_dep_add" ;;
        *) emit_fail "no supported toolchain detected for dep add"; return 1 ;;
    esac
    emit_progress "deps" "add $pkg via $tool"
    local args out rc
    args=$(jq -n --arg p "$pkg" '{package:$p}')
    out=$(tool_invoke "$tool" "$args") && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" --arg t "$tool" --arg p "$pkg" \
        '{ok:($rc==0),summary:("dep add "+$p+" via "+$t),data:{tool:$t,rc:$rc}}')"
}

wf_deps_audit() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *node*)   cmd="npm audit 2>/dev/null" ;;
        *python*) cmd="pip-audit 2>/dev/null || safety check 2>/dev/null" ;;
        *rust*)   cmd="cargo audit 2>/dev/null" ;;
        *) emit_fail "no audit tool detected"; return 1 ;;
    esac
    emit_progress "audit" "scanning for skeletons in the dependency closet"
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit_ok "audit done"
}

wf_deps_update() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *node*)   cmd="npm update" ;;
        *python*) cmd="pip install --upgrade -r requirements.txt 2>/dev/null" ;;
        *rust*)   cmd="cargo update" ;;
        *go*)     cmd="go get -u ./..." ;;
        *) emit_fail "no package manager"; return 1 ;;
    esac
    confirm_action "Update dependencies" "$cmd" || { emit_fail "cancelled"; return 0; }
    emit_progress "deps" ""
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit_ok "deps updated"
}

wf_deps_tree() {
    command -v tree &>/dev/null && tree -I 'node_modules|__pycache__|.git' "${INPUT_path:-$YCA_PROJECT_DIR}" || ls -R "${INPUT_path:-$YCA_PROJECT_DIR}" | head -100
    emit_ok "tree shown"
}

wf_deps_licenses() {
    if command -v pip-licenses &>/dev/null; then pip-licenses
    elif command -v npx &>/dev/null; then (cd "$YCA_PROJECT_DIR" && npx license-checker --summary 2>/dev/null)
    else emit_fail "install pip-licenses or license-checker"; return 1; fi
    emit_ok "licenses shown"
}

# deps.risk — one report: what's outdated, what's vulnerable, what's unpinned,
# and the upgrade order that doesn't blow up the sprint (zero LLM).
wf_deps_risk() {
    local kind
    kind=$(toolchain_detect)
    [[ -z "$kind" ]] && { emit_fail "no toolchain detected"; return 1; }
    emit_progress "deps" "risk survey ($kind)" 10

    # 1) outdated
    local outdated_cmd="" out
    case "$kind" in
        *node*)   outdated_cmd="npm outdated 2>/dev/null" ;;
        *python*) outdated_cmd="pip list --outdated 2>/dev/null" ;;
        *rust*)   outdated_cmd="cargo outdated 2>/dev/null" ;;
        *go*)     outdated_cmd="go list -u -m all 2>/dev/null | grep '\\[' " ;;
    esac
    logmsg "$(c_info '═══ Dependency risk ═══')"
    logmsg "$(c_info '1) Outdated:')"
    local n_outdated=0
    if [[ -n "$outdated_cmd" ]]; then
        out=$(cd "$YCA_PROJECT_DIR" && eval "$outdated_cmd" || true)
        if [[ -n "$out" ]]; then
            printf '%s\n' "$out" | head -20 | sed 's/^/    /' >&2
            n_outdated=$(grep -c . <<< "$out" || true)
        else
            logmsg "    (none reported)"
        fi
    else
        logmsg "    (no outdated-checker for this toolchain)"
    fi

    # 2) audit
    logmsg "$(c_info '2) Known vulnerabilities:')"
    local audit_cmd="" audit_rc=0
    case "$kind" in
        *node*)   audit_cmd="npm audit 2>/dev/null" ;;
        *python*) audit_cmd="pip-audit 2>/dev/null || safety check 2>/dev/null" ;;
        *rust*)   audit_cmd="cargo audit 2>/dev/null" ;;
        *go*)     audit_cmd="govulncheck ./... 2>/dev/null" ;;
    esac
    if [[ -n "$audit_cmd" ]]; then
        out=$(cd "$YCA_PROJECT_DIR" && eval "$audit_cmd") && audit_rc=0 || audit_rc=$?
        printf '%s\n' "$out" | tail -15 | sed 's/^/    /' >&2
    else
        logmsg "    (no audit tool for this toolchain)"
    fi

    # 3) loose specs in the manifest
    logmsg "$(c_info '3) Loose/unreproducible version specs:')"
    local -a loose=()
    if [[ -f "$YCA_PROJECT_DIR/package.json" ]]; then
        out=$(jq -r '((.dependencies // {}) + (.devDependencies // {})) | to_entries[] | select(.value | test("^\\*$|^latest$|^git\\+|^http|^>[=]?[0-9]+(\\.[0-9x*]+)*$")) | "\(.key): \(.value)"' "$YCA_PROJECT_DIR/package.json" 2>/dev/null)
        [[ -n "$out" ]] && while IFS= read -r n; do loose+=("npm $n"); done <<< "$out"
        [[ -f "$YCA_PROJECT_DIR/package-lock.json" || -f "$YCA_PROJECT_DIR/yarn.lock" || -f "$YCA_PROJECT_DIR/pnpm-lock.yaml" ]] || loose+=("npm: NO LOCKFILE — every install is a dice roll")
    fi
    if [[ -f "$YCA_PROJECT_DIR/requirements.txt" ]]; then
        out=$(grep -vE '^\s*(#|-r|-e|$)' "$YCA_PROJECT_DIR/requirements.txt" 2>/dev/null | grep -vE '==' | head -10 || true)
        [[ -n "$out" ]] && while IFS= read -r n; do loose+=("pip unpinned: $n"); done <<< "$out"
    fi
    if [[ -f "$YCA_PROJECT_DIR/Cargo.toml" ]] && grep -sqE '^[a-zA-Z0-9_-]+[[:space:]]*=[[:space:]]*\{[^}]*git[[:space:]]*=' "$YCA_PROJECT_DIR/Cargo.toml"; then
        loose+=("cargo: git dependency in Cargo.toml")
    fi
    grep -sq -- '-SNAPSHOT' "$YCA_PROJECT_DIR/pom.xml" "$YCA_PROJECT_DIR/build.gradle" "$YCA_PROJECT_DIR/build.gradle.kts" 2>/dev/null && \
        loose+=("jvm: SNAPSHOT dependency in the build file")
    local n
    if [[ ${#loose[@]} -gt 0 ]]; then
        for n in "${loose[@]}"; do logmsg "$(c_warn "    ⚠ $n")"; done
    else
        logmsg "    (specs look pinned)"
    fi

    logmsg ""
    logmsg "$(c_info 'Upgrade order (the senior sequence):')"
    logmsg "  1. security fixes FIRST, whatever their size — they jump the queue"
    logmsg "  2. patch bumps in one batch (x.y.Z) — run tests once over the batch"
    logmsg "  3. minor bumps in small groups (x.Y.z) — read changelogs of anything core"
    logmsg "  4. majors ONE AT A TIME, each in its own PR with its own test run"
    logmsg "  5. pin what the survey flagged loose, and commit the lockfile"
    logmsg "  Never mix a dependency upgrade with a feature change in one PR."

    local ok=true; [[ "$audit_rc" -ne 0 ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --argjson o "$n_outdated" --argjson l "${#loose[@]}" --argjson a "$audit_rc" \
        '{ok:$ok,summary:("deps risk: "+($o|tostring)+" outdated, "+($l|tostring)+" loose spec(s), audit rc "+($a|tostring)),data:{outdated:$o,loose:$l,audit_rc:$a}}')"
}

wf_register "deps.install"  wf_deps_install  1 writes "" "Install dependencies"
wf_register "deps.add"      wf_deps_add      1 writes "" "Add a dependency (toolchain-aware)"
wf_register "deps.audit"    wf_deps_audit    1 safe "" "Security audit dependencies"
wf_register "deps.update"   wf_deps_update   1 writes "" "Update dependencies"
wf_register "deps.tree"     wf_deps_tree     1 safe "" "Show dependency tree"
wf_register "deps.licenses" wf_deps_licenses 1 safe "" "Check license compliance"
wf_register "deps.risk"     wf_deps_risk     1 safe "" "Outdated+audit+loose specs with a senior upgrade order"
