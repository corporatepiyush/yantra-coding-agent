# langs/php.sh — PHP tools and workflows
# Rich introspection: detect composer, test framework, static analyzer, linter,
# formatter, and framework presence with install hints for each tool.

# ── Detection ──────────────────────────────────────────────────────────────
lang_php_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/composer.json" || -f "$dir/index.php" || -f "$dir/artisan" || -f "$dir/bin/console" ]]
}

lang_php_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"

    local phpver=""
    phpver=$(php --version 2>&1 | head -1)

    # Composer
    local composer="composer"
    command -v composer &>/dev/null || composer="NOT_INSTALLED"

    # Test framework — check composer.json require-dev then config files
    local test="vendor/bin/phpunit"
    if [[ -f "$dir/composer.json" ]]; then
        if jq -e '.["require-dev"] // {} | has("pestphp/pest")' "$dir/composer.json" &>/dev/null; then
            test="vendor/bin/pest"
        elif jq -e '.["require-dev"] // {} | has("phpunit/phpunit")' "$dir/composer.json" &>/dev/null; then
            test="vendor/bin/phpunit"
        fi
    fi
    if [[ -f "$dir/pest.xml" || -f "$dir/phpunit.xml" || -f "$dir/phpunit.xml.dist" ]]; then
        :
    fi

    # Static analyzer — check composer.json require-dev then config files
    local static=""
    if [[ -f "$dir/psalm.xml" || -f "$dir/psalm.xml.dist" || -f "$dir/psalm-baseline.xml" ]]; then
        static="vendor/bin/psalm"
    elif [[ -f "$dir/phpstan.neon" || -f "$dir/phpstan.neon.dist" ]]; then
        static="vendor/bin/phpstan analyse"
    fi
    if [[ -f "$dir/composer.json" && -z "$static" ]]; then
        jq -e '.["require-dev"] // {} | has("vimeo/psalm")' "$dir/composer.json" &>/dev/null && static="vendor/bin/psalm"
        jq -e '.["require-dev"] // {} | has("phpstan/phpstan")' "$dir/composer.json" &>/dev/null && static="vendor/bin/phpstan analyse"
    fi

    # Linter / formatter
    local lint="vendor/bin/phpcs" format="vendor/bin/php-cs-fixer fix"
    [[ -f "$dir/.php-cs-fixer.php" || -f "$dir/.php-cs-fixer.dist.php" ]] && format="vendor/bin/php-cs-fixer fix"
    if [[ ! -f "$dir/.phpcs.xml" && ! -f "$dir/.phpcs.xml.dist" && ! -f "$dir/phpcs.xml" ]]; then
        # no phpcs config — prefer php-cs-fixer for lint if available
        lint="$format --dry-run"
    fi

    # Framework — laravel / symfony
    local run="php index.php"
    if [[ -f "$dir/artisan" ]] && command -v php &>/dev/null; then
        run="php artisan serve"
    elif [[ -f "$dir/bin/console" ]] && command -v php &>/dev/null; then
        run="php bin/console"
    fi

    local framework="none"
    [[ -f "$dir/artisan" ]] && framework="laravel"
    [[ -f "$dir/bin/console" ]] && framework="symfony"

    jq -n --arg phpver "$phpver" --arg composer "$composer" --arg test "$test" \
          --arg lint "$lint" --arg format "$format" --arg static "$static" \
          --arg run "$run" --arg framework "$framework" \
        '{build:"composer install --no-dev", test:$test, lint:$lint, format:$format, static_analysis:$static, run:$run, php_version:$phpver, framework:$framework, composer:$composer}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_php_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_php_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_php_composer_json_check() {
    local key="$1"
    [[ -f "$YCA_PROJECT_DIR/composer.json" ]] || return 1
    jq -e ".[\"require-dev\"] // {} | has(\"$key\")" "$YCA_PROJECT_DIR/composer.json" &>/dev/null
}

# ── Composer / deps ────────────────────────────────────────────────────────
tool_php_composer_install() {
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer / apt install composer / https://getcomposer.org"; return 1; }
    _php_run composer install 2>&1
}

# dep_add — `composer require <pkg>` resolves + fetches the package (may run
# scripts) and mutates composer.json/composer.lock. The package name is
# validated (no leading '-', no shell metacharacters) and passed as ARGV.
tool_php_dep_add() {
    local pkg safe
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer / https://getcomposer.org"; return 1; }
    confirm_action "add dependency $safe to php project" "composer require $safe" || { confirm_denied_msg; return 1; }
    _php_run composer require "$safe" 2>&1
}

tool_php_composer_update() {
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer"; return 1; }
    local dry_run="${1:-}"
    if [[ -n "$dry_run" ]]; then
        _php_run composer update --dry-run 2>&1
    else
        _php_run composer update 2>&1
    fi
}

tool_php_composer_outdated() {
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer"; return 1; }
    _php_run composer outdated 2>&1
}

tool_php_composer_audit() {
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer"; return 1; }
    _php_run composer audit 2>&1
}

tool_php_composer_why() {
    local pkg="$1"
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer"; return 1; }
    [[ -n "$pkg" ]] || { printf 'package name required (arg2: .name)'; return 1; }
    _php_run composer why "$pkg" 2>&1
}

tool_php_composer_show() {
    command -v composer &>/dev/null || { _php_missing "composer" "brew install composer"; return 1; }
    _php_run composer show 2>&1
}

# ── Test ───────────────────────────────────────────────────────────────────
tool_php_phpunit() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpunit"
    [[ -x "$runner" ]] || runner=$(command -v phpunit 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "phpunit" "composer require --dev phpunit/phpunit"; return 1; }
    _php_run "$runner" 2>&1
}

tool_php_pest() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/pest"
    [[ -x "$runner" ]] || { _php_missing "pest" "composer require --dev pestphp/pest --with-all-dependencies"; return 1; }
    _php_run "$runner" 2>&1
}

tool_php_phpunit_cov() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpunit"
    [[ -x "$runner" ]] || { _php_missing "phpunit" "composer require --dev phpunit/phpunit"; return 1; }
    php -m | grep -iqE 'xdebug|pcov' || { printf 'coverage driver missing\ninstall: pecl install xdebug / pecl install pcov'; return 1; }
    _php_run "$runner" --coverage-text 2>&1
}

# ── Lint / format ──────────────────────────────────────────────────────────
tool_php_phpcs() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpcs"
    [[ -x "$runner" ]] || runner=$(command -v phpcs 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "phpcs" "composer require --dev squizlabs/php_codesniffer"; return 1; }
    _php_run "$runner" 2>&1
}

tool_php_phpcbf() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpcbf"
    [[ -x "$runner" ]] || runner=$(command -v phpcbf 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "phpcbf" "composer require --dev squizlabs/php_codesniffer"; return 1; }
    _php_run "$runner" 2>&1
}

tool_php_cs_fixer() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/php-cs-fixer"
    [[ -x "$runner" ]] || runner=$(command -v php-cs-fixer 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "php-cs-fixer" "composer require --dev friendsofphp/php-cs-fixer"; return 1; }
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        _php_run "$runner" fix "$target" 2>&1
    else
        _php_run "$runner" fix 2>&1
    fi
}

tool_php_cs_fixer_check() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/php-cs-fixer"
    [[ -x "$runner" ]] || runner=$(command -v php-cs-fixer 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "php-cs-fixer" "composer require --dev friendsofphp/php-cs-fixer"; return 1; }
    local target="${1:-}"
    if [[ -n "$target" ]]; then
        _php_run "$runner" fix --dry-run --diff "$target" 2>&1
    else
        _php_run "$runner" fix --dry-run --diff 2>&1
    fi
}

# ── Static analysis ────────────────────────────────────────────────────────
tool_php_psalm() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/psalm"
    [[ -x "$runner" ]] || { _php_missing "psalm" "composer require --dev vimeo/psalm"; return 1; }
    _php_run "$runner" 2>&1
}

tool_php_psalm_taint() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/psalm"
    [[ -x "$runner" ]] || { _php_missing "psalm" "composer require --dev vimeo/psalm"; return 1; }
    _php_run "$runner" --taint-analysis 2>&1
}

tool_php_phpstan() {
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpstan"
    [[ -x "$runner" ]] || runner=$(command -v phpstan 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "phpstan" "composer require --dev phpstan/phpstan"; return 1; }
    _php_run "$runner" analyse 2>&1
}

tool_php_phpstan_level() {
    local level="${1:-max}"
    local runner="$YCA_PROJECT_DIR/vendor/bin/phpstan"
    [[ -x "$runner" ]] || runner=$(command -v phpstan 2>/dev/null)
    [[ -n "$runner" ]] || { _php_missing "phpstan" "composer require --dev phpstan/phpstan"; return 1; }
    _php_run "$runner" analyse --level="$level" 2>&1
}

# ── Run ────────────────────────────────────────────────────────────────────
tool_php_run() {
    command -v php &>/dev/null || { _php_missing "php" "brew install php / apt install php-cli"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/artisan" ]]; then
        _php_run php artisan serve 2>&1
    elif [[ -f "$dir/bin/console" ]]; then
        _php_run php bin/console 2>&1
    elif [[ -f "$dir/index.php" ]]; then
        _php_run php index.php 2>&1
    else
        printf 'no entry point found (index.php / artisan / bin/console)'
        return 1
    fi
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_php_doctor() {
    local dir="$YCA_PROJECT_DIR" out=""
    out+="PHP: $(php --version 2>&1 | head -1 || echo 'missing')\n"
    out+="Interpreter: $(command -v php || echo 'missing')\n"
    out+="Composer: $(composer --version 2>&1 || echo 'NOT installed')\n"
    out+="\n"
    local -a tools=(phpunit pest phpcs phpcbf php-cs-fixer psalm phpstan)
    for t in "${tools[@]}"; do
        local v
        if [[ -x "$dir/vendor/bin/$t" ]]; then
            local ver
            ver=$("$dir/vendor/bin/$t" --version 2>&1 | head -1)
            out+="$t: $ver\n"
        elif command -v "$t" &>/dev/null; then
            local ver
            ver=$("$t" --version 2>&1 | head -1)
            out+="$t (global): $ver\n"
        else
            out+="$t: MISSING\n"
        fi
    done
    # Framework detection
    out+="\nFramework: "
    if [[ -f "$dir/artisan" ]]; then out+="Laravel"
    elif [[ -f "$dir/bin/console" ]]; then out+="Symfony"
    else out+="none detected"; fi
    out+="\n"
    # Config files
    out+="Configs:"
    for cfg in psalm.xml phpstan.neon .php-cs-fixer.dist.php .phpcs.xml.dist phpunit.xml.dist pest.xml; do
        if [[ -f "$dir/$cfg" ]]; then out+=" $cfg"; fi
    done
    out+="\n"
    # Security advisories
    if _php_composer_json_check "roave/security-advisories"; then
        out+="roave/security-advisories: installed\n"
    fi
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "php_composer_install"  tool_php_composer_install  '{"type":"object","properties":{}}' writes all php
tool_register "php_dep_add"           tool_php_dep_add           '{"description":"Add a PHP dependency via composer require (fetches code + mutates composer.json/lock) — gated","type":"object","properties":{"package":{"type":"string","description":"vendor/package, optionally versioned (e.g. guzzlehttp/guzzle or monolog/monolog:^3.0)"}},"required":["package"]}' writes all php
tool_register "php_composer_update"  tool_php_composer_update   '{"type":"object","properties":{"command":{"type":"string","description":"the shell command to run"}}}' safe all php
tool_register "php_composer_outdated" tool_php_composer_outdated '{"type":"object","properties":{}}' safe all php
tool_register "php_composer_audit"    tool_php_composer_audit    '{"type":"object","properties":{}}' safe all php
tool_register "php_composer_why"      tool_php_composer_why      '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all php
tool_register "php_composer_show"     tool_php_composer_show     '{"type":"object","properties":{}}' safe all php
tool_register "php_phpunit"           tool_php_phpunit           '{"type":"object","properties":{}}' safe all php
tool_register "php_pest"              tool_php_pest              '{"type":"object","properties":{}}' safe all php
tool_register "php_phpunit_cov"       tool_php_phpunit_cov       '{"type":"object","properties":{}}' safe all php
tool_register "php_phpcs"             tool_php_phpcs             '{"type":"object","properties":{}}' safe all php
tool_register "php_phpcbf"            tool_php_phpcbf            '{"type":"object","properties":{}}' writes all php
tool_register "php_cs_fixer"          tool_php_cs_fixer          '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' writes all php
tool_register "php_cs_fixer_check"    tool_php_cs_fixer_check    '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all php
tool_register "php_psalm"             tool_php_psalm             '{"type":"object","properties":{}}' safe all php
tool_register "php_psalm_taint"       tool_php_psalm_taint       '{"type":"object","properties":{}}' safe all php
tool_register "php_phpstan"           tool_php_phpstan           '{"type":"object","properties":{}}' safe all php
tool_register "php_phpstan_level"     tool_php_phpstan_level     '{"type":"object","properties":{"value":{"type":"string","description":"the value to set"}}}' safe all php
tool_register "php_run"               tool_php_run               '{"type":"object","properties":{}}' safe all php
tool_register "php_doctor"            tool_php_doctor            '{"type":"object","properties":{}}' safe all php