# tools/s3.sh — S3-compatible API client (curl + SigV4 via openssl)
# Disabled by default. Enable with: tools enable s3
# Requires: curl, openssl, awk, xxd
# Config: S3_ENDPOINT, S3_REGION, S3_BUCKET, S3_ACCESS_KEY, S3_SECRET_KEY (env)
# The Authorization header always goes through a header FILE (-H @<(...)): curl
# argv is world-readable via `ps`, so it must never carry credentials.
# Signing is PATH-STYLE (host = endpoint host, bucket in the path) so the request
# the caller sends is EXACTLY what was signed — works for AWS + S3-compatible
# (MinIO, etc.). NOTE: SigV4 here is verified by construction (internal
# consistency); it is not exercised against a live endpoint in the test suite.

# _s3_uri_encode STR -> RFC3986 encoding for SigV4 canonical form. Keeps
# A-Za-z0-9-._~ and '/', percent-encodes everything else.
_s3_uri_encode() {
    local s="$1" out="" c i
    for (( i=0; i<${#s}; i++ )); do
        c="${s:i:1}"
        case "$c" in
            [A-Za-z0-9._~/-]) out+="$c" ;;
            *) printf -v c '%%%02X' "'$c"; out+="$c" ;;
        esac
    done
    printf '%s' "$out"
}

# _s3_sign METHOD BUCKET KEY [CONTENT_TYPE] [BODY_FILE] [CANONICAL_QUERY]
# -> "auth|amzdate|payload_hash|host|canonical_uri"  (path-style)
_s3_sign() {
    local method="$1" bucket="$2" key="$3" content_type="${4:-application/octet-stream}" body_file="${5:-}" query="${6:-}"
    local endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local region="${S3_REGION:-us-east-1}"
    local access_key="${S3_ACCESS_KEY:?S3_ACCESS_KEY required}"
    local secret_key="${S3_SECRET_KEY:?S3_SECRET_KEY required}"
    local service="s3"
    local now date_short
    now=$(date -u '+%Y%m%dT%H%M%SZ'); date_short="${now%%T*}"

    # Path-style: host is the endpoint host; the bucket lives in the URI.
    local host="${endpoint#https://}"; host="${host#http://}"; host="${host%%/*}"

    local payload_hash="e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    [[ -n "$body_file" && -f "$body_file" ]] && payload_hash=$(openssl dgst -sha256 -hex "$body_file" 2>/dev/null | awk '{print $NF}')

    local canonical_uri="/$bucket"
    [[ -n "$key" ]] && canonical_uri="/$bucket/$(_s3_uri_encode "$key")"

    local canonical_headers="host:$host
x-amz-content-sha256:$payload_hash
x-amz-date:$now
"
    local signed_headers="host;x-amz-content-sha256;x-amz-date"
    local canonical_request="${method}
${canonical_uri}
${query}
${canonical_headers}
${signed_headers}
${payload_hash}"

    local scope="${date_short}/${region}/${service}/aws4_request"
    local string_to_sign="AWS4-HMAC-SHA256
${now}
${scope}
$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"

    local k_date k_region k_service k_signing signature
    k_date=$(printf '%s' "$date_short"  | openssl dgst -sha256 -mac HMAC -macopt "key:AWS4$secret_key" -binary 2>/dev/null | xxd -p -c 256)
    k_region=$(printf '%s' "$region"    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_date" -binary 2>/dev/null | xxd -p -c 256)
    k_service=$(printf '%s' "$service"  | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_region" -binary 2>/dev/null | xxd -p -c 256)
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_service" -hex 2>/dev/null | awk '{print $NF}')
    signature=$(printf '%s' "$string_to_sign" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_signing" -hex 2>/dev/null | awk '{print $NF}')

    local auth_header="AWS4-HMAC-SHA256 Credential=$access_key/$scope, SignedHeaders=$signed_headers, Signature=$signature"
    printf '%s|%s|%s|%s|%s' "$auth_header" "$now" "$payload_hash" "$host" "$canonical_uri"
}

# tool_s3_upload FILE [KEY] -> upload a (fence-confined) local file
tool_s3_upload() {
    local file key; file=$(tool_arg file "${1:-}"); key=$(tool_arg key "${2:-$(basename "$file")}")
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local signed auth now payload_hash host uri rc
    signed=$(_s3_sign PUT "$bucket" "$key" "application/octet-stream" "$file") || return 1
    IFS='|' read -r auth now payload_hash host uri <<< "$signed"
    curl_web --fail-with-body -X PUT --speed-limit 1024 --speed-time 30 \
        -H @<(printf 'Authorization: %s\n' "$auth") \
        -H "x-amz-content-sha256: $payload_hash" -H "x-amz-date: $now" \
        -T "$file" "$endpoint$uri" 2>/dev/null; rc=$?
    (( rc == 0 )) && printf 'uploaded %s to s3://%s/%s' "$file" "$bucket" "$key" \
        || { printf 'upload FAILED (curl rc=%d) — check S3_* env / bucket / key' "$rc"; return 1; }
}

# tool_s3_download KEY [FILE] -> download to a (fence-confined) local path
tool_s3_download() {
    local key file; key=$(tool_arg key "${1:-}"); [[ -n "$key" ]] || { printf 'key required'; return 1; }
    file=$(tool_arg file "${2:-$(basename "$key")}")
    path_check_allowed "$file" || { printf 'output path not allowed: %s' "$file"; return 1; }
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local signed auth now payload_hash host uri rc
    signed=$(_s3_sign GET "$bucket" "$key") || return 1
    IFS='|' read -r auth now payload_hash host uri <<< "$signed"
    curl_web --fail-with-body -o "$file" --speed-limit 1024 --speed-time 30 \
        -H @<(printf 'Authorization: %s\n' "$auth") \
        -H "x-amz-content-sha256: $payload_hash" -H "x-amz-date: $now" \
        "$endpoint$uri" 2>/dev/null; rc=$?
    (( rc == 0 )) && printf 'downloaded s3://%s/%s to %s' "$bucket" "$key" "$file" \
        || { printf 'download FAILED (curl rc=%d)' "$rc"; return 1; }
}

# tool_s3_list [PREFIX] -> list object keys
tool_s3_list() {
    local prefix; prefix=$(tool_arg prefix "${1:-}")
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local query=""; [[ -n "$prefix" ]] && query="prefix=$(_s3_uri_encode "$prefix")"
    local signed auth now payload_hash host uri
    signed=$(_s3_sign GET "$bucket" "" "" "" "$query") || return 1   # query now signed (was hardcoded "")
    IFS='|' read -r auth now payload_hash host uri <<< "$signed"
    curl_web --fail-with-body --max-time 60 --retry 2 --retry-connrefused \
        -H @<(printf 'Authorization: %s\n' "$auth") \
        -H "x-amz-content-sha256: $payload_hash" -H "x-amz-date: $now" \
        "$endpoint$uri${query:+?$query}" 2>/dev/null \
        | grep -oE '<Key>[^<]+</Key>' | sed 's/<[^>]*>//g'
}

# tool_s3_delete KEY  (gated + honest result)
tool_s3_delete() {
    local key; key=$(tool_arg key "${1:-}"); [[ -n "$key" ]] || { printf 'key required'; return 1; }
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    confirm_action "DELETE s3://$bucket/$key (permanent)" "s3 DELETE $key" || { confirm_denied_msg; return 1; }
    local signed auth now payload_hash host uri rc
    signed=$(_s3_sign DELETE "$bucket" "$key") || return 1
    IFS='|' read -r auth now payload_hash host uri <<< "$signed"
    curl_web --fail-with-body --max-time 60 -X DELETE \
        -H @<(printf 'Authorization: %s\n' "$auth") \
        -H "x-amz-content-sha256: $payload_hash" -H "x-amz-date: $now" \
        "$endpoint$uri" 2>/dev/null; rc=$?
    (( rc == 0 )) && printf 'deleted s3://%s/%s' "$bucket" "$key" \
        || { printf 'delete FAILED (curl rc=%d)' "$rc"; return 1; }
}

# tool_s3_object_info KEY -> object metadata
tool_s3_object_info() {
    local key; key=$(tool_arg key "${1:-}"); [[ -n "$key" ]] || { printf 'key required'; return 1; }
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local signed auth now payload_hash host uri
    signed=$(_s3_sign HEAD "$bucket" "$key") || return 1
    IFS='|' read -r auth now payload_hash host uri <<< "$signed"
    curl_web -I --max-time 30 --retry 2 --retry-connrefused \
        -H @<(printf 'Authorization: %s\n' "$auth") \
        -H "x-amz-content-sha256: $payload_hash" -H "x-amz-date: $now" \
        "$endpoint$uri" 2>/dev/null
}

# tool_s3_sync — mirror a local dir and a bucket prefix. direction=down copies
# objects under <prefix> into <dir>; direction=up uploads <dir>'s files under
# <prefix>. Composed from the signed list/get/put; local side is fence-confined
# and the whole op is confirmed once.
tool_s3_sync() {
    local dir prefix direction; dir=$(tool_arg dir "${1:-}"); prefix=$(tool_arg prefix); direction=$(tool_arg direction down)
    [[ -n "$dir" ]] || { printf 'dir required (local directory)'; return 1; }
    path_check_allowed "$dir" || { printf 'path not allowed: %s' "$dir"; return 1; }
    case "$direction" in up|down) ;; *) printf 'direction must be up|down'; return 1 ;; esac
    local bucket="${S3_BUCKET:?S3_BUCKET required}"
    confirm_action "S3 SYNC $direction: $dir <-> s3://$bucket/$prefix" "sync $direction" || { confirm_denied_msg; return 1; }
    local n=0
    if [[ "$direction" == down ]]; then
        path_ensure_dir "$dir"
        local key rel
        while IFS= read -r key; do
            [[ -z "$key" ]] && continue
            rel="${key#"$prefix"}"; rel="${rel#/}"; [[ -z "$rel" ]] && rel="$(basename "$key")"
            path_ensure_dir "$(dirname "$dir/$rel")"
            YCA_TOOL_ARGS_JSON='{}' tool_s3_download "$key" "$dir/$rel" >/dev/null 2>&1 && (( n++ ))
        done < <(YCA_TOOL_ARGS_JSON='{}' tool_s3_list "$prefix")
        printf 'synced %d object(s) down to %s' "$n" "$dir"
    else
        local f rel
        while IFS= read -r f; do
            rel="${f#"$dir"/}"
            YCA_TOOL_ARGS_JSON='{}' tool_s3_upload "$f" "${prefix:+$prefix/}$rel" >/dev/null 2>&1 && (( n++ ))
        done < <(find "$dir" -type f 2>/dev/null)
        printf 'synced %d file(s) up to s3://%s/%s' "$n" "$bucket" "$prefix"
    fi
}

# tool_s3_presign KEY [EXPIRES] -> a time-limited pre-signed GET URL (SigV4
# query-string auth). The output URL grants read access to the object until it
# expires — treat it as a secret.
tool_s3_presign() {
    local key expires; key=$(tool_arg key "${1:-}"); [[ -n "$key" ]] || { printf 'key required'; return 1; }
    expires=$(int_guard "$(tool_arg expires 3600)" 3600); (( expires > 604800 )) && expires=604800; (( expires < 1 )) && expires=1
    local bucket="${S3_BUCKET:?S3_BUCKET required}" endpoint="${S3_ENDPOINT:-https://s3.amazonaws.com}"
    local region="${S3_REGION:-us-east-1}" access_key="${S3_ACCESS_KEY:?S3_ACCESS_KEY required}" secret_key="${S3_SECRET_KEY:?S3_SECRET_KEY required}"
    local host="${endpoint#https://}"; host="${host#http://}"; host="${host%%/*}"
    local now date_short; now=$(date -u '+%Y%m%dT%H%M%SZ'); date_short="${now%%T*}"
    local scope="$date_short/$region/s3/aws4_request"
    local cred; cred=$(_s3_uri_encode "$access_key/$scope")
    local canonical_uri="/$bucket/$(_s3_uri_encode "$key")"
    local cq="X-Amz-Algorithm=AWS4-HMAC-SHA256&X-Amz-Credential=$cred&X-Amz-Date=$now&X-Amz-Expires=$expires&X-Amz-SignedHeaders=host"
    local canonical_request="GET
$canonical_uri
$cq
host:$host

host
UNSIGNED-PAYLOAD"
    local sts="AWS4-HMAC-SHA256
$now
$scope
$(printf '%s' "$canonical_request" | openssl dgst -sha256 -hex 2>/dev/null | awk '{print $NF}')"
    local k_date k_region k_service k_signing sig
    k_date=$(printf '%s' "$date_short"  | openssl dgst -sha256 -mac HMAC -macopt "key:AWS4$secret_key" -binary 2>/dev/null | xxd -p -c 256)
    k_region=$(printf '%s' "$region"    | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_date" -binary 2>/dev/null | xxd -p -c 256)
    k_service=$(printf '%s' "s3"        | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_region" -binary 2>/dev/null | xxd -p -c 256)
    k_signing=$(printf '%s' "aws4_request" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_service" -hex 2>/dev/null | awk '{print $NF}')
    sig=$(printf '%s' "$sts" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$k_signing" -hex 2>/dev/null | awk '{print $NF}')
    printf '%s%s?%s&X-Amz-Signature=%s' "$endpoint" "$canonical_uri" "$cq" "$sig"
}

tool_register "s3_upload"   tool_s3_upload   '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"key":{"type":"string","description":"the lookup key"}},"required":["file"]}' writes all s3
tool_register "s3_download" tool_s3_download '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"},"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["key"]}' writes all s3
tool_register "s3_list"     tool_s3_list     '{"type":"object","properties":{"prefix":{"type":"string","description":"the key or path prefix"}}}' safe all s3
tool_register "s3_delete"   tool_s3_delete   '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"}},"required":["key"]}' destructive all s3
tool_register "s3_object_info"     tool_s3_object_info     '{"type":"object","properties":{"key":{"type":"string","description":"the lookup key"}},"required":["key"]}' safe all s3
tool_register "s3_sync"     tool_s3_sync     '{"description":"Mirror a local dir <-> a bucket prefix (direction up|down) — gated","type":"object","properties":{"dir":{"type":"string","description":"directory path relative to the project root"},"prefix":{"type":"string","description":"the key or path prefix"},"direction":{"type":"string","enum":["up","down"],"description":"the direction"}},"required":["dir"]}' writes all s3
tool_register "s3_presign"  tool_s3_presign  '{"description":"Time-limited pre-signed GET URL (output is a secret)","type":"object","properties":{"key":{"type":"string","description":"the lookup key"},"expires":{"type":"integer","description":"the expires"}},"required":["key"]}' safe all s3
