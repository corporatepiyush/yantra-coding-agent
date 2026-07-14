# workflows/mentor.sh — Encoded senior judgment (zero LLM, fully deterministic).
# Pattern-matched diagnosis, commit-message coaching, and pre-merge checklists.

# mentor.explain-error — classify an error message into a known failure class
# and emit the diagnosis + next steps a senior would give. Input: error (text).
wf_mentor_explain_error() {
    local err="${INPUT_error:-}"
    val_required "$err" "INPUT_error" || return 1
    local low="${err,,}" class diag steps
    if [[ "$low" == *enoent* || "$low" == *"no such file or directory"* ]]; then
        class="missing-file (ENOENT)"
        diag="Something referenced a path that doesn't exist — wrong relative path, missing build/codegen step, or wrong working directory."
        steps=$'1. Take the exact path from the error and check it: ls -la <path>\n2. Check your CWD — relative paths break when run from elsewhere; anchor to the project root\n3. If the file is generated, run the build/codegen step first\n4. Watch case: macOS is case-insensitive, Linux CI is not'
    elif [[ "$low" == *eacces* || "$low" == *"permission denied"* ]]; then
        class="permissions (EACCES)"
        diag="The process lacks rights on a file, directory, or port. Do NOT reach for sudo — fix ownership or the port."
        steps=$'1. ls -la the path — who owns it? (a past sudo npm/pip run often left root-owned files)\n2. chown it back to your user rather than sudo-ing the command\n3. Ports < 1024 need privileges — use 3000/8080 instead\n4. If in Docker, check the container user vs the volume owner'
    elif [[ "$low" == *eaddrinuse* || "$low" == *"address already in use"* ]]; then
        class="port-in-use (EADDRINUSE)"
        diag="Another process (often a zombie of your own dev server) already holds the port."
        steps=$'1. Find it: lsof -i :<port>   (or: fuser <port>/tcp on Linux)\n2. If it is your old process: kill <pid> (add -9 only if it ignores the polite one)\n3. If it is legitimate, run on another port instead of killing it\n4. Recurring? Your dev script is not shutting down cleanly — fix the signal handling'
    elif [[ "$low" == *econnrefused* || "$low" == *"connection refused"* ]]; then
        class="connection-refused (ECONNREFUSED)"
        diag="Nothing is listening at that host:port. This is a 'dependency not running / wrong address' error, not a code bug."
        steps=$'1. Is the dependency (db/api/cache) actually running? Check its process/container\n2. Verify host+port in your config — localhost inside Docker is the CONTAINER, not your machine (use the service name or host.docker.internal)\n3. curl/nc the address from where the code runs, not from your shell\n4. Check the dependency started BEFORE the app (ordering/healthcheck)'
    elif [[ "$low" == *etimedout* || "$low" == *"timed out"* || "$low" == *"timeout"* ]]; then
        class="timeout"
        diag="The remote exists but didn't answer in time — network path, firewall, overload, or a too-tight timeout."
        steps=$'1. Reproduce with curl -v and time it — is it slow or completely black-holed?\n2. Black-holed usually means firewall/security-group/VPN, not code\n3. Slow: check the dependency load and any N+1 calls behind the request\n4. Only after understanding: raise the timeout deliberately; add a retry with backoff for transient cases'
    elif [[ "$low" == *"cannot find module"* || "$low" == *modulenotfounderror* || "$low" == *"no module named"* || "$low" == *importerror* || "$low" == *"cannot resolve"* || "$low" == *"could not resolve"* ]]; then
        class="module-not-found"
        diag="The runtime can't locate a dependency or local file — not installed, wrong env, or a bad import path."
        steps=$'1. Installed at all? npm ls <pkg> / pip show <pkg> — then install and commit the lockfile change\n2. Wrong environment: are you in the right venv/node version? (which python / which node)\n3. Local import: check the path and its case exactly as written\n4. Fresh clone failing = missing from the manifest; it only worked for you via a global install'
    elif [[ "$low" == *nullpointerexception* || "$low" == *"undefined is not"* || "$low" == *"cannot read propert"* || "$low" == *nonetype* || "$low" == *"nil pointer"* ]]; then
        class="null-reference"
        diag="Code assumed a value exists and it didn't. The bug is almost never at the crash line — it's wherever the null was BORN."
        steps=$'1. Read the stack trace to the deepest frame in YOUR code — that is where to look\n2. Ask: why was this null? (missing config, empty API response, unawaited async, bad default)\n3. Fix the SOURCE, and validate at the boundary (parse, don\x27t assume)\n4. Add a test that feeds the same null through — this class of bug loves to return'
    elif [[ "$low" == *cors* || "$low" == *"cross-origin"* ]]; then
        class="CORS"
        diag="The browser blocked a cross-origin call because the SERVER didn't allow your origin. It is a server config issue — client-side hacks are a trap."
        steps=$'1. Check the failing request in devtools — is the preflight OPTIONS the one failing?\n2. Fix on the server: allow the exact origin (not * if you send credentials)\n3. In dev, prefer a proxy (vite/webpack devServer.proxy) over loosening the server\n4. Never ship Access-Control-Allow-Origin: * with credentials — that is a security hole'
    elif [[ "$low" == *"out of memory"* || "$low" == *"heap"*"limit"* || "$low" == *oom* || "$low" == *"exit code 137"* || "$low" == *"code 137"* ]]; then
        class="out-of-memory (OOM)"
        diag="The process exceeded available memory (exit 137 = SIGKILL, usually the OOM killer). Raising the limit hides it; something is holding too much at once."
        steps=$'1. Find WHAT grew: heap snapshot / memory profiler, or log RSS over time\n2. Common causes: loading a whole file/table into memory (stream it), unbounded cache, leak in a loop\n3. In containers: check the container memory limit before blaming the code\n4. Raise limits only as a stopgap, with a ticket to fix the real growth'
    elif [[ "$low" == *sigsegv* || "$low" == *"segmentation fault"* || "$low" == *"core dumped"* ]]; then
        class="segfault"
        diag="Native code touched invalid memory. In high-level languages this is almost always a native extension or a version mismatch, not your code."
        steps=$'1. Which native dep is in the stack? Rebuild it against the current runtime (npm rebuild / pip reinstall --no-binary)\n2. Did the language runtime version change recently? Match versions across the team/CI\n3. In C/C++/Rust-unsafe: run under ASan/valgrind and fix the first invalid access\n4. Reproduce with the smallest input — segfaults shrink well'
    elif [[ "$low" == *"unsupported engine"* || "$low" == *"requires node"* || "$low" == *"incompatible"* || ( "$low" == *version* && "$low" == *required* ) ]]; then
        class="version-mismatch"
        diag="Tool/runtime version differs from what the project requires. Environments drift; pinning stops the drift."
        steps=$'1. Compare: the error names the required version — check yours (node -v / python --version / rustc --version)\n2. Use the project pin: .nvmrc/.tool-versions/rust-toolchain — install a version manager if you have none\n3. Align CI and local to the SAME pinned version\n4. If you own the project: commit the version pin so the next person skips this'
    elif [[ "$low" == *certificate* || "$low" == *"ssl"* || "$low" == *"self-signed"* || "$low" == *tls* ]]; then
        class="TLS/certificate"
        diag="The TLS handshake failed — expired/self-signed/wrong-host cert or a corporate proxy in the middle. Disabling verification is not a fix."
        steps=$'1. Inspect: openssl s_client -connect host:443 -servername host | openssl x509 -noout -dates -subject\n2. Expired → renew; wrong host → fix SAN/domain; self-signed → add the CA to your trust store\n3. Corporate proxy: export the proxy CA (NODE_EXTRA_CA_CERTS / REQUESTS_CA_BUNDLE)\n4. NEVER commit rejectUnauthorized:false / verify=False — it silently disables security for everyone'
    elif [[ "$low" == *"401"* || "$low" == *unauthorized* || "$low" == *"403"* || "$low" == *forbidden* || "$low" == *"invalid token"* || "$low" == *"expired token"* ]]; then
        class="auth (401/403)"
        diag="401 = who are you? (missing/expired credentials). 403 = I know you, and no (insufficient permissions). Different fixes."
        steps=$'1. 401: is the credential present AND fresh? Decode the JWT exp / re-login / rotate the key\n2. 403: the credential works but lacks the scope/role — fix permissions, not the token\n3. Check the credential is sent the way the API expects (header name, Bearer prefix)\n4. Works in curl but not in code? Log the outgoing request headers (redacted) and diff'
    elif [[ "$low" == *"429"* || "$low" == *"rate limit"* || "$low" == *"too many requests"* ]]; then
        class="rate-limit (429)"
        diag="You're calling faster than the provider allows. Hammering harder makes it worse — back off and batch."
        steps=$'1. Read the Retry-After header and honor it\n2. Add exponential backoff with jitter to the client\n3. Look for the real bug: a loop/retry storm is usually WHY you hit the limit\n4. Cache or batch requests; check if the API has a bulk endpoint'
    elif [[ "$low" == *enospc* || "$low" == *"no space left"* ]]; then
        class="disk-full (ENOSPC)"
        diag="The disk (or inode table) is full. On dev machines it's usually caches and old build artifacts."
        steps=$'1. Confirm: df -h (and df -i for inodes)\n2. Reclaim safely: run the disk.scan workflow, then disk.clean\n3. Usual suspects: node_modules graveyards, docker system df, old logs\n4. On servers: find the runaway log/tmp writer before cleaning, or it refills tonight'
    elif [[ "$low" == *"relation"*"does not exist"* || "$low" == *"table"*"doesn't exist"* || "$low" == *"no such table"* || "$low" == *migration* ]]; then
        class="database-schema"
        diag="The code expects schema the database doesn't have — migrations not applied (or applied out of order)."
        steps=$'1. Run the pending migrations for THIS environment\n2. Check which env/database the app actually connected to — wrong DB URL is the classic\n3. Fresh checkout: seed/setup step probably documented in the README\n4. If migrations diverged between branches, resolve order before piling on new ones'
    elif [[ "$low" == *"<<<<<<<"* || "$low" == *"merge conflict"* || "$low" == *"unmerged paths"* ]]; then
        class="merge-conflict"
        diag="Two changes touched the same lines. Conflicts are resolved by understanding INTENT, not by picking a side blindly."
        steps=$'1. git status — see every conflicted file before editing any\n2. For each: understand what BOTH sides were trying to do (git log --merge -p <file>)\n3. Resolve for combined intent; remove ALL <<<<<<< ======= >>>>>>> markers\n4. Build + run tests BEFORE concluding the merge; a compiling conflict resolution can still be wrong'
    else
        class="unclassified"
        diag="No known signature matched — apply the generic senior triage loop."
        steps=$'1. Read the FIRST error in the output, not the last — later errors are fallout\n2. Ask "what changed?" before "what is broken?" — check git log/diff and recent dep updates\n3. Reduce to the smallest command that still fails\n4. Read the actual error text slowly; it usually says exactly what is wrong\n5. Search the exact quoted message — someone hit this before you'
    fi

    logmsg "$(c_info '═══ Error triage ═══')"
    logmsg "Error:     ${err:0:200}"
    logmsg "Class:     $class"
    logmsg "Diagnosis: $diag"
    logmsg "Next steps:"
    local line
    while IFS= read -r line; do logmsg "  $line"; done <<< "$steps"
    emit result "$(jq -n --arg c "$class" --arg d "$diag" --arg s "$steps" \
        '{ok:true,summary:("error class: "+$c),data:{class:$c,diagnosis:$d,steps:$s}}')"
}

# mentor.commit-msg — critique a commit message (INPUT_message, else last commit)
# against the rules seniors actually enforce.
wf_mentor_commit_msg() {
    local msg="${INPUT_message:-}"
    if [[ -z "$msg" ]]; then
        doctor_check_needs "git" || return 1
        msg=$(cd "$YCA_PROJECT_DIR" && git log -1 --pretty=%B 2>/dev/null)
        [[ -z "$msg" ]] && { emit_fail "no message given and no commits yet"; return 0; }
    fi
    local subject body
    subject=$(head -1 <<< "$msg")
    body=$(tail -n +3 <<< "$msg")

    local -a notes=()
    local len=${#subject} first="${subject%% *}"
    (( len > 72 )) && notes+=("subject is $len chars — keep it ≤72 so it doesn't truncate in logs/GitHub")
    (( len < 10 )) && notes+=("subject is only $len chars — say what changed AND where")
    [[ "$subject" == *. ]] && notes+=("drop the trailing period — subjects are titles, not sentences")
    local stripped="${subject#*: }" firstword
    firstword="${stripped%% *}"; firstword="${firstword,,}"
    case "$firstword" in
        fixed|added|removed|updated|changed|refactored|implemented|created|deleted)
            notes+=("past tense '$firstword' — use imperative mood (fix/add/remove): a commit says what applying it DOES") ;;
        fixes|adds|removes|updates|changes)
            notes+=("third person '$firstword' — use imperative mood (fix/add/remove)") ;;
        adding|fixing|updating|removing|changing|refactoring)
            notes+=("gerund '$firstword' — use imperative mood (fix/add/remove)") ;;
    esac
    if grep -qiE '^(wip|stuff|misc|minor|various|things|fix|fixes|update|updates|changes|oops|asdf|temp|tmp|test)$|^(fix bug|fix stuff|small fix|minor changes|more changes|final fix)$' <<< "$subject"; then
        notes+=("'$subject' tells a future reader nothing — name the behavior: 'fix <what> when <condition>'")
    fi
    if [[ ! "$subject" =~ ^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\(.+\))?!?: ]]; then
        notes+=("no conventional-commit prefix — 'feat:/fix:/chore:' makes changelogs and release automation free")
    fi
    if [[ -z "$body" && -z "${INPUT_message:-}" ]]; then
        local dsize
        dsize=$(cd "$YCA_PROJECT_DIR" && git show --numstat --pretty=format: HEAD 2>/dev/null | awk '{i+=$1+$2} END{print i+0}')
        [[ "${dsize:-0}" -gt 100 ]] && notes+=("$dsize changed lines with no body — the subject says WHAT, the body must say WHY")
    fi

    logmsg "$(c_info '═══ Commit message review ═══')"
    logmsg "  Subject: $subject"
    local n
    for n in "${notes[@]}"; do logmsg "$(c_warn "  ⚠ $n")"; done
    if [[ ${#notes[@]} -eq 0 ]]; then
        logmsg "$(c_ok '  ✓ solid — imperative, specific, well-sized')"
    else
        logmsg ""
        logmsg "  Template: <type>(<scope>): <imperative summary ≤72 chars>"
        logmsg "            <blank line>"
        logmsg "            Why the change was needed; what it does NOT cover; links."
    fi
    local ok=true; [[ ${#notes[@]} -gt 2 ]] && ok=false
    emit result "$(jq -n --argjson ok "$ok" --argjson n "${#notes[@]}" --arg s "$subject" \
        '{ok:$ok,summary:("commit-msg review: "+($n|tostring)+" note(s)"),data:{subject:$s,notes:$n}}')"
}

# mentor.checklist — the pre-merge checklist a senior holds in their head,
# tailored to change kind (feature|bugfix|refactor|hotfix) and toolchain.
wf_mentor_checklist() {
    local kind="${INPUT_kind:-feature}" tc
    val_in_list "$kind" feature bugfix refactor hotfix || return 1
    tc=$(toolchain_detect)

    logmsg "$(c_info "═══ Pre-merge checklist ($kind) ═══")"
    logmsg "  [ ] the change does ONE thing (if you wrote 'and' in the PR title, split it)"
    logmsg "  [ ] you ran it once for real, not just the tests"
    logmsg "  [ ] errors/timeouts on the new path fail loudly, not silently"
    logmsg "  [ ] no secrets, no debug prints, no commented-out code in the diff"
    logmsg "  [ ] names read like the domain, not like the implementation"
    case "$kind" in
        feature)
            logmsg "  [ ] a test exercises the new behavior (happy path AND one failure path)"
            logmsg "  [ ] feature is discoverable: docs/changelog/flag noted"
            logmsg "  [ ] rollout thought through: can it ship dark / behind a flag?" ;;
        bugfix)
            logmsg "  [ ] a test REPRODUCES the bug and fails without the fix — else the bug returns"
            logmsg "  [ ] you fixed the cause, not the symptom (why was the value wrong, not just null-check it)"
            logmsg "  [ ] you checked for the same bug pattern elsewhere in the codebase" ;;
        refactor)
            logmsg "  [ ] behavior is UNCHANGED — tests pass before and after with no test edits"
            logmsg "  [ ] no functional change smuggled in (reviewers can't verify both at once)"
            logmsg "  [ ] mechanical steps done in separate commits from judgment steps" ;;
        hotfix)
            logmsg "  [ ] smallest possible diff — resist the drive-by cleanup"
            logmsg "  [ ] verified against the DEPLOYED version, not main"
            logmsg "  [ ] rollback command written down BEFORE merging"
            logmsg "  [ ] follow-up ticket filed for the real fix + the missing test" ;;
    esac
    case "$tc" in *node*)
        logmsg "  [ ] lockfile committed with the manifest change; no console.log left" ;; esac
    case "$tc" in *python*)
        logmsg "  [ ] ruff/format clean; new public functions have type hints" ;; esac
    case "$tc" in *rust*)
        logmsg "  [ ] cargo clippy clean; no unwrap()/expect() on fallible paths in lib code" ;; esac
    case "$tc" in *go*)
        logmsg "  [ ] errors wrapped with context (fmt.Errorf %w), not swallowed; go vet clean" ;; esac
    logmsg ""
    logmsg "  Run the deterministic parts: review.precommit, review.risk, pipeline.preflight"
    emit result "$(jq -n --arg k "$kind" --arg t "$tc" \
        '{ok:true,summary:("checklist for "+$k),data:{kind:$k,toolchain:$t}}')"
}

wf_register "mentor.explain-error" wf_mentor_explain_error 1 safe ""    "Classify an error message; senior diagnosis + next steps (no LLM)"
wf_register "mentor.commit-msg"    wf_mentor_commit_msg    1 safe ""    "Critique a commit message (given, or the last commit)"
wf_register "mentor.checklist"     wf_mentor_checklist     1 safe ""    "Pre-merge checklist tailored to change kind + toolchain"
