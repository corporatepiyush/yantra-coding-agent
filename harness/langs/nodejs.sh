# langs/nodejs.sh — Node.js/JavaScript/TypeScript tools and workflows
# Rich introspection: detect package manager, test framework, linter, formatter,
# type checker, module system, and report which are installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_nodejs_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/package.json" ]]
}

lang_nodejs_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local pm="npm"
    [[ -f "$dir/pnpm-lock.yaml" ]] && pm="pnpm"
    [[ -f "$dir/yarn.lock" ]] && pm="yarn"
    [[ -f "$dir/bun.lockb" || -f "$dir/bun.lock" ]] && pm="bun"
    local node_version="" has_ts="false" module_type="cjs" test_framework=""
    local linter="" formatter="" devdeps="" has_lint_script="false" has_format_script="false"
    node_version=$(node --version 2>&1)
    [[ -f "$dir/tsconfig.json" ]] && has_ts="true"
    if [[ -f "$dir/package.json" ]]; then
        local mt
        mt=$(jq -r '.type // "commonjs"' "$dir/package.json" 2>/dev/null)
        [[ "$mt" == "module" ]] && module_type="esm"
        devdeps=$(jq -r '((.devDependencies // {}) + (.dependencies // {})) | keys[]' "$dir/package.json" 2>/dev/null)
        jq -e '.scripts.lint' "$dir/package.json" &>/dev/null && has_lint_script="true"
        jq -e '.scripts.format' "$dir/package.json" &>/dev/null && has_format_script="true"
        # Detect test framework from scripts or devDependencies
        local scripts_tests
        scripts_tests=$(jq -r '.scripts | to_entries[] | select(.key | test("test")) | .value' "$dir/package.json" 2>/dev/null)
        if echo "$scripts_tests" | grep -q 'vitest'; then test_framework="vitest"
        elif echo "$scripts_tests" | grep -q 'jest'; then test_framework="jest"
        elif echo "$scripts_tests" | grep -q 'mocha'; then test_framework="mocha"
        elif echo "$scripts_tests" | grep -q 'playwright'; then test_framework="playwright"
        else
            if echo "$devdeps" | grep -q 'vitest'; then test_framework="vitest"
            elif echo "$devdeps" | grep -q 'jest'; then test_framework="jest"
            elif echo "$devdeps" | grep -q 'mocha'; then test_framework="mocha"
            elif echo "$devdeps" | grep -q 'playwright'; then test_framework="playwright"
            fi
        fi
    fi
    # Linter/formatter: Rust-first detection order (biome > oxlint > eslint;
    # biome > prettier) — a project that adopted the Rust toolchain gets it
    # used, instead of the eslint/prettier assumption.
    if [[ -f "$dir/biome.json" || -f "$dir/biome.jsonc" ]] || grep -qx '@biomejs/biome' <<< "$devdeps"; then
        linter="biome"; formatter="biome"
    fi
    if [[ -z "$linter" ]] && { [[ -f "$dir/.oxlintrc.json" ]] || grep -qx 'oxlint' <<< "$devdeps"; }; then
        linter="oxlint"
    fi
    if [[ -z "$linter" ]] && { _node_eslint_config "$dir" || grep -q '^eslint$' <<< "$devdeps"; }; then
        linter="eslint"
    fi
    if [[ -z "$formatter" ]] && { _scan_exists "$dir"/.prettierrc* "$dir"/prettier.config.* || grep -qx 'prettier' <<< "$devdeps"; }; then
        formatter="prettier"
    fi
    # Commands: an explicit package script always wins (the project's choice);
    # otherwise run the detected tool from node_modules/.bin.
    local lint_cmd="$pm run lint" format_cmd="$pm run format"
    if [[ "$has_lint_script" != "true" && -n "$linter" ]]; then
        case "$linter" in
            biome)  lint_cmd="./node_modules/.bin/biome check ." ;;
            oxlint) lint_cmd="./node_modules/.bin/oxlint ." ;;
            eslint) lint_cmd="./node_modules/.bin/eslint ." ;;
        esac
    fi
    if [[ "$has_format_script" != "true" && -n "$formatter" ]]; then
        case "$formatter" in
            biome)    format_cmd="./node_modules/.bin/biome format --write ." ;;
            prettier) format_cmd="./node_modules/.bin/prettier --write ." ;;
        esac
    fi
    jq -n --arg pm "$pm" --arg nv "$node_version" --argjson ts "$has_ts" \
          --arg mt "$module_type" --arg tf "$test_framework" \
          --arg lint "$lint_cmd" --arg fmt "$format_cmd" \
          --arg linter "$linter" --arg formatter "$formatter" \
        '{build:($pm+" run build"),test:($pm+" test"),lint:$lint,format:$fmt,run:($pm+" start"),package_manager:$pm,node_version:$nv,typescript:$ts,module_type:$mt,test_framework:$tf,linter:$linter,formatter:$formatter}'
}

# _node_eslint_config DIR -> 0 if any eslint config file exists.
_node_eslint_config() {
    local dir="$1"
    _scan_exists "$dir"/.eslintrc.js "$dir"/.eslintrc.cjs "$dir"/.eslintrc.yaml \
        "$dir"/.eslintrc.yml "$dir"/.eslintrc.json "$dir"/eslint.config.js "$dir"/eslint.config.mjs
}

# ── Helpers ────────────────────────────────────────────────────────────────
_node_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_node_pm() {
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/pnpm-lock.yaml" ]] && { echo "pnpm"; return; }
    [[ -f "$dir/yarn.lock" ]] && { echo "yarn"; return; }
    [[ -f "$dir/bun.lockb" || -f "$dir/bun.lock" ]] && { echo "bun"; return; }
    echo "npm"
}
_node_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# _node_has_tool BIN -> 0 if BIN is on PATH or installed in the project's
# node_modules/.bin (the normal home of devDependency CLIs).
_node_has_tool() {
    command -v "$1" &>/dev/null && return 0
    [[ -x "$YCA_PROJECT_DIR/node_modules/.bin/$1" ]]
}

# _node_tool BIN ARGS... — run a project CLI: PATH binary first, else the
# project's own node_modules/.bin copy. Never `npx <pkg>` for a missing tool:
# that downloads and EXECUTES unpinned registry code. Callers gate on
# _node_has_tool and print an install hint instead.
_node_tool() {
    local bin="$1"; shift
    if command -v "$bin" &>/dev/null; then _node_run "$bin" "$@"
    else _node_run "./node_modules/.bin/$bin" "$@"; fi
}

# ── Install / deps ─────────────────────────────────────────────────────────
tool_nodejs_install() {
    local dir="$YCA_PROJECT_DIR" pm
    pm=$(_node_pm)
    case "$pm" in
        pnpm) _node_run pnpm install ;;
        yarn) _node_run yarn install ;;
        bun)  _node_run bun install ;;
        *)    _node_run npm install ;;
    esac
}

# dep_add — package-manager-aware add (npm install / pnpm|yarn|bun add). The
# package name is validated (no leading '-', no shell metacharacters) and passed
# as ARGV, never interpolated. Adding a dep fetches + may run install scripts +
# mutates the lockfile → gated.
tool_nodejs_dep_add() {
    local pkg safe pm sub
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    pm=$(_node_pm)
    command -v "$pm" &>/dev/null || { _node_missing "$pm" "install $pm (or use npm)"; return 1; }
    case "$pm" in
        npm) sub="install" ;;   # `npm install <pkg>` adds + saves to package.json
        *)   sub="add" ;;       # pnpm/yarn/bun use `add`
    esac
    confirm_action "add dependency $safe to nodejs project ($pm)" "$pm $sub $safe" || { confirm_denied_msg; return 1; }
    _node_run "$pm" "$sub" "$safe"
}

tool_nodejs_audit() {
    local pm
    pm=$(_node_pm)
    case "$pm" in
        pnpm) _node_run pnpm audit ;;
        yarn) _node_run yarn audit ;;
        bun)  _node_run bun audit ;;
        *)    _node_run npm audit ;;
    esac
}

tool_nodejs_outdated() {
    local pm
    pm=$(_node_pm)
    case "$pm" in
        pnpm) _node_run pnpm outdated ;;
        yarn) _node_run yarn outdated ;;
        bun)  _node_run bun outdated ;;
        *)    _node_run npm outdated ;;
    esac
}

tool_nodejs_list_deps() {
    local pm
    pm=$(_node_pm)
    case "$pm" in
        pnpm) _node_run pnpm ls --depth=0 ;;
        yarn) _node_run yarn list --depth=0 ;;
        bun)  _node_run bun pm ls ;;
        *)    _node_run npm ls --depth=0 ;;
    esac
}

tool_nodejs_why() {
    local pkg="$1"
    [[ -n "$pkg" ]] || { printf 'package name required (use "name" arg2)'; return 1; }
    local pm
    pm=$(_node_pm)
    case "$pm" in
        pnpm) _node_run pnpm why "$pkg" ;;
        yarn) _node_run yarn why "$pkg" ;;
        bun)  _node_run bun pm why "$pkg" ;;
        *)    _node_run npm explain "$pkg" ;;
    esac
}

# ── Type checking ──────────────────────────────────────────────────────────
tool_nodejs_ts_check() {
    command -v tsc &>/dev/null || command -v npx &>/dev/null || { _node_missing "tsc" "npm i -g typescript"; return 1; }
    _node_run npx tsc --noEmit 2>&1
}

tool_nodejs_ts_coverage() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx type-coverage 2>&1 || _node_missing "type-coverage" "npm i -D type-coverage"
}

# ── Lint / format ──────────────────────────────────────────────────────────
tool_nodejs_eslint() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/.eslintrc.js" || -f "$dir/.eslintrc.cjs" || -f "$dir/.eslintrc.yaml" || -f "$dir/.eslintrc.yml" || -f "$dir/.eslintrc.json" || -f "$dir/eslint.config.js" || -f "$dir/eslint.config.mjs" ]]; then
        _node_run npx eslint --fix .
    else
        _node_run npx eslint --fix . 2>&1 || _node_missing "eslint" "npm i -D eslint"
    fi
}

tool_nodejs_eslint_check() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx eslint . 2>&1 || _node_missing "eslint" "npm i -D eslint"
}

tool_nodejs_prettier() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx prettier --write . 2>&1 || _node_missing "prettier" "npm i -D prettier"
}

tool_nodejs_prettier_check() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx prettier --check . 2>&1 || _node_missing "prettier" "npm i -D prettier"
}

# ── Test / coverage ────────────────────────────────────────────────────────
tool_nodejs_test() {
    local dir="$YCA_PROJECT_DIR"
    # Check for pm test script first
    if jq -e '.scripts.test' "$dir/package.json" &>/dev/null; then
        _node_run "$(_node_pm)" test
    elif command -v vitest &>/dev/null; then
        _node_run npx vitest run
    elif command -v jest &>/dev/null; then
        _node_run npx jest
    else
        _node_missing "test runner" "npm i -D vitest"
    fi
}

tool_nodejs_test_watch() {
    local dir="$YCA_PROJECT_DIR"
    if command -v vitest &>/dev/null || jq -e '.scripts.test' "$dir/package.json" | grep -q 'vitest' 2>/dev/null; then
        _node_run npx vitest --watch
    elif command -v jest &>/dev/null || jq -e '.scripts.test' "$dir/package.json" | grep -q 'jest' 2>/dev/null; then
        _node_run npx jest --watch
    else
        _node_missing "test runner (vitest/jest)" "npm i -D vitest"
    fi
}

tool_nodejs_test_cov() {
    local dir="$YCA_PROJECT_DIR"
    if command -v vitest &>/dev/null; then
        _node_run npx vitest --coverage
    elif command -v jest &>/dev/null; then
        _node_run npx jest --coverage
    else
        _node_missing "test runner with coverage (vitest/jest)" "npm i -D vitest"
    fi
}

tool_nodejs_playwright() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx playwright test 2>&1 || _node_missing "playwright" "npm i -D @playwright/test"
}

tool_nodejs_playwright_ui() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx playwright test --ui 2>&1 || _node_missing "playwright" "npm i -D @playwright/test"
}

# ── Build / run ────────────────────────────────────────────────────────────
tool_nodejs_build() {
    local dir="$YCA_PROJECT_DIR"
    if jq -e '.scripts.build' "$dir/package.json" &>/dev/null; then
        _node_run "$(_node_pm)" run build
    else
        printf 'no "build" script in package.json'
        return 1
    fi
}

tool_nodejs_run() {
    local dir="$YCA_PROJECT_DIR"
    if jq -e '.scripts.start' "$dir/package.json" &>/dev/null; then
        _node_run "$(_node_pm)" start
    elif jq -e '.scripts.dev' "$dir/package.json" &>/dev/null; then
        _node_run "$(_node_pm)" run dev
    else
        printf 'no "start" or "dev" script in package.json'
        return 1
    fi
}

# ── Bundle / license analysis ──────────────────────────────────────────────
tool_nodejs_bundle_analyze() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/vite.config.ts" || -f "$dir/vite.config.js" ]]; then
        _node_run npx vite-bundle-visualizer 2>&1 || _node_missing "vite-bundle-visualizer" "npm i -D vite-bundle-visualizer"
    elif [[ -f "$dir/webpack.config.js" || -f "$dir/webpack.config.ts" ]]; then
        _node_run npx webpack-bundle-analyzer dist/stats.json 2>&1 || _node_missing "webpack-bundle-analyzer" "npm i -D webpack-bundle-analyzer"
    else
        printf 'no vite or webpack config detected'
        return 1
    fi
}

tool_nodejs_license_check() {
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx license-checker --summary 2>&1 || _node_missing "license-checker" "npm i -g license-checker"
}

# ── Rust-based JS toolchain (oxc / swc / Biome) ─────────────────────────────
# The ecosystem is moving to Rust-built tools: oxlint (the oxc linter,
# 50–100× ESLint's speed), Biome (linter+formatter, the Rome successor), and
# swc (the compiler under Next.js/Jest). These run them when the project has
# adopted them; availability is gated (no npx auto-download of registry code).

# oxlint — the oxc linter. Whole-repo lint in milliseconds; no config needed.
tool_nodejs_oxlint() {
    _node_has_tool oxlint || { _node_missing "oxlint (Rust linter, oxc)" "npm i -D oxlint"; return 1; }
    _node_tool oxlint .
}

tool_nodejs_oxlint_fix() {
    _node_has_tool oxlint || { _node_missing "oxlint (Rust linter, oxc)" "npm i -D oxlint"; return 1; }
    _node_tool oxlint --fix .
}

# Biome — lint + format in one Rust binary (biome.json configured projects).
tool_nodejs_biome_check() {
    _node_has_tool biome || { _node_missing "biome (Rust linter+formatter)" "npm i -D @biomejs/biome"; return 1; }
    _node_tool biome check .
}

tool_nodejs_biome_fix() {
    _node_has_tool biome || { _node_missing "biome (Rust linter+formatter)" "npm i -D @biomejs/biome"; return 1; }
    _node_tool biome check --write .
}

# swc — Rust compiler/transpiler. Compiles src -> out (default src/ -> dist/).
tool_nodejs_swc_build() {
    _node_has_tool swc || { _node_missing "swc (Rust compiler, @swc/cli)" "npm i -D @swc/cli @swc/core"; return 1; }
    local src out
    src=$(tool_arg src "src"); out=$(tool_arg out "dist")
    path_check_allowed "$YCA_PROJECT_DIR/$out" || return 1
    _node_tool swc "$src" -d "$out"
}

# ── Npx passthrough ────────────────────────────────────────────────────────
tool_nodejs_npx() {
    local cmd="$1"
    [[ -n "$cmd" ]] || { printf 'command required (use "command" arg1)'; return 1; }
    command -v npx &>/dev/null || { _node_missing "npx" "npm i -g npx"; return 1; }
    _node_run npx "$cmd"
}

# ── Project introspection ──────────────────────────────────────────────────
tool_nodejs_scripts() {
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/package.json" ]] || { printf 'no package.json'; return 1; }
    jq -r '.scripts // {} | to_entries[] | "\(.key)\t\(.value)"' "$dir/package.json" 2>/dev/null \
        || printf 'no scripts defined'
}

tool_nodejs_entry() {
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/package.json" ]] || { printf 'no package.json'; return 1; }
    jq '{name, version, main, module, types, bin, exports} | with_entries(select(.value != null))' "$dir/package.json" 2>&1
}

tool_nodejs_engines() {
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/package.json" ]] || { printf 'no package.json'; return 1; }
    printf 'declared engines: %s\n' "$(jq -c '.engines // "none"' "$dir/package.json" 2>/dev/null)"
    printf 'current node:     %s\n' "$(node --version 2>&1)"
    printf 'current npm:      %s\n' "$(npm --version 2>&1)"
    [[ -f "$dir/.nvmrc" ]] && printf '.nvmrc:           %s\n' "$(<"$dir/.nvmrc")"
    printf '(mismatch here explains "works on my machine" CI failures)\n'
}

# pack_check — what would actually be published (npm pack dry-run).
tool_nodejs_pack_check() {
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/package.json" ]] || { printf 'no package.json'; return 1; }
    _node_run npm pack --dry-run 2>&1 | tail -50
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_nodejs_doctor() {
    local dir="$YCA_PROJECT_DIR" out="" pm
    pm=$(_node_pm)
    out+="Node: $(node --version 2>&1 || echo 'missing')\n"
    out+="Path: $(command -v node || echo 'missing')\n"
    out+="Package manager: $pm"
    case "$pm" in
        pnpm) out+=" ($(pnpm --version 2>&1 || echo 'NOT installed'))" ;;
        yarn) out+=" ($(yarn --version 2>&1 || echo 'NOT installed'))" ;;
        bun)  out+=" ($(bun --version 2>&1 || echo 'NOT installed'))" ;;
        *)    out+=" ($(npm --version 2>&1))" ;;
    esac
    out+="\nModule type: "
    local mt
    mt=$(jq -r '.type // "commonjs"' "$dir/package.json" 2>/dev/null)
    out+="$mt\n"
    out+="TypeScript: "
    [[ -f "$dir/tsconfig.json" ]] && out+="detected" || out+="none"
    out+="\n"
    local t
    for t in npx tsc eslint prettier oxlint biome swc vitest jest playwright; do
        local v
        # PATH or the project's node_modules/.bin — devDependency CLIs live there.
        v=$(_node_has_tool "$t" && printf ' ok' || printf ' MISSING')
        out+="$t:$v\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "nodejs_install"        tool_nodejs_install        '{"type":"object","properties":{}}' writes all nodejs
tool_register "nodejs_dep_add"        tool_nodejs_dep_add        '{"description":"Add a JS/TS dependency via the detected package manager (fetches code + mutates the lockfile) — gated","type":"object","properties":{"package":{"type":"string","description":"package name, optionally versioned (e.g. left-pad or react@18)"}},"required":["package"]}' writes all nodejs
tool_register "nodejs_audit"          tool_nodejs_audit          '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_outdated"       tool_nodejs_outdated       '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_list_deps"             tool_nodejs_list_deps             '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_why"            tool_nodejs_why            '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all nodejs
tool_register "nodejs_ts_check"       tool_nodejs_ts_check       '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_ts_coverage"    tool_nodejs_ts_coverage    '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_eslint"         tool_nodejs_eslint         '{"type":"object","properties":{}}' writes all nodejs
tool_register "nodejs_eslint_check"   tool_nodejs_eslint_check   '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_prettier"       tool_nodejs_prettier       '{"type":"object","properties":{}}' writes all nodejs
tool_register "nodejs_prettier_check" tool_nodejs_prettier_check '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_test"           tool_nodejs_test           '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_test_watch"     tool_nodejs_test_watch     '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_test_cov"       tool_nodejs_test_cov       '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_playwright"     tool_nodejs_playwright     '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_playwright_ui"  tool_nodejs_playwright_ui  '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_build"          tool_nodejs_build          '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_run"            tool_nodejs_run            '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_bundle_analyze" tool_nodejs_bundle_analyze '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_license_check"  tool_nodejs_license_check  '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_npx"            tool_nodejs_npx            '{"type":"object","properties":{"command":{"type":"string","description":"the shell command to run"}},"required":["command"]}' writes all nodejs
tool_register "nodejs_doctor"         tool_nodejs_doctor         '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_scripts"        tool_nodejs_scripts        '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_entry"          tool_nodejs_entry          '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_engines"        tool_nodejs_engines        '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_pack_check"     tool_nodejs_pack_check     '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_oxlint"         tool_nodejs_oxlint         '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_oxlint_fix"     tool_nodejs_oxlint_fix     '{"type":"object","properties":{}}' writes all nodejs
tool_register "nodejs_biome_check"    tool_nodejs_biome_check    '{"type":"object","properties":{}}' safe all nodejs
tool_register "nodejs_biome_fix"      tool_nodejs_biome_fix      '{"type":"object","properties":{}}' writes all nodejs
tool_register "nodejs_swc_build"      tool_nodejs_swc_build      '{"type":"object","properties":{"src":{"type":"string","description":"source path"},"out":{"type":"string","description":"output path"}}}' writes all nodejs
