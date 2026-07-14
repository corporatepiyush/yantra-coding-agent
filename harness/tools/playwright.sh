# tools/playwright.sh — Playwright end-to-end testing.
#
# Why these exist (not thin `npx playwright` wrappers — the bash tool runs those):
# every tool here SHAPES the JSON reporter into a structured pass/fail/flaky result
# a model can act on, hunts flaky tests across retries, installs browsers (the #1
# first-run failure), and adds LLM diagnose/write for the selector/timeout/race
# failures developers actually hit. Tests are opt-in via `tools enable playwright`.

# Resolve the playwright command as an ARRAY (local devDep > global > npx). npx
# ships with node, so the needs-gate is on node.
_pw_cmd() {
    if [[ -x "$YCA_PROJECT_DIR/node_modules/.bin/playwright" ]]; then
        _PW=("$YCA_PROJECT_DIR/node_modules/.bin/playwright")
    elif command -v playwright >/dev/null 2>&1; then
        _PW=(playwright)
    else
        _PW=(npx --no-install playwright)
    fi
}
_pw_need() { doctor_check_needs "node" || return 1; }

# A filter value must never start with '-' (option injection into playwright).
_pw_safe() { [[ -n "$1" && "$1" != -* ]]; }

# Shape the JSON reporter (stdin) -> {passed,failed,flaky,skipped,duration_ms,failures[]}.
# specs are walked across arbitrarily-nested suites; the failure error is the
# first result error (ANSI stripped) so it stays terminal-clean in the payload.
_pw_parse() {
    jq -c '
      def specs: [ .suites[]? | recurse(.suites[]?) | .specs[]? ];
      { passed:  (.stats.expected // 0),
        failed:  (.stats.unexpected // 0),
        flaky:   (.stats.flaky // 0),
        skipped: (.stats.skipped // 0),
        duration_ms: ((.stats.duration // 0) | floor),
        failures: [ specs[] | select(.ok | not)
          | { title, file, line,
              error: ( [ .tests[]?.results[]?.error.message // empty ]
                       | map(gsub("\\[[0-9;]*m"; "")) | first // "" ) } ] }
    ' 2>/dev/null
}

# Run playwright test with a json reporter; return the raw json file path in $_PWJSON
# and a human error in $_PWERR. rc0 = parseable json produced.
_pw_run_json() {
    local -a extra=("$@")
    _pw_cmd
    local jf ef; jf=$(mktemp) || return 1; ef=$(mktemp) || { rm -f "$jf"; return 1; }
    ( cd "$YCA_PROJECT_DIR" && "${_PW[@]}" test --reporter=json "${extra[@]}" >"$jf" 2>"$ef" )
    _PWJSON="$jf"; _PWERR=""
    if ! jq -e . "$jf" >/dev/null 2>&1; then
        if grep -qiE "Executable doesn't exist|playwright install|Please run the following" "$ef"; then
            _PWERR="browsers not installed — run the playwright_install tool (playwright install --with-deps)"
        elif grep -qiE "no tests found|npm error|command not found|Cannot find module" "$ef"; then
            _PWERR="$(tail -5 "$ef")"
        else
            _PWERR="playwright produced no parseable result:"$'\n'"$(tail -12 "$ef")"
        fi
        rm -f "$jf" "$ef"; _PWJSON=""; return 1
    fi
    rm -f "$ef"; return 0
}

# playwright_test — run the suite, return a STRUCTURED result (not the verbose
# reporter dump): counts + every failure's title/file/line/error.
tool_playwright_test() {
    _pw_need || return 1
    local grep_ proj file workers
    grep_=$(tool_arg grep); proj=$(tool_arg project); file=$(tool_arg file); workers=$(tool_arg workers)
    local -a a=()
    if [[ -n "$grep_" ]]; then _pw_safe "$grep_" || { printf 'invalid grep filter'; return 1; }; a+=(--grep "$grep_"); fi
    if [[ -n "$proj" ]];  then _pw_safe "$proj"  || { printf 'invalid project name'; return 1; }; a+=(--project "$proj"); fi
    if [[ -n "$workers" ]]; then [[ "$workers" =~ ^[0-9]+$ ]] || { printf 'workers must be a number'; return 1; }; a+=(--workers "$workers"); fi
    if [[ -n "$file" ]]; then path_check_allowed "$YCA_PROJECT_DIR/$file" 2>/dev/null || { printf 'path not allowed: %s' "$file"; return 1; }; a+=("$file"); fi
    if ! _pw_run_json "${a[@]}"; then printf '%s' "$_PWERR"; return 1; fi
    _pw_parse < "$_PWJSON"; rm -f "$_PWJSON"
}

# playwright_flaky — run with retries and surface tests that PASSED only after a
# retry (the classic race/timing bug). Reports the flaky set explicitly.
tool_playwright_flaky() {
    _pw_need || return 1
    local retries grep_; retries=$(tool_arg retries 2); grep_=$(tool_arg grep)
    [[ "$retries" =~ ^[0-9]+$ ]] || retries=2
    local -a a=(--retries "$retries")
    if [[ -n "$grep_" ]]; then _pw_safe "$grep_" || { printf 'invalid grep filter'; return 1; }; a+=(--grep "$grep_"); fi
    if ! _pw_run_json "${a[@]}"; then printf '%s' "$_PWERR"; return 1; fi
    jq -c '
      def specs: [ .suites[]? | recurse(.suites[]?) | .specs[]? ];
      { retries_used: '"$retries"',
        flaky_count: (.stats.flaky // 0),
        flaky_tests: [ specs[] | select(.ok)
          | select( [ .tests[]?.results[]?.status ] | any(. == "failed" or . == "timedOut") )
          | { title, file, line } ],
        still_failing: (.stats.unexpected // 0) }
    ' < "$_PWJSON" 2>/dev/null
    rm -f "$_PWJSON"
}

# playwright_list — enumerate tests WITHOUT running them (structured).
tool_playwright_list() {
    _pw_need || return 1
    _pw_cmd
    local jf; jf=$(mktemp) || return 1
    ( cd "$YCA_PROJECT_DIR" && "${_PW[@]}" test --list --reporter=json >"$jf" 2>/dev/null )
    if ! jq -e . "$jf" >/dev/null 2>&1; then rm -f "$jf"; printf 'could not list tests (no playwright config, or browsers/deps missing — try playwright_install)'; return 1; fi
    jq -c '
      def specs: [ .suites[]? | recurse(.suites[]?) | .specs[]? ];
      { count: (specs | length),
        tests: [ specs[] | { title, file, line } ] }
    ' < "$jf" 2>/dev/null
    rm -f "$jf"
}

# playwright_install — install browsers (+ OS deps on Linux). This is the fix for
# the ubiquitous "Executable doesn't exist … run playwright install" first-run error.
tool_playwright_install() {
    _pw_need || return 1
    local browser with_deps; browser=$(tool_arg browser); with_deps=$(tool_arg with_deps)
    local -a a=(install)
    [[ "$with_deps" == "true" ]] && a+=(--with-deps)
    if [[ -n "$browser" ]]; then
        case "$browser" in chromium|firefox|webkit|chrome|msedge) a+=("$browser") ;; *) printf 'browser must be chromium|firefox|webkit|chrome|msedge'; return 1 ;; esac
    fi
    _pw_cmd
    local out rc
    out=$( cd "$YCA_PROJECT_DIR" && "${_PW[@]}" "${a[@]}" 2>&1 ); rc=$?
    [[ $rc -eq 0 ]] && printf 'playwright browsers installed%s' "${browser:+ ($browser)}" || printf 'install failed (rc=%d):\n%s' "$rc" "$(printf '%s' "$out" | tail -15)"
}

# playwright_llm_diagnose — run the failing test(s), then LLM-analyze the failure:
# selector-not-found vs timeout vs race vs assertion, with the concrete fix.
tool_playwright_llm_diagnose() {
    _pw_need || return 1
    local grep_; grep_=$(tool_arg grep)
    local -a a=()
    if [[ -n "$grep_" ]]; then _pw_safe "$grep_" || { printf 'invalid grep filter'; return 1; }; a+=(--grep "$grep_"); fi
    if ! _pw_run_json "${a[@]}"; then printf '%s' "$_PWERR"; return 1; fi
    local summary; summary=$(_pw_parse < "$_PWJSON"); rm -f "$_PWJSON"
    local nfail; nfail=$(printf '%s' "$summary" | jq -r '.failed // 0' 2>/dev/null)
    [[ "${nfail:-0}" -eq 0 ]] && { printf 'no failing tests to diagnose (passed=%s)' "$(printf '%s' "$summary" | jq -r '.passed')"; return 0; }
    local system_prompt='You are a Playwright end-to-end testing expert. For each failing test below, classify the ROOT CAUSE — selector not found / wrong locator, auto-wait timeout, race condition or timing, navigation, assertion mismatch, or environment (browsers, base URL, auth) — then give the CONCRETE fix: prefer role-based locators (getByRole/getByLabel/getByText), web-first assertions (await expect(locator).toBeVisible()), and Playwright auto-waiting over arbitrary waitForTimeout. Cite the exact error line. Do not invent selectors you cannot see.'
    llm_analyze "$system_prompt" "$summary"
}

# playwright_llm_write — generate a Playwright test for a described scenario,
# encoding the best practices (role locators, web-first assertions, isolation).
tool_playwright_llm_write() {
    local desc url; desc=$(tool_arg description); url=$(tool_arg url)
    [[ -z "$desc" ]] && { printf 'description required (what should the test do?)'; return 1; }
    local system_prompt='You are a Playwright test author. Write ONE complete, runnable @playwright/test spec (TypeScript) for the scenario. Rules: use test() with a clear title; role-based locators (getByRole/getByLabel/getByText/getByTestId) — never brittle CSS/XPath if avoidable; web-first assertions await expect(locator).toBeVisible()/toHaveText() — never arbitrary page.waitForTimeout; each test independent (own context/state); use baseURL-relative paths. Output only the code in one ```ts block plus a one-line note on where to save it.'
    local content="Scenario: $desc"
    [[ -n "$url" ]] && content+=$'\n'"Base URL / entry: $url"
    llm_analyze "$system_prompt" "$content"
}

tool_register "playwright_test"          tool_playwright_test          '{"type":"object","properties":{"grep":{"type":"string","description":"only run tests whose title matches this text/regex"},"project":{"type":"string","description":"playwright project (browser) to run, e.g. chromium"},"file":{"type":"string","description":"a specific spec file, relative to the project root"},"workers":{"type":"integer","description":"number of parallel workers"}}}' safe all playwright
tool_register "playwright_flaky"         tool_playwright_flaky         '{"type":"object","properties":{"retries":{"type":"integer","description":"retries per test (default 2) — a test that passes only on retry is flaky"},"grep":{"type":"string","description":"only run tests whose title matches this text/regex"}}}' safe all playwright
tool_register "playwright_list"          tool_playwright_list          '{"type":"object","properties":{}}' safe all playwright
tool_register "playwright_install"       tool_playwright_install       '{"type":"object","properties":{"browser":{"type":"string","description":"chromium|firefox|webkit|chrome|msedge (default: all)"},"with_deps":{"type":"boolean","description":"also install OS-level dependencies (Linux) — recommended in CI/containers"}}}' writes all playwright
tool_register "playwright_llm_diagnose"  tool_playwright_llm_diagnose  '{"type":"object","properties":{"grep":{"type":"string","description":"only diagnose tests whose title matches this text/regex"}}}' safe all playwright mid
tool_register "playwright_llm_write"     tool_playwright_llm_write     '{"type":"object","properties":{"description":{"type":"string","description":"what the test should verify (the user flow/scenario)"},"url":{"type":"string","description":"base URL or entry path for the flow (optional)"}},"required":["description"]}' safe all playwright mid
