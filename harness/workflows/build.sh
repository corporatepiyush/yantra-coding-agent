# workflows/build.sh — Build workflows

wf_build_run() {
    local cmd
    cmd=$(toolchain_profile_json | jq -r '.build // empty')
    [[ -z "$cmd" || "$cmd" == "null" ]] && { emit_fail "no build command detected"; return 1; }
    emit_progress "build" "$cmd (hold my beer)"
    local out rc
    out=$(cd "$YCA_PROJECT_DIR" && eval "$cmd" 2>&1) && rc=0 || rc=$?
    printf '%s\n' "$out" >&2
    emit result "$(jq -n --argjson rc "$rc" '{ok:($rc==0),summary:("build exit "+($rc|tostring))}')"
}

wf_build_clean() {
    local kind cmd
    kind=$(toolchain_detect)
    case "$kind" in
        *rust*)   cmd="cargo clean" ;;
        *node*)   cmd="rm -rf dist build node_modules" ;;
        *python*) cmd="rm -rf build dist *.egg-info __pycache__" ;;
        *c-cpp*)  cmd="make clean 2>/dev/null || rm -rf build" ;;
        *java*)   cmd="mvn clean 2>/dev/null || gradle clean" ;;
        *)        cmd="rm -rf dist build" ;;
    esac
    confirm_action "Clean build artifacts" "$cmd" || { emit_fail "cancelled"; return 0; }
    ( cd "$YCA_PROJECT_DIR" && eval "$cmd" )
    emit_ok "cleaned"
}

wf_register "build.run"   wf_build_run   1 safe "" "Build project"
wf_register "build.clean" wf_build_clean 1 writes "" "Clean build artifacts"
