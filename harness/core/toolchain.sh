# core/toolchain.sh — Toolchain profile detection (base, language-agnostic)
# Language-specific profiles are in harness/langs/*.sh

toolchain_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local tools=()
    [[ -f "$dir/package.json" ]] && tools+=(node) && [[ -f "$dir/tsconfig.json" ]] && tools+=(typescript)
    [[ -f "$dir/pyproject.toml" || -f "$dir/requirements.txt" || -f "$dir/setup.py" ]] && tools+=(python)
    [[ -f "$dir/Cargo.toml" ]] && tools+=(rust)
    [[ -f "$dir/go.mod" ]] && tools+=(go)
    [[ -f "$dir/CMakeLists.txt" || -f "$dir/Makefile" || -f "$dir/GNUmakefile" ]] && tools+=(c-cpp)
    [[ -f "$dir/Gemfile" || -f "$dir/Rakefile" ]] && tools+=(ruby)
    [[ -f "$dir/composer.json" ]] && tools+=(php)
    [[ -f "$dir/pom.xml" || -f "$dir/build.gradle" || -f "$dir/build.gradle.kts" ]] && tools+=(java)
    [[ -f "$dir/build.sbt" || -f "$dir/project/build.sbt" ]] && tools+=(scala)
    [[ -f "$dir/settings.gradle.kts" || -f "$dir/build.gradle.kts" ]] && grep -ql 'kotlin' "$dir/build.gradle.kts" 2>/dev/null && tools+=(kotlin)
    printf '%s\n' "${tools[*]}"
}

toolchain_profile_json() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local tools
    tools=$(toolchain_detect "$dir")
    local base
    base=$(jq -n --arg t "$tools" '
      {toolchain:$t,
       build:(if $t|contains("node") then "npm run build"
              elif $t|contains("python") then "python -m build"
              elif $t|contains("rust") then "cargo build"
              elif $t|contains("go") then "go build ./..."
              elif $t|contains("c-cpp") then "make"
              elif $t|contains("java") then "mvn package -DskipTests 2>/dev/null || gradle build"
              elif $t|contains("ruby") then "bundle exec rake compile 2>/dev/null"
              elif $t|contains("php") then "composer install --no-dev 2>/dev/null"
              else null end),
       test:(if $t|contains("node") then "npm test"
             elif $t|contains("python") then "pytest"
             elif $t|contains("rust") then "cargo test"
             elif $t|contains("go") then "go test ./..."
             elif $t|contains("c-cpp") then "ctest"
             elif $t|contains("java") then "mvn test 2>/dev/null || gradle test"
             elif $t|contains("ruby") then "bundle exec rspec"
             elif $t|contains("php") then "vendor/bin/phpunit"
             else null end),
       lint:(if $t|contains("node") then "npx eslint ."
             elif $t|contains("python") then "ruff check ."
             elif $t|contains("rust") then "cargo clippy"
             elif $t|contains("go") then "go vet ./..."
             elif $t|contains("java") then "mvn checkstyle:check 2>/dev/null"
             elif $t|contains("ruby") then "rubocop"
             elif $t|contains("php") then "vendor/bin/phpcs"
             else null end),
       format:(if $t|contains("node") then "npx prettier --write ."
               elif $t|contains("python") then "ruff format ."
               elif $t|contains("rust") then "cargo fmt"
               elif $t|contains("go") then "gofmt -w ."
               elif $t|contains("java") then "mvn spotless:apply 2>/dev/null"
               elif $t|contains("ruby") then "rubocop -a"
               elif $t|contains("php") then "vendor/bin/php-cs-fixer fix"
               else null end),
       run:(if $t|contains("node") then "npm start"
            elif $t|contains("rust") then "cargo run"
            elif $t|contains("go") then "go run ."
            elif $t|contains("java") then "mvn exec:java 2>/dev/null || gradle run"
            elif $t|contains("ruby") then "ruby main.rb"
            elif $t|contains("php") then "php index.php"
            else null end)}')
    # Overlay the primary language's rich profile (langs/*.sh) onto the generic
    # defaults: the language modules know pm/linter/formatter specifics the
    # static table can't (pnpm vs npm, biome/oxlint vs the eslint assumption).
    # Without this, lang_*_profile was consulted by nothing — lint.check et al
    # always got the hardcoded fallbacks.
    local primary="${tools%% *}" mapped fn overlay
    case "$primary" in
        node|typescript) mapped=nodejs ;;
        go)              mapped=golang ;;
        c-cpp)           mapped=ccpp ;;
        *)               mapped="$primary" ;;
    esac
    fn="lang_${mapped}_profile"
    if declare -F "$fn" &>/dev/null; then
        overlay=$("$fn" "$dir" 2>/dev/null)
        if [[ -n "$overlay" ]] && printf '%s' "$overlay" | jq -e . &>/dev/null; then
            printf '%s' "$base" | jq -c --argjson o "$overlay" \
                '. + ($o | with_entries(select(.value != null and .value != "")))'
            return 0
        fi
    fi
    printf '%s' "$base"
}
