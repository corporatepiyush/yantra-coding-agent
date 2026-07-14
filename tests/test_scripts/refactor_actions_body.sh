#!/usr/bin/env bash
# tests/test_scripts/refactor_actions_body.sh — offline unit tests for the refactor
# + scaffold ACT half. Calls the workflow functions directly (YCA_UI_MODE=json,
# YCA_OUT_FD=1) and inspects the emitted result frame + the files on disk.
# Args: $1=YCA_DIR $2=TMP(project dir)
set -Euo pipefail
export YCA_DIR="$1" YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json; YCA_OUT_FD=1
YCA_SEQ=0; YCA_AUTO_CONFIRM=true; YCA_SAFETY_CONFIRM=false
fail(){ echo "FAIL: $1"; exit 1; }

# Extract the (last) result frame from captured emit output.
res_line(){ printf '%s\n' "$1" | grep '"type":"result"' | tail -1; }

# ── 1) extract-const on Go: insert AFTER package/import, substitute the value ──
cat > "$YCA_PROJECT_DIR/main.go" <<'EOF'
package main

import "fmt"

func main() {
    fmt.Println("hello")
}
EOF
out=$(INPUT_value='"hello"' INPUT_name=GREETING INPUT_file=main.go wf_refactor_extract) \
    || fail "go extract returned non-zero"
[[ "$(res_line "$out")" == *'"ok":true'* ]] || fail "go extract not ok:true (got: $out)"
head -1 "$YCA_PROJECT_DIR/main.go" | grep -q '^package main' \
    || fail "go: line 1 must stay 'package main' (decl landed above it)"
grep -q 'Println(GREETING)' "$YCA_PROJECT_DIR/main.go" \
    || fail 'go: value "hello" not substituted with GREETING'
gimp=$(awk '/^import "fmt"/{print NR; exit}' "$YCA_PROJECT_DIR/main.go")
gdec=$(awk '/^const GREETING/{print NR; exit}' "$YCA_PROJECT_DIR/main.go")
[[ -n "$gimp" && -n "$gdec" && "$gdec" -gt "$gimp" ]] \
    || fail "go: const must be AFTER the import (import=$gimp const=$gdec)"

# ── 2) extract-const on Python: insert AFTER shebang+import, substitute value ──
cat > "$YCA_PROJECT_DIR/app.py" <<'EOF'
#!/usr/bin/env python3
import os

def main():
    print("hello")
EOF
out=$(INPUT_value='"hello"' INPUT_name=GREETING INPUT_file=app.py wf_refactor_extract) \
    || fail "py extract returned non-zero"
[[ "$(res_line "$out")" == *'"ok":true'* ]] || fail "py extract not ok:true (got: $out)"
head -1 "$YCA_PROJECT_DIR/app.py" | grep -q '^#!/usr/bin/env python3' \
    || fail "py: shebang must stay on line 1"
grep -q 'print(GREETING)' "$YCA_PROJECT_DIR/app.py" \
    || fail "py: value not substituted with GREETING"
pimp=$(awk '/^import os/{print NR; exit}' "$YCA_PROJECT_DIR/app.py")
pdec=$(awk '/^GREETING =/{print NR; exit}' "$YCA_PROJECT_DIR/app.py")
[[ -n "$pimp" && -n "$pdec" && "$pdec" -gt "$pimp" && "$pdec" -gt 1 ]] \
    || fail "py: const must be AFTER the import and not line 1 (import=$pimp const=$pdec)"

# ── 3) extract-const with an ABSENT value -> emit_fail, no orphan constant ──
printf 'x = 1\n' > "$YCA_PROJECT_DIR/absent.py"
out=$(INPUT_value='"not_here"' INPUT_name=FOO INPUT_file=absent.py wf_refactor_extract) || true
[[ "$(res_line "$out")" == *'"ok":false'* ]] \
    || fail "extract with absent value must be ok:false (got: $out)"
if grep -q 'FOO' "$YCA_PROJECT_DIR/absent.py"; then fail "extract absent-value wrote an orphan const"; fi

# ── 4) rename with ast-grep ABSENT -> emit_fail + install hint (never emit_ok) ──
mkdir -p "$YCA_PROJECT_DIR/nobin"
ln -sf "$(command -v jq)" "$YCA_PROJECT_DIR/nobin/jq"
printf 'package main\nfunc main(){ foo := 1; _ = foo }\n' > "$YCA_PROJECT_DIR/r.go"
out=$(PATH="$YCA_PROJECT_DIR/nobin" INPUT_old=foo INPUT_new=bar INPUT_path=r.go wf_refactor_rename) || true
rl=$(res_line "$out")
[[ "$rl" == *'"ok":false'* ]] || fail "sg-absent rename must be ok:false (got: $out)"
printf '%s\n' "$rl" | grep -qi 'ast-grep' || fail "sg-absent rename lacks an install hint (got: $rl)"

# ── 5) rename with NO match (sg present) -> emit_fail honestly, never emit_ok ──
if command -v sg &>/dev/null; then
    printf 'package main\nfunc main(){ foo := 1; _ = foo }\n' > "$YCA_PROJECT_DIR/nm.go"
    out=$(INPUT_old=zzz_absent_symbol INPUT_new=whatever INPUT_path=nm.go wf_refactor_rename) || true
    rl=$(res_line "$out")
    [[ "$rl" == *'"ok":false'* ]] || fail "no-match rename must be ok:false (got: $out)"
    if [[ "$rl" == *'"ok":true'* ]]; then fail "no-match rename emitted a false success"; fi
fi

# ── 6) rename APPLY (sg present): real write with -U + honest emit_ok ──
if command -v sg &>/dev/null; then
    printf 'package main\n\nfunc main() {\n\tfoo := 1\n\t_ = foo\n}\n' > "$YCA_PROJECT_DIR/ap.go"
    out=$(INPUT_old=foo INPUT_new=bar INPUT_path=ap.go wf_refactor_rename) || true
    [[ "$(res_line "$out")" == *'"ok":true'* ]] || fail "rename apply must be ok:true (got: $out)"
    grep -q 'bar :=' "$YCA_PROJECT_DIR/ap.go" || fail "rename apply: file not updated (no 'bar :=')"
    if grep -q 'foo :=' "$YCA_PROJECT_DIR/ap.go"; then fail "rename apply: old 'foo :=' still present"; fi
fi

# ── 7) signature: honest plan-only, never a lying emit_ok for a no-op ──
out=$(INPUT_fn=doThing wf_refactor_signature) || true
rl=$(res_line "$out")
[[ "$rl" == *'"ok":false'* ]] || fail "signature must NOT emit_ok for a no-op (got: $out)"
if [[ "$rl" == *'"ok":true'* ]]; then fail "signature emitted a false success"; fi

# ── 8) scaffold.test-stub: red arrange-act-assert skeleton, NEVER a tautology ──
# Python: imports the module, calls the fn, no `assert True`.
printf 'def greet():\n    return "hi"\n' > "$YCA_PROJECT_DIR/mod.py"
out=$(INPUT_file=mod.py INPUT_fn=greet wf_scaffold_test_stub) || fail "py stub returned non-zero"
tf="$YCA_PROJECT_DIR/mod_test.py"
[[ -f "$tf" ]] || fail "py stub not written"
if grep -qE 'assert[[:space:]]+True\b' "$tf"; then fail "py stub contains tautological 'assert True'"; fi
grep -q 'import mod' "$tf" || fail "py stub does not import the target module"
grep -q 'mod.greet(' "$tf" || fail "py stub does not call the target function"

# JS: no expect(true).toBe(true).
printf 'function greet(){ return "hi"; }\nmodule.exports = { greet };\n' > "$YCA_PROJECT_DIR/mod.js"
out=$(INPUT_file=mod.js INPUT_fn=greet wf_scaffold_test_stub) || fail "js stub returned non-zero"
tf="$YCA_PROJECT_DIR/mod.test.js"
[[ -f "$tf" ]] || fail "js stub not written"
if grep -qi 'expect(true)' "$tf"; then fail "js stub contains an expect(true) tautology"; fi
grep -q 'require(' "$tf" || fail "js stub does not import the target"

# Go: picks up the source package, is a failing (red) stub, no tautology.
printf 'package widget\n\nfunc Greet() string { return "hi" }\n' > "$YCA_PROJECT_DIR/widget.go"
out=$(INPUT_file=widget.go INPUT_fn=greet wf_scaffold_test_stub) || fail "go stub returned non-zero"
tf="$YCA_PROJECT_DIR/widget_test.go"
[[ -f "$tf" ]] || fail "go stub not written"
if grep -qE 'assert!\(true\)|assert[[:space:]]+True|toBe\(true\)'  "$tf"; then fail "go stub contains a tautology"; fi
grep -q '^package widget' "$tf" || fail "go stub did not pick up the source package name"
grep -q 't.Fatal' "$tf" || fail "go stub is not a failing (red) stub"

# Rust: no assert!(true).
printf 'pub fn greet() -> &str { "hi" }\n' > "$YCA_PROJECT_DIR/lib.rs"
out=$(INPUT_file=lib.rs INPUT_fn=greet wf_scaffold_test_stub) || fail "rs stub returned non-zero"
tf="$YCA_PROJECT_DIR/lib_test.rs"
[[ -f "$tf" ]] || fail "rs stub not written"
if grep -qE 'assert!\(true\)' "$tf"; then fail "rs stub contains assert!(true) tautology"; fi

echo "refactor_actions_body OK"
