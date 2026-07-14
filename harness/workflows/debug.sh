# workflows/debug.sh — Evidence-first debugging (zero LLM).
# Seniors gather facts before forming theories; this automates the gathering.

# debug.triage — one evidence bundle: env, versions, toolchain, git state,
# recent changes, and (optionally) the failing command's output.
# Inputs: cmd (optional — a repro/failing command to run and capture).
wf_debug_triage() {
    local bundle t v
    bundle=$(path_temp_file yca-triage .md)
    emit_progress "triage" "collecting evidence" 20
    {
        printf '# Debug triage — %s\n\n' "$(now_stamp '%Y-%m-%d %H:%M:%S')"
        printf '## Environment\n'
        printf -- '- os: %s\n' "$(uname -srm 2>/dev/null)"
        printf -- '- shell: bash %s\n' "$BASH_VERSION"
        printf -- '- project: %s\n' "$YCA_PROJECT_DIR"
        for t in git node npm python3 rustc cargo go java docker jq curl; do
            command -v "$t" &>/dev/null || continue
            v=$("$t" --version 2>/dev/null | head -1)
            [[ -z "$v" ]] && v=$("$t" version 2>/dev/null | head -1)
            printf -- '- %s: %s\n' "$t" "${v:-?}"
        done
        printf '\n## Toolchain profile\n```json\n%s\n```\n' "$(toolchain_profile_json)"
        if ( cd "$YCA_PROJECT_DIR" && git rev-parse --git-dir &>/dev/null ); then
            printf '\n## Git state\n'
            printf -- '- branch: %s @ %s\n' \
                "$(cd "$YCA_PROJECT_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null)" \
                "$(cd "$YCA_PROJECT_DIR" && git rev-parse --short HEAD 2>/dev/null)"
            printf -- '- dirty paths: %s\n' "$(cd "$YCA_PROJECT_DIR" && git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
            printf '\n### Last 5 commits (suspects, newest first)\n```\n'
            ( cd "$YCA_PROJECT_DIR" && git log --oneline -5 2>/dev/null )
            printf '```\n\n### Uncommitted changes\n```\n'
            ( cd "$YCA_PROJECT_DIR" && git diff --stat HEAD 2>/dev/null | tail -10 )
            printf '```\n'
        fi
        if [[ -n "${INPUT_cmd:-}" ]]; then
            printf '\n## Repro command\n`%s`\n\n' "$INPUT_cmd"
            # Running the repro is arbitrary code execution, so it is consent-
            # gated: machine mode auto-denies without auto_confirm (the evidence
            # bundle above is still produced); interactive mode previews + prompts.
            # Without this, `debug.triage --cmd '<anything>'` was an ungated bash.
            if confirm_action "Run repro command in $YCA_PROJECT_DIR" "$INPUT_cmd"; then
                local out rc
                out=$(cd "$YCA_PROJECT_DIR" && eval "$INPUT_cmd" 2>&1) && rc=0 || rc=$?
                printf 'Exit code: %s\n\n```\n%s\n```\n' "$rc" "$(printf '%s\n' "$out" | tail -60)"
            else
                printf '_Repro command not run — needs confirmation (re-run with -y / auto_confirm to execute)._\n'
            fi
        fi
        printf '\n## How a senior reads this\n'
        printf -- '- read the FIRST error, not the last — later ones are usually fallout\n'
        printf -- '- "what changed?" beats "what is wrong?" — start from the last 5 commits + dirty files\n'
        printf -- '- reproduce with the smallest possible command before touching any code\n'
        printf -- '- if it works locally but not elsewhere, diff the two environments above\n'
    } > "$bundle"
    cat "$bundle" >&2
    emit result "$(jq -n --arg b "$bundle" \
        '{ok:true,summary:("triage bundle at "+$b),data:{bundle:$b}}')"
}

wf_register "debug.triage" wf_debug_triage 1 safe "" "Evidence bundle: env+versions+git state+repro output (add --cmd '<failing cmd>')"
