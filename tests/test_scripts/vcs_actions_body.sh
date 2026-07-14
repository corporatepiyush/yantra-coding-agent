#!/usr/bin/env bash
# tests/test_scripts/vcs_actions_body.sh — the VCS "ship a change" act-half:
# git.ship/release/pr/quicksave/sync + conflict-assist + pr.merge/review-triage.
# Proves the act-half is GATED, VALIDATES its inputs, and — the whole point of the
# rewrite — NEVER reports a failed push as success. All offline. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json; YCA_OUT_FD=1; YCA_DB_PATH=""
fail(){ echo "FAIL: $1"; exit 1; }

# main() (not run here) is what probes deps + seeds the manifest; seed git as
# present so doctor_check_needs "git" doesn't lazily probe an unpopulated manifest.
YCA_DEP_STATUS[git]=OK

CAP="$2/cap.ndjson"; : > "$CAP"

# r ID INPUTS AUTO_CONFIRM [PROJECT_DIR] -> prints the emitted NDJSON frames.
# Emit targets a preserved fd (fd 9), exactly like the real harness — run_workflow
# redirects the workflow's own stdout to stderr, so a naive YCA_OUT_FD=1 would lose
# the result frame. `set +e` runs the workflow as production does (no errexit).
r(){
    ( set +e; exec 9>"$CAP"
      export YCA_OUT_FD=9 YCA_INPUT_JSON="$2" YCA_AUTO_CONFIRM="$3"
      [[ -n "${4:-}" ]] && export YCA_PROJECT_DIR="$4"
      run_workflow "$1"
    ) >/dev/null 2>&1 || true
    printf '%s' "$(<"$CAP")"
}
sok(){  printf '%s\n' "$1" | jq -rc 'select(.type=="result")|.ok'       2>/dev/null | tail -1; }
ssum(){ printf '%s\n' "$1" | jq -rc 'select(.type=="result")|.summary'  2>/dev/null | tail -1; }
sdata(){ printf '%s\n' "$1" | jq -rc "select(.type==\"result\")|.data.$2 // empty" 2>/dev/null | tail -1; }
newrepo(){ local d="$1"; mkdir -p "$d"; ( cd "$d"
    git init -q; git config user.email t@t; git config user.name t
    printf '.harness.db*\ncap.ndjson\n' > .gitignore
    echo a > a.txt; git add -A; git commit -qm init >/dev/null 2>&1; git branch -M main ); }

# A clean repo at the project root for the gate/validation/quicksave checks.
newrepo "$2"

# ── 1) registration honesty: every outward workflow is `writes` (so the machine
#       consent gate covers it); the read-only triage is `safe`. ──
for spec in "git.ship writes" "git.release writes" "git.pr writes" \
            "git.conflict-assist writes" "git.sync writes" "git.quicksave writes" \
            "pr.merge writes" "pr.review-triage safe"; do
    id="${spec%% *}"; want="${spec##* }"
    info="${YCA_WF_REGISTRY[$id]:-}"; [[ -n "$info" ]] || fail "$id is not registered"
    IFS='|' read -r _fn _tier dg _needs _desc _cx <<< "$info"
    [[ "$dg" == "$want" ]] || fail "$id danger token '$dg' != expected '$want'"
    if [[ "$want" == writes ]]; then
        danger_needs_confirm "$dg" || fail "$id ('$dg') bypasses the consent gate"
    else
        danger_needs_confirm "$dg" && fail "$id ('$dg') should NOT be consent-gated"
    fi
done

# ── 2) git.ship is destructive → machine mode auto-denies it without auto_confirm ──
o=$(r "git.ship" '{"version":"v1.0.0"}' false)
[[ "$(sok "$o")" == false ]] || fail "git.ship was not consent-gated in machine mode: $o"
ssum "$o" | grep -qi 'consent\|confirm' || fail "git.ship gate message unexpected: $(ssum "$o")"

# ── 3) git.ship validates the version/tag (auto_confirm=true gets past the gate,
#       so the workflow's own validation is what must reject these) ──
o=$(r "git.ship" '{"version":"-rf"}' true)
[[ "$(sok "$o")" == false ]] || fail "git.ship accepted an option-injection version '-rf': $o"
ssum "$o" | grep -qi 'invalid' || fail "git.ship should reject '-rf' as invalid: $(ssum "$o")"
o=$(r "git.ship" '{"version":"v1;rm -rf"}' true)
[[ "$(sok "$o")" == false ]] || fail "git.ship accepted a metacharacter version: $o"
ssum "$o" | grep -qi 'invalid' || fail "git.ship should reject a metachar version: $(ssum "$o")"
o=$(r "git.ship" '{}' true)
[[ "$(sok "$o")" == false ]] || fail "git.ship accepted an empty version: $o"
ssum "$o" | grep -qi 'version required' || fail "git.ship empty-version message unexpected: $(ssum "$o")"

# ── 4) THE honesty test: a push that FAILS must NOT be reported as success. Point
#       at a bogus remote; the pipeline must run through validate+preflight+tag and
#       then fail HONESTLY at the push (ok:false), rolling the local tag back. ──
BOGUS="$2/bogus"; newrepo "$BOGUS"; ( cd "$BOGUS"; git remote add origin /nonexistent/bogus.git )
o=$(r "git.ship" '{"version":"v9.9.9"}' true "$BOGUS")
[[ "$(sok "$o")" == false ]] || fail "FAILED PUSH REPORTED AS SUCCESS — git.ship claimed ok:true on a bogus remote: $o"
ssum "$o" | grep -qi 'fail' || fail "git.ship push-failure summary should say it FAILED: $(ssum "$o")"
[[ "$(sdata "$o" pushed)" != "true" ]] || fail "git.ship marked pushed:true when the push failed: $o"
[[ -z "$(git -C "$BOGUS" tag -l v9.9.9)" ]] || fail "git.ship left the local tag behind after a failed push (no rollback)"

# ── 5) git.ship happy path: against a REAL reachable remote the tag actually lands
#       (honest success on the push, whatever gh does afterward). ──
GOOD="$2/good"; newrepo "$GOOD"
git clone --bare -q "$GOOD" "$2/good_remote.git"
( cd "$GOOD"; git remote add origin "$2/good_remote.git"; git push -q -u origin main )
o=$(r "git.ship" '{"version":"v1.2.3"}' true "$GOOD")
[[ "$(sdata "$o" pushed)" == "true" ]] || fail "git.ship did not report a successful push on a real remote: $o"
[[ "$(git -C "$2/good_remote.git" tag -l v1.2.3)" == "v1.2.3" ]] || fail "git.ship did not push the tag to the remote"

# ── 6) git.quicksave refuses a useless commit message (empty or 'wip') ──
o=$(r "git.quicksave" '{"message":"wip"}' true)
[[ "$(sok "$o")" == false ]] || fail "git.quicksave accepted 'wip' as a message: $o"
ssum "$o" | grep -qi 'wip' || fail "git.quicksave 'wip' rejection message unexpected: $(ssum "$o")"
o=$(r "git.quicksave" '{"message":""}' true)
[[ "$(sok "$o")" == false ]] || fail "git.quicksave accepted an empty message: $o"
ssum "$o" | grep -qi 'message required' || fail "git.quicksave empty-message rejection unexpected: $(ssum "$o")"
o=$(r "git.quicksave" '{"message":"   "}' true)
[[ "$(sok "$o")" == false ]] || fail "git.quicksave accepted a whitespace-only message: $o"

# ── 7) git.conflict-assist is a safe no-op when there is nothing in conflict ──
o=$(r "git.conflict-assist" '{"action":"show"}' true "$2")
[[ "$(sok "$o")" == true ]] || fail "conflict-assist on a clean repo should be an ok no-op: $o"
ssum "$o" | grep -qi 'nothing to assist' || fail "conflict-assist no-op summary unexpected: $(ssum "$o")"

# ── 8) pr.merge is `writes` and machine mode auto-denies it without auto_confirm ──
o=$(r "pr.merge" '{"method":"squash"}' false "$BOGUS")
[[ "$(sok "$o")" == false ]] || fail "pr.merge was not consent-gated in machine mode: $o"
ssum "$o" | grep -qi 'consent\|confirm' || fail "pr.merge gate message unexpected: $(ssum "$o")"

echo "vcs_actions_body OK"
