# langs/rust.sh — Rust tools and workflows
# Rich introspection: detect workspace vs single crate, edition, features,
# toolchain (stable/nightly), and report which cargo subcommands/tools are
# installed vs missing with install hints.

# ── Detection ──────────────────────────────────────────────────────────────
lang_rust_detect() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    [[ -f "$dir/Cargo.toml" ]]
}

lang_rust_profile() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    local cargo_toml="$dir/Cargo.toml"
    # Edition
    local edition=""
    [[ -f "$cargo_toml" ]] && edition=$(sed -n 's/.*edition\s*=\s*"\(.*\)"/\1/p' "$cargo_toml" | head -1)
    # Workspace
    local workspace="false"
    [[ -f "$cargo_toml" ]] && grep -q '\[workspace\]' "$cargo_toml" 2>/dev/null && workspace="true"
    # Features
    local features="false"
    [[ -f "$cargo_toml" ]] && grep -q '\[features\]' "$cargo_toml" 2>/dev/null && features="true"
    # Toolchain
    local toolchain=""
    toolchain=$(rustup show active-toolchain 2>/dev/null || rustc --version 2>/dev/null || echo 'missing')
    local is_nightly="false"
    if rustc --version 2>/dev/null | grep -q nightly; then is_nightly="true"; fi
    # Targets
    local targets=""
    targets=$(rustup target list --installed 2>/dev/null | tr '\n' ' ' | sed 's/ $//')
    jq -n --arg edition "$edition" --argjson workspace "$workspace" --argjson features "$features" \
          --arg toolchain "$toolchain" --argjson nightly "$is_nightly" --arg targets "$targets" \
        '{build:"cargo build", test:"cargo test", lint:"cargo clippy -- -D warnings", format:"cargo fmt", run:"cargo run", edition:$edition, workspace:$workspace, features:$features, toolchain:$toolchain, nightly:$nightly, targets:$targets}'
}

# ── Helpers ────────────────────────────────────────────────────────────────
_rust_run() { (cd "$YCA_PROJECT_DIR" && "$@" 2>&1); }
_rust_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_rust_cargo_sub() {
    local sub="$1"
    command -v "cargo-$sub" &>/dev/null || {
        _rust_missing "cargo-$sub" "cargo install cargo-$sub"
        return 1
    }
}

# ── Build ──────────────────────────────────────────────────────────────────
tool_rust_cargo_build() { _rust_run cargo build; }

# ── Test ───────────────────────────────────────────────────────────────────
tool_rust_cargo_test() { _rust_run cargo test; }
tool_rust_cargo_test_release() { _rust_run cargo test --release; }
tool_rust_cargo_test_target() {
    local target="$1"
    [[ -n "$target" ]] || { printf 'target filter required (use .target field)'; return 1; }
    _rust_run cargo test "$target"
}

# faster test runner with nightly fallback
tool_rust_cargo_nextest() {
    if command -v cargo-nextest &>/dev/null; then
        _rust_run cargo nextest run
    else
        printf 'cargo-nextest not installed, falling back to cargo test\n'
        _rust_run cargo test
    fi
}

# ── Lint / format ──────────────────────────────────────────────────────────
tool_rust_cargo_clippy() { _rust_run cargo clippy -- -D warnings; }
tool_rust_cargo_fmt()    { _rust_run cargo fmt; }
tool_rust_cargo_fmt_check() { _rust_run cargo fmt --check; }

# ── Documentation ──────────────────────────────────────────────────────────
tool_rust_cargo_doc()     { _rust_run cargo doc; }
tool_rust_cargo_doc_open(){ _rust_run cargo doc --open; }

# ── Security ───────────────────────────────────────────────────────────────
tool_rust_cargo_audit() {
    command -v cargo-audit &>/dev/null || { _rust_missing "cargo-audit" "cargo install cargo-audit"; return 1; }
    _rust_run cargo audit
}

# ── Dependency management ──────────────────────────────────────────────────
tool_rust_cargo_outdated() {
    command -v cargo-outdated &>/dev/null || { _rust_missing "cargo-outdated" "cargo install cargo-outdated"; return 1; }
    _rust_run cargo outdated
}

tool_rust_cargo_udeps() {
    command -v cargo-udeps &>/dev/null || { _rust_missing "cargo-udeps" "cargo install cargo-udeps"; return 1; }
    _rust_run cargo udeps
}

tool_rust_cargo_tree() { _rust_run cargo tree; }

# ── Add dependency ─────────────────────────────────────────────────────────
# cargo add fetches the crate index and mutates Cargo.toml/Cargo.lock. The
# package name is validated (no leading '-' → no option injection, no shell
# metacharacters) and passed as ARGV, never interpolated into a shell string.
tool_rust_dep_add() {
    local pkg safe
    pkg=$(tool_arg package "${1:-}")
    safe=$(shell_arg_safe "$pkg") || { printf 'invalid package name (rejected: leading dash or shell metacharacter): %s' "$pkg"; return 1; }
    command -v cargo &>/dev/null || { _rust_missing "cargo" "https://rustup.rs"; return 1; }
    confirm_action "add dependency $safe to rust project" "cargo add $safe" || { confirm_denied_msg; return 1; }
    _rust_run cargo add "$safe"
}

tool_rust_cargo_bloat() {
    command -v cargo-bloat &>/dev/null || { _rust_missing "cargo-bloat" "cargo install cargo-bloat"; return 1; }
    _rust_run cargo bloat
}

# ── Macro expansion ────────────────────────────────────────────────────────
tool_rust_cargo_expand() {
    command -v cargo-expand &>/dev/null || { _rust_missing "cargo-expand" "cargo install cargo-expand"; return 1; }
    _rust_run cargo expand
}

# ── UB detection (nightly only) ────────────────────────────────────────────
tool_rust_cargo_miri() {
    command -v cargo-miri &>/dev/null || { _rust_missing "cargo-miri" "rustup component add miri && cargo install cargo-miri"; return 1; }
    if ! rustc --version 2>/dev/null | grep -q nightly; then
        printf 'Miri requires a nightly toolchain\nswitch: rustup override set nightly'
        return 1
    fi
    _rust_run cargo miri test
}

# ── Profiling ──────────────────────────────────────────────────────────────
tool_rust_cargo_flamegraph() {
    command -v cargo-flamegraph &>/dev/null || { _rust_missing "cargo-flamegraph" "cargo install flamegraph"; return 1; }
    local binary="$1"
    if [[ -n "$binary" ]]; then
        _rust_run cargo flamegraph --bin "$binary"
    else
        _rust_run cargo flamegraph
    fi
}

tool_rust_cargo_criterion() {
    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/Cargo.toml" ]] && grep -q 'criterion' "$dir/Cargo.toml" 2>/dev/null; then
        _rust_run cargo bench
    else
        printf 'criterion not found in Cargo.toml (add [dev-dependencies] criterion)'
        return 1
    fi
}

# ── Sanitizers ─────────────────────────────────────────────────────────────
tool_rust_cargo_test_asan() {
    printf 'ASAN (Address Sanitizer) — detects memory errors (use-after-free, buffer overflows)\n'
    RUSTFLAGS="-Z sanitizer=address" _rust_run cargo test --target "$(rustc -vV | sed -n 's/.*host: //p')" 2>&1
}
tool_rust_cargo_test_tsan() {
    printf 'TSAN (Thread Sanitizer) — detects data races\n'
    RUSTFLAGS="-Z sanitizer=thread" _rust_run cargo test --target "$(rustc -vV | sed -n 's/.*host: //p')" 2>&1
}

# ── Features ───────────────────────────────────────────────────────────────
tool_rust_features() {
    local dir="${1:-$YCA_PROJECT_DIR}" cargo_toml="$dir/Cargo.toml"
    [[ -f "$cargo_toml" ]] || { printf 'no Cargo.toml found'; return 1; }
    # Print feature flags from [features] section
    sed -n '/^\[features\]/,/^\[/{/^\[features\]/d; /^\[/q; p;}' "$cargo_toml"
    # Also list default features
    local default_features=""
    default_features=$(sed -n '/^\[features\]/,/^\[/{s/default\s*=//p;}' "$cargo_toml")
    [[ -n "$default_features" ]] && printf '\ndefault: %s\n' "$default_features"
}

# ── Introspection: what's installed ────────────────────────────────────────
tool_rust_doctor() {
    local out=""
    out+="rustc: $(rustc --version 2>&1 || echo 'missing')\n"
    out+="cargo: $(cargo --version 2>&1 || echo 'missing')\n"
    out+="rustup: $(rustup --version 2>&1 | head -1 || echo 'missing')\n"
    local tc
    tc=$(rustup show active-toolchain 2>/dev/null || echo 'none')
    out+="active toolchain: $tc\n"

    local dir="$YCA_PROJECT_DIR"
    if [[ -f "$dir/Cargo.toml" ]]; then
        local ed
        ed=$(sed -n 's/.*edition\s*=\s*"\(.*\)"/\1/p' "$dir/Cargo.toml" | head -1)
        out+="edition: ${ed:-not set}\n"
        local ws="no"
        grep -q '\[workspace\]' "$dir/Cargo.toml" 2>/dev/null && ws="yes"
        out+="workspace: $ws\n"
    fi

    local tools="clippy rustfmt cargo-audit cargo-nextest cargo-miri cargo-flamegraph cargo-udeps cargo-outdated cargo-bloat cargo-expand"
    out+="\n-- cargo subcommands --\n"
    local t
    for t in $tools; do
        local s
        if command -v "cargo-$t" &>/dev/null; then s="ok"; else s="MISSING"; fi
        out+="  $t: $s\n"
    done

    # Check rustup components (clippy, rustfmt are components not cargo-*)
    local comps="clippy rustfmt"
    out+="\n-- rustup components --\n"
    local c
    for c in $comps; do
        local cs
        if rustup component list --installed 2>/dev/null | grep -q "$c"; then cs="ok"; else cs="MISSING"; fi
        out+="  $c: $cs\n"
    done

    # Check criterion as dev-dependency
    if [[ -f "$dir/Cargo.toml" ]] && grep -q 'criterion' "$dir/Cargo.toml" 2>/dev/null; then
        out+="\ncriterion: present in Cargo.toml [dev-dependencies]\n"
    else
        out+="\ncriterion: not in Cargo.toml\n"
    fi

    printf '%b' "$out"
}

# ── Project introspection ──────────────────────────────────────────────────
# targets — every bin/lib/example/test target and its entry point.
tool_rust_targets() {
    command -v cargo &>/dev/null || { _rust_missing "cargo" "https://rustup.rs"; return 1; }
    _rust_run cargo metadata --no-deps --format-version 1 2>/dev/null \
        | jq -r '.packages[] | .name as $p | .targets[] | "\(.kind[0])\t\($p)::\(.name)\t\(.src_path)"' 2>/dev/null \
        || printf 'cargo metadata failed (not a cargo project?)'
}

# msrv — declared minimum supported Rust version vs the installed toolchain.
tool_rust_msrv() {
    local ct="$YCA_PROJECT_DIR/Cargo.toml"
    [[ -f "$ct" ]] || { printf 'no Cargo.toml'; return 1; }
    local msrv edition
    msrv=$(sed -n 's/^rust-version[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ct" | head -1)
    edition=$(sed -n 's/^edition[[:space:]]*=[[:space:]]*"\(.*\)"/\1/p' "$ct" | head -1)
    printf 'rust-version (MSRV): %s\n' "${msrv:-(not declared)}"
    printf 'edition:             %s\n' "${edition:-(not declared)}"
    printf 'installed rustc:     %s\n' "$(rustc --version 2>&1)"
    printf 'active toolchain:    %s\n' "$(rustup show active-toolchain 2>/dev/null || printf 'rustup not installed')"
}

# publish_check — what `cargo publish` would ship (dry-run file list).
tool_rust_publish_check() {
    command -v cargo &>/dev/null || { _rust_missing "cargo" "https://rustup.rs"; return 1; }
    _rust_run cargo package --list --allow-dirty 2>&1 | head -60
}

# ── Register ───────────────────────────────────────────────────────────────
tool_register "rust_cargo_build"       tool_rust_cargo_build       '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_test"        tool_rust_cargo_test        '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_test_release" tool_rust_cargo_test_release '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_test_target" tool_rust_cargo_test_target '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}},"required":["target"]}' safe all rust
tool_register "rust_cargo_nextest"     tool_rust_cargo_nextest     '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_clippy"      tool_rust_cargo_clippy      '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_fmt"         tool_rust_cargo_fmt         '{"type":"object","properties":{}}' writes all rust
tool_register "rust_cargo_fmt_check"   tool_rust_cargo_fmt_check   '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_doc"         tool_rust_cargo_doc         '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_doc_open"    tool_rust_cargo_doc_open    '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_audit"       tool_rust_cargo_audit       '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_outdated"    tool_rust_cargo_outdated    '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_udeps"       tool_rust_cargo_udeps       '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_tree"        tool_rust_cargo_tree        '{"type":"object","properties":{}}' safe all rust
tool_register "rust_dep_add"           tool_rust_dep_add           '{"description":"Add a Cargo dependency (fetches code + mutates Cargo.toml/lock) — gated","type":"object","properties":{"package":{"type":"string","description":"crate name, optionally versioned (e.g. serde or serde@1.0)"}},"required":["package"]}' writes all rust
tool_register "rust_cargo_bloat"       tool_rust_cargo_bloat       '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_expand"      tool_rust_cargo_expand      '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_miri"        tool_rust_cargo_miri        '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_flamegraph"  tool_rust_cargo_flamegraph  '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all rust
tool_register "rust_cargo_criterion"   tool_rust_cargo_criterion   '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_test_asan"   tool_rust_cargo_test_asan   '{"type":"object","properties":{}}' safe all rust
tool_register "rust_cargo_test_tsan"   tool_rust_cargo_test_tsan   '{"type":"object","properties":{}}' safe all rust
tool_register "rust_features"          tool_rust_features          '{"type":"object","properties":{}}' safe all rust
tool_register "rust_doctor"            tool_rust_doctor            '{"type":"object","properties":{}}' safe all rust
tool_register "rust_targets"           tool_rust_targets           '{"type":"object","properties":{}}' safe all rust
tool_register "rust_msrv"              tool_rust_msrv              '{"type":"object","properties":{}}' safe all rust
tool_register "rust_publish_check"     tool_rust_publish_check     '{"type":"object","properties":{}}' safe all rust