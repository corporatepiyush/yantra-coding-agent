# langs/ruby.sh — Ruby tools and workflows
# Rich introspection: detect gem manager, test runner, linter, security
# scanners, and report which are installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_ruby_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/Gemfile" || -f "$dir/Rakefile" ]] && return 0
    ls "$dir"/*.gemspec 2>/dev/null | grep -q . && return 0
    return 1
}

lang_ruby_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local test="bundle exec rspec"
    if [[ -f "$dir/Gemfile" ]]; then
        if grep -q 'rspec-rails\|rspec' "$dir/Gemfile" 2>/dev/null; then
            test="bundle exec rspec"
        elif grep -q 'minitest\|minitest-rails' "$dir/Gemfile" 2>/dev/null; then
            test="bundle exec rake test"
        fi
    fi
    [[ -d "$dir/spec" ]] && test="bundle exec rspec"
    [[ -d "$dir/test" ]] && ! grep -q 'rspec\|rspec-rails' "$dir/Gemfile" 2>/dev/null && test="bundle exec rake test"

    local lint="rubocop"
    [[ -f "$dir/.rubocop.yml" ]] && lint="rubocop"

    local format="rubocop -a"
    local rails="false"
    [[ -f "$dir/config/application.rb" ]] && grep -q '^module\|class.*Application' "$dir/config/application.rb" 2>/dev/null && rails="true"

    local run="ruby main.rb"
    [[ "$rails" == "true" ]] && run="rails server"

    local ru=""
    ru=$(ruby --version 2>&1)
    local bu=""
    bu=$(bundle --version 2>&1)
    local ra=""
    [[ "$rails" == "true" ]] && ra=$(rails --version 2>&1)

    jq -n --arg test "$test" --arg lint "$lint" --arg format "$format" \
          --argjson rails "$rails" --arg run "$run" \
          --arg ruby "$ru" --arg bundle "$bu" --arg rails_v "$ra" \
        '{build:"bundle exec rake compile", test:$test, lint:$lint, format:$format, run:$run, rails:$rails, ruby_version:$ruby, bundle_version:$bundle, rails_version:$rails_v}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_ruby_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_ruby_bundle_exec() { (cd "$YCA_PROJECT_DIR" && bundle exec "$@" 2>&1); }
_ruby_bundle() { (cd "$YCA_PROJECT_DIR" && bundle "$@" 2>&1); }
_ruby_missing() { printf 'tool missing: %s\ninstall: %s\n' "$1" "$2"; }

# ── Bundler / deps ─────────────────────────────────────────────────────────
tool_ruby_bundle_install() {
    command -v bundle &>/dev/null || { _ruby_missing "bundler" "gem install bundler"; return 1; }
    _ruby_bundle install
}

# dep_add — `bundle add <gem>` resolves + fetches the gem and mutates
# Gemfile/Gemfile.lock. The gem name is validated (no leading '-', no shell
# metacharacters) and passed as ARGV, never interpolated.
tool_ruby_dep_add() {
    local pkg safe
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    command -v bundle &>/dev/null || { _ruby_missing "bundler" "gem install bundler"; return 1; }
    confirm_action "add dependency $safe to ruby project" "bundle add $safe" || { confirm_denied_msg; return 1; }
    _ruby_bundle add "$safe"
}

tool_ruby_bundle_outdated() {
    command -v bundle &>/dev/null || { _ruby_missing "bundler" "gem install bundler"; return 1; }
    _ruby_bundle outdated
}

tool_ruby_bundle_audit() {
    command -v bundler-audit &>/dev/null || { _ruby_missing "bundler-audit" "gem install bundler-audit"; return 1; }
    _ruby_bundle exec bundler-audit check --update
}

tool_ruby_bundle_list() {
    command -v bundle &>/dev/null || { _ruby_missing "bundler" "gem install bundler"; return 1; }
    _ruby_bundle list
}

# ── Test ───────────────────────────────────────────────────────────────────
tool_ruby_rspec() {
    command -v rspec &>/dev/null || { _ruby_missing "rspec" "gem install rspec"; return 1; }
    _ruby_bundle_exec rspec
}

tool_ruby_rspec_cov() {
    command -v rspec &>/dev/null || { _ruby_missing "rspec" "gem install rspec"; return 1; }
    local helper
    helper=$(find "$YCA_PROJECT_DIR/spec" -name spec_helper.rb 2>/dev/null | head -1)
    if [[ -n "$helper" ]] && grep -q 'simplecov' "$helper" 2>/dev/null; then
        _ruby_bundle_exec rspec
    else
        printf 'SimpleCov not configured in spec_helper.\ninstall: gem install simplecov, add require to spec_helper\n'
        _ruby_bundle_exec rspec --format documentation
    fi
}

tool_ruby_minitest() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/Rakefile" ]] && grep -q 'test\|minitest' "$dir/Rakefile" 2>/dev/null; then
        _ruby_run bundle exec rake test
    elif ls "$dir/test"/*_test.rb 2>/dev/null | grep -q .; then
        _ruby_run ruby -Itest
    elif ls "$dir/test"/*_spec.rb 2>/dev/null | grep -q .; then
        _ruby_run ruby -Itest
    else
        printf 'no test files found in test/'; return 1
    fi
}

# ── Lint / format ──────────────────────────────────────────────────────────
tool_ruby_rubocop() {
    command -v rubocop &>/dev/null || { _ruby_missing "rubocop" "gem install rubocop"; return 1; }
    _ruby_run rubocop
}

tool_ruby_rubocop_fix() {
    command -v rubocop &>/dev/null || { _ruby_missing "rubocop" "gem install rubocop"; return 1; }
    _ruby_run rubocop -a
}

tool_ruby_standardrb() {
    command -v standardrb &>/dev/null || { _ruby_missing "standardrb" "gem install standard"; return 1; }
    [[ -f "$YCA_PROJECT_DIR/.standard.yml" ]] || { printf 'no .standard.yml found'; return 1; }
    _ruby_run standardrb --fix
}

# ── Security ───────────────────────────────────────────────────────────────
tool_ruby_brakeman() {
    command -v brakeman &>/dev/null || { _ruby_missing "brakeman" "gem install brakeman"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    if [[ ! -f "$dir/config/application.rb" ]]; then
        printf 'warning: not a Rails app — brakeman may produce limited results\n'
    fi
    _ruby_run brakeman --no-progress
}

tool_ruby_reek() {
    command -v reek &>/dev/null || { _ruby_missing "reek" "gem install reek"; return 1; }
    _ruby_run reek .
}

# ── Performance ────────────────────────────────────────────────────────────
tool_ruby_fasterer() {
    command -v fasterer &>/dev/null || { _ruby_missing "fasterer" "gem install fasterer"; return 1; }
    _ruby_run fasterer
}

# ── Rails-specific ─────────────────────────────────────────────────────────
tool_ruby_rails_bestpractices() {
    command -v rails_best_practices &>/dev/null || { _ruby_missing "rails_best_practices" "gem install rails_best_practices"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    [[ -f "$dir/config/application.rb" ]] || { printf 'not a Rails app'; return 1; }
    _ruby_run rails_best_practices .
}

# ── Markdown lint ──────────────────────────────────────────────────────────
tool_ruby_mdl() {
    command -v mdl &>/dev/null || { _ruby_missing "mdl" "gem install mdl"; return 1; }
    local dir="$YCA_PROJECT_DIR"
    ls "$dir"/*.md 2>/dev/null | grep -q . || { printf 'no markdown files found'; return 0; }
    _ruby_run mdl "$dir"/*.md
}

# ── Run ────────────────────────────────────────────────────────────────────
tool_ruby_run() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/config/application.rb" ]]; then
        command -v rails &>/dev/null || { _ruby_missing "rails" "gem install rails"; return 1; }
        _ruby_run rails server
    elif [[ -f "$dir/main.rb" ]]; then
        _ruby_run ruby main.rb
    else
        printf 'no main.rb or Rails app found'; return 1
    fi
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_ruby_doctor() {
    local dir="$YCA_PROJECT_DIR" out=""
    out+="Ruby: $(ruby --version 2>&1 || echo 'missing')\n"
    out+="Interpreter: $(command -v ruby || echo 'missing')\n"
    out+="Bundler: $(bundle --version 2>&1 || echo 'missing')\n"
    out+="Gem: $(gem --version 2>&1 || echo 'missing')\n"
    out+="Rails: "
    if [[ -f "$dir/config/application.rb" ]]; then
        out+="$(rails --version 2>&1 || echo 'NOT installed')\n"
    else
        out+="not a Rails project\n"
    fi
    out+="\nTool status:\n"
    local t
    for t in rubocop standardrb brakeman reek fasterer rspec minitest mdl rails_best_practices bundler-audit simplecov; do
        local v
        if command -v "$t" &>/dev/null; then v="ok"
        else v="MISSING"; fi
        out+="  $t: $v\n"
    done
    printf '%b' "$out"
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "ruby_bundle_install"      tool_ruby_bundle_install      '{"type":"object","properties":{}}' writes all ruby
tool_register "ruby_dep_add"             tool_ruby_dep_add             '{"description":"Add a Ruby gem via bundle add (fetches code + mutates Gemfile/lock) — gated","type":"object","properties":{"package":{"type":"string","description":"gem name (e.g. rails or nokogiri)"}},"required":["package"]}' writes all ruby
tool_register "ruby_bundle_outdated"     tool_ruby_bundle_outdated     '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_bundle_audit"        tool_ruby_bundle_audit        '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_bundle_list"         tool_ruby_bundle_list         '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_rspec"               tool_ruby_rspec               '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_rspec_cov"           tool_ruby_rspec_cov           '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_minitest"            tool_ruby_minitest            '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_rubocop"             tool_ruby_rubocop             '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_rubocop_fix"         tool_ruby_rubocop_fix         '{"type":"object","properties":{}}' writes all ruby
tool_register "ruby_standardrb"          tool_ruby_standardrb          '{"type":"object","properties":{}}' writes all ruby
tool_register "ruby_brakeman"            tool_ruby_brakeman            '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_reek"                tool_ruby_reek                '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_fasterer"            tool_ruby_fasterer            '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_rails_bestpractices" tool_ruby_rails_bestpractices '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_mdl"                 tool_ruby_mdl                 '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_run"                 tool_ruby_run                 '{"type":"object","properties":{}}' safe all ruby
tool_register "ruby_doctor"              tool_ruby_doctor              '{"type":"object","properties":{}}' safe all ruby