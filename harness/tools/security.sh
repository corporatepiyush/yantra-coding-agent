# tools/security.sh — Security scanning tools (secrets, SAST, IaC, containers, SBOM, deps)

# ── Helpers ──────────────────────────────────────────────────────────────
_sec_missing() { printf 'tool missing: %s\ninstall: %s' "$1" "$2"; }
_sec_run() {
    local tool="$1" hint="$2"; shift 2
    command -v "$tool" &>/dev/null || { _sec_missing "$tool" "$hint"; return 1; }
    "$tool" "$@" 2>&1
}

# ── Doctor ─────────────────────────────────────────────────────────────────
tool_sec_doctor() {
    local out=""
    local t v
    for t in gitleaks trufflehog semgrep checkov tfsec kube-bench grype trivy syft osv-scanner; do
        v=$(command -v "$t" 2>/dev/null && printf 'ok' || printf 'MISSING')
        out+="$t: $v\n"
    done
    printf '%b' "$out"
}

# ── Secrets ──────────────────────────────────────────────────────────────
tool_sec_scan_secrets() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    if command -v gitleaks &>/dev/null; then
        gitleaks detect --source="$dir" --no-git 2>&1
    elif command -v trufflehog &>/dev/null; then
        trufflehog filesystem --directory="$dir" 2>&1
    else
        _sec_missing "gitleaks" "brew install gitleaks / https://github.com/gitleaks/gitleaks/releases"
        return 1
    fi
}

# ── IaC ──────────────────────────────────────────────────────────────────
tool_sec_scan_iac() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    if command -v checkov &>/dev/null; then
        checkov -d "$dir" --compact 2>&1
    elif command -v tfsec &>/dev/null; then
        tfsec "$dir" 2>&1
    else
        _sec_missing "checkov" "pip install checkov"
        return 1
    fi
}

# ── SAST ─────────────────────────────────────────────────────────────────
tool_sec_semgrep() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    if command -v semgrep &>/dev/null; then
        semgrep --config=auto "$dir" 2>&1
    else
        _sec_missing "semgrep" "pip install semgrep"
        return 1
    fi
}

# ── Container scan ───────────────────────────────────────────────────────
tool_sec_container_scan() {
    local target="${1:-$YCA_PROJECT_DIR}"
    if command -v trivy &>/dev/null; then
        if [[ -d "$target" ]]; then
            trivy fs "$target" 2>&1
        else
            trivy image "$target" 2>&1
        fi
    elif command -v grype &>/dev/null; then
        grype "$target" 2>&1
    else
        _sec_missing "trivy" "brew install trivy / https://github.com/aquasecurity/trivy#quick-start"
        return 1
    fi
}

# ── SBOM ─────────────────────────────────────────────────────────────────
tool_sec_sbom() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    if command -v syft &>/dev/null; then
        syft "$dir" -o cyclonedx-json 2>&1
    else
        _sec_missing "syft" "brew install syft / https://github.com/anchore/syft#installation"
        return 1
    fi
}

# ── Kubernetes CIS benchmark ─────────────────────────────────────────────
tool_sec_kube_bench() {
    if command -v kube-bench &>/dev/null; then
        kube-bench run 2>&1
    else
        _sec_missing "kube-bench" "https://github.com/aquasecurity/kube-bench#installation"
        return 1
    fi
}

# ── OSV (open source vulnerabilities) ─────────────────────────────────────
tool_sec_osv() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    if command -v osv-scanner &>/dev/null; then
        osv-scanner --recursive --lockfile "$dir" 2>&1
    else
        _sec_missing "osv-scanner" "go install github.com/google/osv-scanner/cmd/osv-scanner@latest"
        return 1
    fi
}

# ── Dependency audit (language-aware) ────────────────────────────────────
tool_sec_dep_audit() {
    local dir="${1:-$YCA_PROJECT_DIR}" ran=""
    if [[ -f "$dir/package-lock.json" || -f "$dir/yarn.lock" || -f "$dir/pnpm-lock.yaml" ]]; then
        if command -v npm &>/dev/null; then
            ran="npm audit"
            (cd "$dir" && npm audit 2>&1)
        else
            printf 'npm not found — cannot audit JS deps'
        fi
    elif [[ -f "$dir/requirements.txt" || -f "$dir/pyproject.toml" || -f "$dir/Pipfile" ]]; then
        if command -v pip-audit &>/dev/null; then
            ran="pip-audit"
            pip-audit -r "$dir" 2>&1
        else
            printf 'pip-audit not found — install: pip install pip-audit'
        fi
    elif [[ -f "$dir/Cargo.lock" || -f "$dir/Cargo.toml" ]]; then
        if command -v cargo-audit &>/dev/null; then
            ran="cargo audit"
            (cd "$dir" && cargo audit 2>&1)
        else
            printf 'cargo-audit not found — install: cargo install cargo-audit'
        fi
    elif [[ -f "$dir/Gemfile.lock" ]]; then
        if command -v bundle-audit &>/dev/null; then
            ran="bundle audit"
            (cd "$dir" && bundle audit check --update 2>&1)
        else
            printf 'bundle-audit not found — install: gem install bundler-audit'
        fi
    else
        printf 'no supported dependency manifests found (package-lock.json, requirements.txt, Cargo.lock, Gemfile.lock)'
        return 1
    fi
    [[ -n "$ran" ]] && printf '\n[ran: %s]' "$ran"
}

# ── Local hygiene audits (no external scanners needed) ──────────────────
_sec_perm() {
    case "$(os_detect)" in
        darwin) stat -f '%Lp' "$1" 2>/dev/null ;;
        *)      stat -c '%a' "$1" 2>/dev/null ;;
    esac
}

# world_writable — files/dirs anyone on the machine can modify.
tool_sec_find_world_writable() {
    local dir="${1:-$YCA_PROJECT_DIR}"
    printf '=== world-writable files (top 50) ===\n'
    find "$dir" -type f -perm -0002 ! -path '*/.git/*' 2>/dev/null | head -50
    printf '\n=== world-writable dirs (top 20) ===\n'
    find "$dir" -type d -perm -0002 ! -path '*/.git/*' 2>/dev/null | head -20
    printf '\n(fix: chmod o-w <path>)\n'
}

# suid — setuid/setgid binaries under a path (privilege-escalation surface).
tool_sec_find_suid() {
    local dir="${1:-$YCA_PROJECT_DIR}" out
    out=$(find "$dir" -type f \( -perm -4000 -o -perm -2000 \) 2>/dev/null | head -50)
    [[ -n "$out" ]] && printf '%s\n' "$out" || printf 'no setuid/setgid files under %s' "$dir"
}

# perm_audit — permissions on sensitive credential files in $HOME.
tool_sec_perm_audit() {
    local out="" entry f want perm
    local -a checks=(
        "$HOME/.ssh:700" "$HOME/.gnupg:700"
        "$HOME/.netrc:600" "$HOME/.pgpass:600" "$HOME/.my.cnf:600"
        "$HOME/.aws/credentials:600" "$HOME/.kube/config:600"
        "$HOME/.npmrc:600" "$HOME/.docker/config.json:600"
    )
    for entry in "${checks[@]}"; do
        f="${entry%:*}"; want="${entry##*:}"
        [[ -e "$f" ]] || continue
        perm=$(_sec_perm "$f")
        if [[ "$perm" == "$want" || ( "$want" == "600" && "$perm" == "400" ) ]]; then
            out+="[ok]   $perm $f\n"
        else
            out+="[WARN] $perm $f (recommend $want)\n"
        fi
    done
    local k
    for k in "$HOME"/.ssh/id_*; do
        [[ -f "$k" && "$k" != *.pub ]] || continue
        perm=$(_sec_perm "$k")
        if [[ "$perm" == "600" || "$perm" == "400" ]]; then out+="[ok]   $perm $k\n"
        else out+="[WARN] $perm $k (private keys must be 600)\n"; fi
    done
    [[ -z "$out" ]] && out="no sensitive files found to audit\n"
    printf '%b' "$out"
}

# history_scan — flag secret-looking lines in shell history (line numbers only,
# values are never printed).
tool_sec_history_scan() {
    local pat='(password|passwd|api[_-]?key|secret|token|bearer |aws_secret|ghp_[A-Za-z0-9]|sk-[A-Za-z0-9]{8})'
    local f count found=0
    for f in "$HOME/.bash_history" "$HOME/.zsh_history" "$HOME/.local/share/fish/fish_history"; do
        [[ -f "$f" ]] || continue
        count=$(grep -Eic "$pat" "$f" 2>/dev/null) || count=0
        if (( count > 0 )); then
            found=1
            printf '%s: %d suspicious lines (line numbers only): ' "$f" "$count"
            grep -Ein "$pat" "$f" 2>/dev/null | cut -d: -f1 | head -20 | tr '\n' ' '
            printf '\n'
        fi
    done
    if (( found )); then
        printf '\nrotate any real secrets, then scrub: history -d <n> / edit the file\n'
    else
        printf 'no obvious secrets in shell history'
    fi
}

# ssh_audit — weak settings in ssh/sshd configs + key inventory.
tool_sec_ssh_audit() {
    local out="" f hits k
    for f in "$HOME/.ssh/config" /etc/ssh/sshd_config /etc/ssh/ssh_config; do
        [[ -f "$f" && -r "$f" ]] || continue
        out+="=== $f ===\n"
        hits=$(grep -niE '^[[:space:]]*(PasswordAuthentication[[:space:]]+yes|PermitRootLogin[[:space:]]+yes|StrictHostKeyChecking[[:space:]]+no|ForwardAgent[[:space:]]+yes|PermitEmptyPasswords[[:space:]]+yes|Protocol[[:space:]]+1)' "$f" 2>/dev/null)
        [[ -n "$hits" ]] && out+="[WARN] weak settings:\n$hits\n" || out+="[ok] no weak settings\n"
    done
    out+="=== keys (~/.ssh) ===\n"
    for k in "$HOME"/.ssh/*.pub; do
        [[ -f "$k" ]] || continue
        out+="$(ssh-keygen -lf "$k" 2>/dev/null || printf 'unreadable: %s' "$k")\n"
    done
    printf '%b' "$out"
}

# env_scan — env var NAMES that look like secrets (values never printed).
tool_sec_env_scan() {
    local n count=0
    while IFS= read -r n; do
        [[ "$n" =~ (KEY|TOKEN|SECRET|PASSWORD|PASSWD|CREDENTIAL) ]] || continue
        local v="${!n:-}"
        printf '%s (length %d, value hidden)\n' "$n" "${#v}"
        ((count++))
    done < <(compgen -e)
    (( count > 0 )) || printf 'no secret-looking env var names'
    printf '\n(these leak into child processes and crash reports — prefer a secrets manager)\n'
}

# ── Register ─────────────────────────────────────────────────────────────
tool_register "sec_scan_secrets"       tool_sec_scan_secrets       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_scan_iac"           tool_sec_scan_iac           '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_semgrep"       tool_sec_semgrep       '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_container_scan" tool_sec_container_scan '{"type":"object","properties":{"target":{"type":"string","description":"the target to act on"}}}' safe all sec
tool_register "sec_sbom"          tool_sec_sbom          '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_kube_bench"    tool_sec_kube_bench    '{"type":"object","properties":{}}' safe all sec
tool_register "sec_osv"           tool_sec_osv           '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_dep_audit"     tool_sec_dep_audit     '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_doctor"        tool_sec_doctor        '{"type":"object","properties":{}}' safe all sec
tool_register "sec_find_world_writable" tool_sec_find_world_writable '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_find_suid"          tool_sec_find_suid          '{"type":"object","properties":{"path":{"type":"string","description":"file or directory path relative to the project root"}}}' safe all sec
tool_register "sec_perm_audit"    tool_sec_perm_audit    '{"type":"object","properties":{}}' safe all sec
tool_register "sec_history_scan"  tool_sec_history_scan  '{"type":"object","properties":{}}' safe all sec
tool_register "sec_ssh_audit"     tool_sec_ssh_audit     '{"type":"object","properties":{}}' safe all sec
tool_register "sec_env_scan"      tool_sec_env_scan      '{"type":"object","properties":{}}' safe all sec
