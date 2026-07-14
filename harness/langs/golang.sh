# langs/golang.sh — Go tools and workflows
# Rich introspection: detect Go version, module path from go.mod, presence of
# go.work (workspace), GOPATH/module mode, and which lint/analysis/formatter
# tools are installed with install hints for missing ones.

# ── Detection ──────────────────────────────────────────────────────────────
lang_golang_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/go.mod" ]]
}

lang_golang_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local go_ver="" module="" workspace="false" lint_tool="golangci-lint"
    go_ver=$(go version 2>&1)
    module=$(head -1 "$dir/go.mod" 2>/dev/null | awk '{print $2}')
    [[ -f "$dir/go.work" ]] && workspace="true"
    command -v staticcheck &>/dev/null && lint_tool="staticcheck"
    command -v golangci-lint &>/dev/null && lint_tool="golangci-lint"
    jq -n --arg go_ver "$go_ver" --arg module "$module" \
           --argjson workspace "$workspace" --arg lint "$lint_tool" \
        '{build:"go build ./...", test:"go test ./...", lint:("go vet ./...; " + $lint + " run ./..."), format:"gofmt -w .", run:"go run .", go_version:$go_ver, module:$module, workspace:$workspace, lint_tool:$lint}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_go_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_go_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }

# ── Build ──────────────────────────────────────────────────────────────────
tool_go_build() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go build ./...
}

# ── Test ───────────────────────────────────────────────────────────────────
tool_go_test() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go test ./...
}

tool_go_test_race() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go test -race ./...
}

tool_go_test_cov() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go test -coverprofile=coverage.out ./... && \
    _go_run go tool cover -html=coverage.out -o coverage.html && \
    printf 'coverage report: coverage.html'
}

tool_go_test_verbose() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go test -v ./...
}

tool_go_test_bench() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local pattern="${1:-.}"
    _go_run go test -bench="$pattern" -benchmem ./...
}

tool_go_test_fuzz() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local target="$2"
    [[ -n "$target" ]] || { printf 'fuzz target required (use .name field, e.g. FuzzMyFunc)'; return 1; }
    _go_run go test -fuzz="$target" -fuzztime=30s ./...
}

# ── Static analysis ────────────────────────────────────────────────────────
tool_go_vet() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go vet ./...
}

tool_go_vet_shadow() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local shadow_path
    shadow_path="$(go env GOPATH)/bin/shadow"
    if command -v shadow &>/dev/null; then
        _go_run go vet -vettool="$(command -v shadow)" ./...
    elif [[ -x "$shadow_path" ]]; then
        _go_run go vet -vettool="$shadow_path" ./...
    else
        printf 'shadow variable-shadowing analyzer not installed.\n\nIt detects variables that shadow other variables in enclosing scopes.\n\ninstall: go install golang.org/x/tools/go/analysis/passes/shadow/cmd/shadow@latest\n  then: go vet -vettool=$(go env GOPATH)/bin/shadow ./...\n\nAlternate approach (GCCGO): gccgo -fgo-opt='-fcheck-shadow' but this only covers a subset.'
        return 1
    fi
}

tool_go_golangci_lint() {
    command -v golangci-lint &>/dev/null || { _go_missing "golangci-lint" "curl -sSfL https://raw.githubusercontent.com/golangci/golangci-lint/master/install.sh | sh -s -- -b $(go env GOPATH)/bin"; return 1; }
    _go_run golangci-lint run ./...
}

tool_go_staticcheck() {
    command -v staticcheck &>/dev/null || { _go_missing "staticcheck" "go install honnef.co/go/tools/cmd/staticcheck@latest"; return 1; }
    _go_run staticcheck ./...
}

# ── Format ─────────────────────────────────────────────────────────────────
tool_go_fmt() {
    command -v gofmt &>/dev/null || { _go_missing "gofmt" "part of Go distribution (go.dev/dl/)"; return 1; }
    _go_run gofmt -w .
}

tool_go_fmt_check() {
    command -v gofmt &>/dev/null || { _go_missing "gofmt" "part of Go distribution (go.dev/dl/)"; return 1; }
    local out
    out=$(_go_run gofmt -l . 2>&1)
    if [[ -n "$out" ]]; then printf 'unformatted files:\n%s' "$out"; return 1; fi
    printf 'all files are gofmt-compliant'
}

tool_go_goimports() {
    command -v goimports &>/dev/null || { _go_missing "goimports" "go install golang.org/x/tools/cmd/goimports@latest"; return 1; }
    _go_run goimports -w .
}

tool_go_gofumpt() {
    command -v gofumpt &>/dev/null || { _go_missing "gofumpt" "go install mvdan.cc/gofumpt@latest"; return 1; }
    _go_run gofumpt -w .
}

# ── Module ─────────────────────────────────────────────────────────────────
tool_go_mod_tidy() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go mod tidy
}

# dep_add — `go get <pkg>` fetches the module and mutates go.mod/go.sum. The
# module path is validated (no leading '-', no shell metacharacters) and passed
# as ARGV, never interpolated. Paths like github.com/foo/bar@v1.2.3 are allowed.
tool_go_dep_add() {
    local pkg safe
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    confirm_action "add dependency $safe to go module" "go get $safe" || { confirm_denied_msg; return 1; }
    _go_run go get "$safe"
}

tool_go_mod_why() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local pkg="$2"
    [[ -n "$pkg" ]] || { printf 'package required (use .name field)'; return 1; }
    _go_run go mod why "$pkg"
}

tool_go_mod_graph() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go mod graph
}

tool_go_list() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go list ./...
}

# ── Security ───────────────────────────────────────────────────────────────
tool_go_govulncheck() {
    command -v govulncheck &>/dev/null || { _go_missing "govulncheck" "go install golang.org/x/vuln/cmd/govulncheck@latest"; return 1; }
    _go_run govulncheck ./...
}

# ── LSP ────────────────────────────────────────────────────────────────────
tool_go_gopls_check() {
    command -v gopls &>/dev/null || { _go_missing "gopls" "go install golang.org/x/tools/gopls@latest"; return 1; }
    _go_run gopls check ./...
}

# ── Profiling ──────────────────────────────────────────────────────────────
tool_go_pprof_cpu() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local out="${YCA_PROJECT_DIR}/cpu.prof"
    _go_run go test -bench=. -cpuprofile "$out" ./... && \
    printf 'CPU profile: %s\nview: go tool pprof -http=:8080 %s' "$out" "$out"
}

tool_go_pprof_mem() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local out="${YCA_PROJECT_DIR}/mem.prof"
    _go_run go test -bench=. -memprofile "$out" ./... && \
    printf 'mem profile: %s\nview: go tool pprof -http=:8080 %s' "$out" "$out"
}

tool_go_tool_trace() {
    printf 'Go tool trace requires runtime/trace trace data.\n\nUsage:\n  1. Add import "runtime/trace" to your program\n  2. In main():\n       f, _ := os.Create("trace.out")\n       trace.Start(f)\n       defer trace.Stop()\n  3. Run your program to produce trace.out\n  4. View: go tool trace trace.out\n'
}

# ── Introspection ──────────────────────────────────────────────────────────
tool_go_version() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go version
}

tool_go_env() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go env
}

tool_go_doctor() {
    local dir="$YCA_PROJECT_DIR" out=""
    out+="Go: $(go version 2>&1 || echo 'missing')\n"
    out+="GOPATH: $(go env GOPATH 2>/dev/null || echo 'unknown')\n"
    out+="GOROOT: $(go env GOROOT 2>/dev/null || echo 'unknown')\n"
    out+="Module mode: "
    if [[ -f "$dir/go.work" ]]; then out+="workspace (go.work)"
    elif [[ -f "$dir/go.mod" ]]; then out+="module (go.mod)"
    else out+="GOPATH mode (no go.mod)"; fi
    out+="\nModule: $(head -1 "$dir/go.mod" 2>/dev/null | awk '{print $2}' || echo 'none')\n"
    out+="Packages: $(_go_run go list ./... 2>/dev/null | wc -l | tr -d ' ' || echo '0')\n"
    out+="\n"
    local t
    for t in go golangci-lint staticcheck govulncheck gopls dlv gofumpt goimports shadow; do
        local v
        if command -v "$t" &>/dev/null; then
            v="installed ($($t version 2>&1 | head -c 80))"
            out+="  $t: $v\n"
        else
            out+="  $t: MISSING\n"
        fi
    done
    printf '%b' "$out"
}

# ── Project introspection ──────────────────────────────────────────────────
# outdated — modules with a newer version available.
tool_go_outdated() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local out
    out=$(_go_run go list -u -m all 2>&1 | awk '/\[/')
    [[ -n "$out" ]] && printf '%s\n' "$out" || printf 'all modules up to date'
}

# mod_verify — checksums of downloaded modules match go.sum.
tool_go_mod_verify() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    _go_run go mod verify
}

# mains — entry points: every package main in the module.
tool_go_entrypoints() {
    command -v go &>/dev/null || { _go_missing "go" "https://go.dev/dl/"; return 1; }
    local out
    out=$(_go_run go list -f '{{if eq .Name "main"}}{{.ImportPath}} -> {{.Dir}}{{end}}' ./... 2>&1 | awk 'NF')
    [[ -n "$out" ]] && printf '%s\n' "$out" || printf 'no package main found'
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "go_build"        tool_go_build        '{"type":"object","properties":{}}' safe all golang
tool_register "go_test"         tool_go_test         '{"type":"object","properties":{}}' safe all golang
tool_register "go_test_race"    tool_go_test_race    '{"type":"object","properties":{}}' safe all golang
tool_register "go_test_cov"     tool_go_test_cov     '{"type":"object","properties":{}}' safe all golang
tool_register "go_test_verbose" tool_go_test_verbose '{"type":"object","properties":{}}' safe all golang
tool_register "go_test_bench"   tool_go_test_bench   '{"type":"object","properties":{"pattern":{"type":"string","description":"the search pattern (text or regex)"}}}' safe all golang
tool_register "go_test_fuzz"    tool_go_test_fuzz    '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all golang
tool_register "go_vet"          tool_go_vet          '{"type":"object","properties":{}}' safe all golang
tool_register "go_vet_shadow"   tool_go_vet_shadow   '{"type":"object","properties":{}}' safe all golang
tool_register "go_golangci_lint" tool_go_golangci_lint '{"type":"object","properties":{}}' safe all golang
tool_register "go_staticcheck"  tool_go_staticcheck  '{"type":"object","properties":{}}' safe all golang
tool_register "go_fmt"          tool_go_fmt          '{"type":"object","properties":{}}' writes all golang
tool_register "go_fmt_check"    tool_go_fmt_check    '{"type":"object","properties":{}}' safe all golang
tool_register "go_goimports"    tool_go_goimports    '{"type":"object","properties":{}}' writes all golang
tool_register "go_gofumpt"      tool_go_gofumpt      '{"type":"object","properties":{}}' writes all golang
tool_register "go_mod_tidy"     tool_go_mod_tidy     '{"type":"object","properties":{}}' writes all golang
tool_register "go_dep_add"      tool_go_dep_add      '{"description":"Add a Go module dependency via go get (fetches code + mutates go.mod/go.sum) — gated","type":"object","properties":{"package":{"type":"string","description":"module path, optionally versioned (e.g. github.com/pkg/errors@v0.9.1)"}},"required":["package"]}' writes all golang
tool_register "go_mod_why"      tool_go_mod_why      '{"type":"object","properties":{"name":{"type":"string","description":"the resource name"}},"required":["name"]}' safe all golang
tool_register "go_mod_graph"    tool_go_mod_graph    '{"type":"object","properties":{}}' safe all golang
tool_register "go_list"         tool_go_list         '{"type":"object","properties":{}}' safe all golang
tool_register "go_govulncheck"  tool_go_govulncheck  '{"type":"object","properties":{}}' safe all golang
tool_register "go_gopls_check"  tool_go_gopls_check  '{"type":"object","properties":{}}' safe all golang
tool_register "go_pprof_cpu"    tool_go_pprof_cpu    '{"type":"object","properties":{}}' writes all golang
tool_register "go_pprof_mem"    tool_go_pprof_mem    '{"type":"object","properties":{}}' writes all golang
tool_register "go_tool_trace"   tool_go_tool_trace   '{"type":"object","properties":{}}' safe all golang
tool_register "go_version"      tool_go_version      '{"type":"object","properties":{}}' safe all golang
tool_register "go_env"          tool_go_env          '{"type":"object","properties":{}}' safe all golang
tool_register "go_doctor"       tool_go_doctor       '{"type":"object","properties":{}}' safe all golang
tool_register "go_outdated"     tool_go_outdated     '{"type":"object","properties":{}}' safe all golang
tool_register "go_mod_verify"   tool_go_mod_verify   '{"type":"object","properties":{}}' safe all golang
tool_register "go_entrypoints"        tool_go_entrypoints        '{"type":"object","properties":{}}' safe all golang