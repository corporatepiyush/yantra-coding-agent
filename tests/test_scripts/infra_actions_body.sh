#!/usr/bin/env bash
# tests/test_scripts/infra_actions_body.sh — k8s/helm act-half: arg validation (no
# kubectl/helm needed; validated before the tool-present check), the consent gate,
# and gated registration tokens. Args: $1=YCA_DIR $2=TMP
set -Euo pipefail
export YCA_DIR="$1"
export YCA_PROJECT_DIR="$2"
source "$YCA_DIR/harness/main.sh" 2>/dev/null
YCA_PROJECT_DIR="$2"; YCA_SAFETY_PATHS="$2"; YCA_UI_MODE=json
YCA_CAT_ENABLED[kubernetes]=1; YCA_CAT_ENABLED[helm]=1
fail(){ echo "FAIL: $1"; exit 1; }

# ── k8s validation (rejects flag-injection + destructive defaults, offline) ──
out=$(YCA_TOOL_ARGS_JSON='{"resource":"pod","name":"--all"}' tool_k8s_delete 2>&1 || true)
echo "$out" | grep -qi 'invalid name' || fail "k8s_delete accepted --all as a name ($out)"
out=$(YCA_TOOL_ARGS_JSON='{"resource":"pod","name":"*"}' tool_k8s_delete 2>&1 || true)
echo "$out" | grep -qi 'refused' || fail "k8s_delete accepted a wildcard name ($out)"
out=$(YCA_TOOL_ARGS_JSON='{"resource":"-oyaml","name":"x"}' tool_k8s_delete 2>&1 || true)
echo "$out" | grep -qi 'invalid resource' || fail "k8s_delete accepted an option-injection resource ($out)"
out=$(YCA_TOOL_ARGS_JSON='{"resource":"deployment/api","replicas":"notnum"}' tool_k8s_scale 2>&1 || true)
echo "$out" | grep -qi 'replicas must be' || fail "k8s_scale accepted non-numeric replicas ($out)"
out=$(YCA_TOOL_ARGS_JSON='{"resource":"deployment/api","namespace":"-x"}' tool_k8s_rollout_restart 2>&1 || true)
echo "$out" | grep -qi 'invalid namespace' || fail "k8s_rollout_restart accepted an option-injection namespace ($out)"

# ── consent gate: destructive infra ops auto-deny in machine mode ──
YCA_AUTO_CONFIRM=false
for spec in 'k8s_delete {"resource":"pod","name":"x"}' 'k8s_scale {"resource":"deployment/api","replicas":1}' 'helm_uninstall {"target":"rel"}'; do
    t="${spec%% *}"; a="${spec#* }"
    out=$(tool_dispatch "$t" "$a" 2>&1 || true)
    echo "$out" | grep -qi 'cancel\|confirm' || fail "$t was not consent-gated in machine mode ($out)"
done

# ── registration: every new destructive/writes infra tool carries a gated token ──
for t in k8s_delete k8s_scale k8s_rollout_restart k8s_rollout_undo k8s_apply k8s_exec k8s_port_forward helm_uninstall helm_upgrade helm_rollback; do
    info="${YCA_TOOL_REGISTRY[$t]:-}"; [[ -n "$info" ]] || fail "$t not registered"
    IFS='|' read -r _fn dg _rest <<< "$info"
    danger_needs_confirm "$dg" || fail "$t tagged '$dg' — bypasses the consent gate"
done

# ── docker / redis validation + gating (offline; validated before tool check) ──
YCA_CAT_ENABLED[docker]=1; YCA_CAT_ENABLED[redis]=1
out=$(YCA_TOOL_ARGS_JSON='{"container":"-x","command":"id"}' tool_docker_exec 2>&1 || true)
echo "$out" | grep -qi 'invalid container' || fail "docker_exec accepted an option-injection container ($out)"
out=$(YCA_TOOL_ARGS_JSON="{\"src\":\"web:/etc/passwd\",\"dst\":\"/etc/evil_$$\"}" tool_docker_copy 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "docker_copy allowed a local dst outside the fence ($out)"

YCA_AUTO_CONFIRM=false
for spec in 'docker_exec {"container":"web","command":"id"}' 'docker_push {"name":"repo/img:tag"}' 'redis_flushdb {}'; do
    t="${spec%% *}"; a="${spec#* }"
    out=$(tool_dispatch "$t" "$a" 2>&1 || true)
    echo "$out" | grep -qi 'cancel\|confirm' || fail "$t was not consent-gated ($out)"
done
for t in docker_exec docker_copy docker_restart docker_push redis_flushdb; do
    info="${YCA_TOOL_REGISTRY[$t]:-}"; [[ -n "$info" ]] || fail "$t not registered"
    IFS='|' read -r _fn dg _rest <<< "$info"
    danger_needs_confirm "$dg" || fail "$t tagged '$dg' — bypasses the consent gate"
done

# ── s3: SigV4 path-style consistency + uri-encode + fence + gating (offline) ──
export S3_ACCESS_KEY=AKIATEST S3_SECRET_KEY=secrettestkey000000000000000000000000 S3_BUCKET=testbucket S3_ENDPOINT=https://s3.amazonaws.com S3_REGION=us-east-1
YCA_CAT_ENABLED[s3]=1
[[ "$(_s3_uri_encode 'a b/c+d')" == 'a%20b/c%2Bd' ]] || fail "_s3_uri_encode wrong (got $(_s3_uri_encode 'a b/c+d'))"
signed=$(_s3_sign GET testbucket mykey 2>&1 || true)
IFS='|' read -r _sa _sn _sp shost suri <<< "$signed"
[[ "$shost" == "s3.amazonaws.com" ]] || fail "_s3_sign host not path-style (got '$shost' — signature would mismatch)"
[[ "$suri" == "/testbucket/mykey" ]] || fail "_s3_sign uri wrong (got '$suri')"
out=$(YCA_TOOL_ARGS_JSON='{"file":"/etc/hosts","key":"x"}' tool_s3_upload 2>&1 || true)
echo "$out" | grep -qi 'not allowed' || fail "s3_upload allowed a file outside the fence ($out)"
YCA_AUTO_CONFIRM=false
out=$(tool_dispatch s3_delete '{"key":"x"}' 2>&1 || true)
echo "$out" | grep -qi 'cancel\|confirm' || fail "s3_delete not gated ($out)"
YCA_AUTO_CONFIRM=true
url=$(YCA_TOOL_ARGS_JSON='{"key":"mykey","expires":600}' tool_s3_presign 2>&1 || true)
echo "$url" | grep -q 'X-Amz-Signature=' || fail "s3_presign missing signature ($url)"
echo "$url" | grep -q '/testbucket/mykey' || fail "s3_presign wrong path ($url)"
for t in s3_upload s3_download s3_delete s3_sync; do
    info="${YCA_TOOL_REGISTRY[$t]:-}"; [[ -n "$info" ]] || fail "$t not registered"
    IFS='|' read -r _fn dg _rest <<< "$info"
    danger_needs_confirm "$dg" || fail "$t tagged '$dg' — bypasses the gate"
done

echo "infra_actions_body OK"
