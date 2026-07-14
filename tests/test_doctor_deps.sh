#!/usr/bin/env bash
# Test: dependency doctor — brew-formula resolution, install offers, version
# checks. Includes a regression guard for the same-line `local` bug that made
# every dependency resolve to the same (wrong) brew formula.
set -uo pipefail
HARNESS="$1"; TMP="$2"
cd "$TMP"
rm -f .harness.db
git init -q

# ── unit-level checks by sourcing the harness ───────────────────────────────
cat > "$TMP/body.sh" <<'SCRIPT'
set -Euo pipefail
export YCA_DIR="$1"
source "$YCA_DIR/harness/main.sh"
YCA_UI_MODE="json"
doctor_init_manifest
fail() { echo "FAIL: $1"; exit 1; }

# brew formula is mined per-tool and is DISTINCT per tool.
[[ "$(doctor_brew_formula gh)"        == "gh"        ]] || fail "gh formula wrong: $(doctor_brew_formula gh)"
[[ "$(doctor_brew_formula gitleaks)"  == "gitleaks"  ]] || fail "gitleaks formula wrong"
[[ "$(doctor_brew_formula shellcheck)" == "shellcheck" ]] || fail "shellcheck formula wrong"
# tools that install via npm/cargo (no brew hint) → empty formula
[[ -z "$(doctor_brew_formula tree-sitter)" ]] || fail "tree-sitter should have no brew formula"
[[ -z "$(doctor_brew_formula sd)" ]]           || fail "sd (cargo) should have no brew formula"

# REGRESSION: a global `name` in scope must NOT leak into doctor_brew_formula.
# (Before the fix, `local name=$1 hint=${arr[$name]}` on one line read the global
# `name`, so every lookup returned the same wrong formula.)
name=sbt
[[ "$(doctor_brew_formula gh)" == "gh" ]] || fail "global name leaked into doctor_brew_formula (got $(doctor_brew_formula gh))"
name=gitleaks
[[ "$(doctor_brew_formula helm)" == "helm" ]] || fail "global name leaked (helm -> $(doctor_brew_formula helm))"
unset name

# doctor_check_one must key off its argument, not an unrelated global loop var.
YCA_DEP_MANIFEST[faketool]="x|feature|brew install faketool"
name=gh                       # hostile global
doctor_check_one faketool || true
[[ -n "${YCA_DEP_STATUS[faketool]:-}" ]] || fail "doctor_check_one didn't record faketool status"
[[ "${YCA_DEP_STATUS[faketool]%%|*}" == "MISSING" ]] || fail "faketool should be MISSING"
unset name

# doctor_check_needs (json mode) → one actionable deps_missing error carrying the
# exact brew install command + installable flag.
YCA_DEP_STATUS[faketool]="MISSING|x|brew install faketool"
out=$(doctor_check_needs "faketool" 2>/dev/null)
echo "$out" | jq -e 'select(.type=="error" and .code=="deps_missing" and .installable==true and (.install|test("brew install faketool")))' >/dev/null \
    || fail "doctor_check_needs didn't emit actionable deps_missing (got: $out)"

# a satisfied need passes silently (return 0, no error frame)
YCA_DEP_STATUS[faketool]="OK|x|present"
out=$(doctor_check_needs "faketool" 2>/dev/null); rc=$?
[[ "$rc" -eq 0 && -z "$out" ]] || fail "satisfied dep should pass quietly (rc=$rc out=$out)"

# doctor_tool_version parses a semver for a tool we know exists (bash).
v=$(doctor_tool_version bash)
[[ "$v" =~ ^[0-9]+\.[0-9] ]] || fail "doctor_tool_version bash didn't parse a version (got '$v')"

echo "doctor body OK"
SCRIPT
BODY=$(bash "$TMP/body.sh" "$(dirname "$HARNESS")" 2>&1) || { echo "$BODY"; exit 1; }
echo "$BODY" | grep -q "doctor body OK" || { echo "$BODY"; exit 1; }

# ── end-to-end via the binary: install plan has DISTINCT formulas ────────────
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"

OUT=$(mcp_wf "$HARNESS" doctor.install '{}') || true
INSTALL=$(printf '%s' "$OUT" | jq -r '.data.install // empty' | head -1)
if [[ -n "$INSTALL" ]]; then
    # No formula should appear more than once (the old bug produced "sbt sbt sbt…").
    dupes=$(printf '%s\n' $INSTALL | grep -v '^brew$' | grep -v '^install$' | sort | uniq -d)
    [[ -z "$dupes" ]] || { echo "doctor.install produced duplicate formulas: $dupes"; echo "$INSTALL"; exit 1; }
fi

# doctor.versions returns a well-formed summary
OUT=$(mcp_wf "$HARNESS" doctor.versions '{}') || true
printf '%s' "$OUT" | jq -e '(.data | has("ok") and has("outdated") and has("missing"))' >/dev/null \
    || { echo "doctor.versions summary malformed"; echo "$OUT"; exit 1; }

echo "doctor_deps OK"
exit 0
