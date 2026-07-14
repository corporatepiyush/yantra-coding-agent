# workflows/scaffold.sh — Scaffold workflows

wf_scaffold_new() {
    local kind="${INPUT_kind:-bash}" name="${INPUT_name:-newproj}"
    local target="$YCA_PROJECT_DIR/$name"
    [[ -e "$target" ]] && { emit_fail "$target exists"; return 1; }
    path_ensure_dir "$target"
    case "$kind" in
        bash)
            cat > "$target/$name.sh" <<EOF
#!/usr/bin/env bash
set -Euo pipefail
echo "hello from $name"
EOF
            chmod +x "$target/$name.sh" ;;
        python)
            cat > "$target/$name.py" <<EOF
def main():
    print("hello from $name")

if __name__ == "__main__":
    main()
EOF
            ;;
        node)
            cat > "$target/index.js" <<EOF
console.log("hello from $name");
EOF
            ;;
        go)
            cat > "$target/main.go" <<EOF
package main

import "fmt"

func main() {
    fmt.Println("hello from $name")
}
EOF
            ;;
        rust)
            cat > "$target/Cargo.toml" <<EOF
[package]
name = "$name"
version = "0.1.0"
edition = "2021"
EOF
            mkdir -p "$target/src"
            cat > "$target/src/main.rs" <<EOF
fn main() {
    println!("hello from $name");
}
EOF
            ;;
        *)
            cat > "$target/README.md" <<EOF
# $name

Created by Yantra Coding Agent.
EOF
            ;;
    esac
    emit_ok "scaffolded $target"
}

# scaffold.test-stub — generate a REAL arrange-act-assert skeleton that imports the
# target and calls it, with an initially-FAILING assertion (or a clearly-marked
# TODO). It used to emit `assert True` / `expect(true).toBe(true)` — a false-green
# test that passes without exercising anything. A red stub forces the dev to write
# real assertions before it can go green.
wf_scaffold_test_stub() {
    local file="${INPUT_file:-}" fn="${INPUT_fn:-}"
    val_required "$file" "INPUT_file" || return 1
    path_check_allowed "$YCA_PROJECT_DIR/$file" || return 1
    local src="$YCA_PROJECT_DIR/$file"
    local ext test_file fnname base fname
    ext=$(path_ext "$src")
    fnname="${fn:-main}"
    fname="${file##*/}"; base="${fname%.*}"

    case "$ext" in
        py)  test_file="${file%.py}_test.py" ;;
        js)  test_file="${file%.js}.test.js" ;;
        ts)  test_file="${file%.ts}.test.ts" ;;
        rs)  test_file="${file%.rs}_test.rs" ;;
        go)  test_file="${file%.go}_test.go" ;;
        *)   test_file="${file}.test" ;;
    esac
    path_check_allowed "$YCA_PROJECT_DIR/$test_file" || return 1

    confirm_action "Write a failing test stub for ${fnname} to ${test_file}" \
        "arrange-act-assert skeleton; the assertion FAILS until you fill it in" \
        || { emit_fail "cancelled"; return 0; }

    local target="$YCA_PROJECT_DIR/$test_file"
    case "$ext" in
        py)
            cat > "$target" <<EOF
import ${base}


def test_${fnname}():
    # Arrange
    # TODO: build the inputs ${fnname} needs.
    # Act
    result = ${base}.${fnname}()  # TODO: pass real arguments.
    # Assert
    # TODO: replace the placeholder with the real expected value.
    assert result == "TODO", "stub test for ${fnname} — write a real assertion"
EOF
            ;;
        js|ts)
            cat > "$target" <<EOF
// TODO: adjust the import to match your module system / path.
const { ${fnname} } = require("./${base}");

test("${fnname} returns the expected value", () => {
  // Arrange
  // TODO: set up the inputs ${fnname} needs.
  // Act
  const result = ${fnname}();  // TODO: pass real arguments.
  // Assert
  // TODO: replace the placeholder with the real expected value.
  expect(result).toBe("TODO");
});
EOF
            ;;
        rs)
            cat > "$target" <<EOF
// TODO: move this into a #[cfg(test)] mod in ${fname} (or under tests/) and
// import ${fnname} from your crate — a standalone _test.rs is not compiled by cargo.
#[test]
fn test_${fnname}() {
    // Arrange / Act
    // TODO: call ${fnname} with real inputs and bind its result.
    // Assert
    assert_eq!(1 + 1, 3, "stub test for ${fnname} — replace with a real assertion");
}
EOF
            ;;
        go)
            local pkg; pkg=$(awk '/^package /{print $2; exit}' "$src" 2>/dev/null); pkg="${pkg:-main}"
            cat > "$target" <<EOF
package ${pkg}

import "testing"

func Test$(str_capitalize "$fnname")(t *testing.T) {
	// Arrange
	// TODO: set up the inputs ${fnname} needs.
	// Act
	// TODO: call ${fnname} with real arguments (it is in this package).
	// Assert
	t.Fatal("stub test for ${fnname} — replace with real arrange-act-assert")
}
EOF
            ;;
        *)
            cat > "$target" <<EOF
# Test stub for ${fnname} in ${file}.
# TODO: no known test framework for this file type. Write a real test that
# exercises ${fnname} and asserts on its result. This is a failing placeholder —
# do NOT treat it as passing.
EOF
            ;;
    esac
    emit_ok "test stub: $test_file (fails until you fill in real assertions)"
}

wf_register "scaffold.new"       wf_scaffold_new       1 writes "" "Scaffold a new project"
wf_register "scaffold.test-stub" wf_scaffold_test_stub 1 writes "" "Generate a test stub"
