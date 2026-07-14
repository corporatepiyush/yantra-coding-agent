# workflows/lint.sh — Lint workflows

wf_lint_fix() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *python*) cmd="ruff check --fix . 2>/dev/null || black ." ;;
        # Rust toolchain first (biome/oxlint), then the eslint/prettier classics.
        # node_modules/.bin only — `npx <missing-pkg>` would download and run
        # unpinned registry code.
        *node*)   cmd="./node_modules/.bin/biome check --write . 2>/dev/null || ./node_modules/.bin/oxlint --fix . 2>/dev/null || npx --no-install eslint --fix . 2>/dev/null || npx --no-install prettier --write ." ;;
        *rust*)   cmd="cargo clippy --fix --allow-dirty" ;;
        *go*)     cmd="go vet ./... 2>/dev/null; gofmt -w ." ;;
        *java*)   cmd="mvn checkstyle:check 2>/dev/null" ;;
        *)        cmd=$(toolchain_profile_json | jq -r '.lint // empty') ;;
    esac
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no linter detected"; return 1; }
    emit_progress "lint" ""
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit_ok "lint fix done"
}

wf_lint_check() {
    local cmd
    cmd=$(toolchain_profile_json | jq -r '.lint // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no linter detected"; return 1; }
    emit_progress "lint" ""
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" '{ok:($rc==0),summary:"lint check done"}')"
}

wf_register "lint.fix"    wf_lint_fix    1 writes "" "Auto-fix lint issues"
wf_register "lint.check"  wf_lint_check  1 safe "" "Check lint (no fixes)"
