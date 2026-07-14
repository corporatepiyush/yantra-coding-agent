# workflows/disk.sh — find and reclaim unnecessary disk usage. SAFETY-CRITICAL:
# this deletes real files, so every removal funnels through ONE guarded primitive
# (_disk_rm) that must pass several independent checks. It only ever removes
# regenerable things — package/build caches, stale temp, old backups, browser
# caches — and (only when you confirm) browsing history. It NEVER touches your
# documents, media, source, cookies, saved logins, localStorage, or bookmarks.
#
#   disk.scan  — map the largest dirs + reclaimable items. Reports only; deletes nothing.
#   disk.clean — the same scan, then ASK PERMISSION (confirm_action) per category.
#
# Inputs (optional): root (scan root, default $HOME), age_days (stale-temp age,
# default 3), include_builds ("true" to also offer node_modules/target/… ).

# ── size / format helpers ────────────────────────────────────────────────────
_disk_size_kib() { local total=0 p k; for p in "$@"; do [[ -e "$p" ]] || continue; k=$(du -sk "$p" 2>/dev/null | awk 'END{print $1+0}'); total=$((total + k)); done; printf '%s' "$total"; }
_disk_h() { awk -v k="${1:-0}" 'BEGIN{split("KiB MiB GiB TiB PiB",u," "); s=k; i=1; while(s>=1024&&i<5){s/=1024;i++} printf "%.1f %s", s, u[i]}'; }
_disk_row() { logmsg "$(printf '  %10s  %s' "$1" "$2")"; }
_disk_avail_kib() { df -k "$HOME" 2>/dev/null | awk 'NR==2{print $4+0}'; }
_disk_strip_private() { local x="$1"; [[ "$x" == /private/* ]] && x="${x#/private}"; printf '%s' "$x"; }

# ── SAFEGUARD 1: allowed roots ───────────────────────────────────────────────
# _disk_guard PATH -> 0 only if PATH is strictly under $HOME, $TMPDIR, or the
# Homebrew cache (never those roots themselves, never "/").
_disk_guard() {
    local p tmp h bc
    p=$(_disk_strip_private "$1")
    h=$(_disk_strip_private "$HOME")
    tmp=$(_disk_strip_private "${TMPDIR:-/tmp}"); tmp="${tmp%/}"
    bc=$(_disk_strip_private "${_DISK_BREW_CACHE:-}")
    [[ -z "$p" || "$p" == "/" || "$p" == "$h" ]] && return 1
    case "$p" in "$h"/?*|"$tmp"/?*) return 0 ;; esac
    [[ -n "$bc" && "$p" == "$bc"/?* ]] && return 0
    return 1
}

# ── SAFEGUARD 2: protected-path denylist ─────────────────────────────────────
# _disk_protected PATH -> 0 if PATH is a location that must NEVER be deleted:
# the home root, personal folders, and the cache/config/data/security ROOTS
# (so only their subdirs/contents are ever removable, never the whole thing).
_disk_protected() {
    local p h; p=$(_disk_strip_private "$1"); p="${p%/}"; h=$(_disk_strip_private "$HOME"); h="${h%/}"
    case "$p" in
        "$h") return 0 ;;
        "$h"/Documents|"$h"/Desktop|"$h"/Downloads|"$h"/Pictures|"$h"/Movies|"$h"/Music|"$h"/Public|"$h"/Applications|"$h"/Sites) return 0 ;;
        "$h"/Library|"$h"/Library/Application\ Support|"$h"/Library/Caches|"$h"/Library/Preferences|"$h"/Library/Mail|"$h"/Library/Messages|"$h"/Library/Keychains|"$h"/Library/CloudStorage) return 0 ;;
        "$h"/.ssh|"$h"/.gnupg|"$h"/.aws|"$h"/.kube|"$h"/.docker|"$h"/.config|"$h"/.local|"$h"/.local/share) return 0 ;;
        "$h"/.cache|"$h"/.npm|"$h"/.cargo|"$h"/.rustup|"$h"/.bun|"$h"/go|"$h"/.mozilla|"$h"/.gradle) return 0 ;;
    esac
    return 1
}

# ── SAFEGUARD 3: minimum depth (never a top-level dir under $HOME) ────────────
_disk_min_depth() {
    local p h; p=$(_disk_strip_private "$1"); h=$(_disk_strip_private "$HOME")
    case "$p" in
        "$h"/*) local rest="${p#"$h"/}"; [[ "$rest" == */* ]] || return 1 ;;  # >= 2 segments below $HOME
    esac
    return 0   # temp/brew-cache entries may be depth 1
}

# ── THE guarded deletion primitive — every removal goes through here ──────────
_disk_refuse() { logmsg "$(c_warn "  $SYM_WARN refused ($1): $2")"; }
_disk_rm() {
    local p="$1"
    [[ -n "$p" && "$p" == /* ]]        || { _disk_refuse "not absolute" "${p:-<empty>}"; return 1; }
    [[ -e "$p" ]]                      || return 0
    [[ -L "$p" ]]                      && { _disk_refuse "symlink" "$p"; return 1; }
    _disk_guard "$p"                   || { _disk_refuse "outside safe roots" "$p"; return 1; }
    _disk_protected "$p"               && { _disk_refuse "protected path" "$p"; return 1; }
    _disk_min_depth "$p"               || { _disk_refuse "too shallow" "$p"; return 1; }
    rm -rf -- "$p" 2>/dev/null && _DISK_RM_COUNT=$(( ${_DISK_RM_COUNT:-0} + 1 ))
}
# _disk_rm_contents DIR -> delete DIR's children (each via _disk_rm), keep DIR.
_disk_rm_contents() { local d="$1" c; for c in "$d"/* "$d"/.[!.]*; do [[ -e "$c" ]] && _disk_rm "$c"; done; }

# ── preflight: refuse to run in an obviously unsafe environment ──────────────
_disk_preflight() {
    if [[ -z "${HOME:-}" || "$HOME" == "/" || "$HOME" != /* ]]; then
        emit_error "500" "refusing: \$HOME is unset, '/', or not absolute"; return 1
    fi
    [[ -d "$HOME" ]] || { emit_error "500" "refusing: \$HOME is not a directory"; return 1; }
    return 0
}

# ── reclaimable cache buckets ────────────────────────────────────────────────
_disk_collect() {
    _DISK_BREW_CACHE=""; command -v brew >/dev/null 2>&1 && _DISK_BREW_CACHE=$(brew --cache 2>/dev/null)
    DISK_LABELS=(); DISK_PATHS=(); DISK_KIB=()
    _disk_add() {
        local label="$1"; shift; local existing=() p
        for p in "$@"; do [[ -e "$p" ]] && _disk_guard "$p" && existing+=("$p"); done
        [[ ${#existing[@]} -eq 0 ]] && return
        local k; k=$(_disk_size_kib "${existing[@]}"); [[ "${k:-0}" -lt 1024 ]] && return
        DISK_LABELS+=("$label"); DISK_PATHS+=("${existing[*]}"); DISK_KIB+=("$k")
    }
    _disk_add "User caches"          "$HOME/Library/Caches" "$HOME/.cache"
    _disk_add "npm cache"            "$HOME/.npm/_cacache"
    _disk_add "bun cache"            "$HOME/.bun/install/cache"
    _disk_add "cargo registry cache" "$HOME/.cargo/registry/cache" "$HOME/.cargo/registry/src"
    _disk_add "go module cache"      "$HOME/go/pkg/mod/cache/download"
    [[ -n "$_DISK_BREW_CACHE" ]] && _disk_add "Homebrew download cache" "$_DISK_BREW_CACHE/downloads"
}

_disk_stale_temp() {
    local tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}"; local days="${INPUT_age_days:-3}"
    DISK_TMP_LIST=(); local k=0 p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue; _disk_guard "$p" || continue
        DISK_TMP_LIST+=("$p"); k=$((k + $(du -sk "$p" 2>/dev/null | awk 'END{print $1+0}')))
    done < <(find "$tmp" -maxdepth 1 -mindepth 1 -mtime +"$days" 2>/dev/null)
    DISK_TMP_KIB=$k
}

# LARGE temp files REGARDLESS of age. The stale-temp pass only flags items older
# than age_days, so a runaway process that fills $TMPDIR with hundreds of GB in
# minutes (e.g. a hung test looping into a mktemp out.log) is invisible to it. This
# reports any temp FILE at/over a size threshold (default 1 GiB) no matter how new,
# so the single biggest disk-full cause we've actually hit is caught immediately.
# Report-only: a live process may still be writing one, so it never auto-deletes.
# Bounded: -size stats metadata only, and -maxdepth caps the walk.
_disk_large_temp() {
    local tmp="${TMPDIR:-/tmp}"; tmp="${tmp%/}"
    local mib="${INPUT_large_temp_mib:-1024}"
    DISK_LARGETMP_LIST=(); DISK_LARGETMP_KIB=0
    [[ "$mib" =~ ^[0-9]+$ && "$mib" -gt 0 ]] || mib=1024
    local p k
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue
        k=$(du -sk "$p" 2>/dev/null | awk 'END{print $1+0}')
        DISK_LARGETMP_LIST+=("$k"$'\t'"$p"); DISK_LARGETMP_KIB=$((DISK_LARGETMP_KIB + k))
    done < <(find "$tmp" -maxdepth 4 -type f -size +"${mib}"M 2>/dev/null)
}

_disk_bak_files() {
    DISK_BAK_LIST=(); local k=0 p
    while IFS= read -r p; do
        [[ -z "$p" ]] && continue; _disk_guard "$p" || continue
        DISK_BAK_LIST+=("$p"); k=$((k + $(du -sk "$p" 2>/dev/null | awk 'END{print $1+0}')))
    done < <(find "$YCA_PROJECT_DIR" -maxdepth 3 -type f -name '*.bak.*' 2>/dev/null)
    DISK_BAK_KIB=$k
}

# ── browsers: profile roots (Chromium family, macOS + Linux) ─────────────────
# Chrome, Brave, Chromium, Edge, Opera, Vivaldi. Each "<...>/*" expands to profile
# dirs (Default, Profile 1, …); the two bare Opera dirs cover its flat layout.
_disk_browser_profile_roots() {
cat <<ROOTS
$HOME/Library/Application Support/Google/Chrome/*
$HOME/Library/Application Support/BraveSoftware/Brave-Browser/*
$HOME/Library/Application Support/Chromium/*
$HOME/Library/Application Support/Microsoft Edge/*
$HOME/Library/Application Support/com.operasoftware.Opera/*
$HOME/Library/Application Support/com.operasoftware.Opera
$HOME/Library/Application Support/Vivaldi/*
$HOME/.config/google-chrome/*
$HOME/.config/BraveSoftware/Brave-Browser/*
$HOME/.config/chromium/*
$HOME/.config/microsoft-edge/*
$HOME/.config/opera/*
$HOME/.config/opera
$HOME/.config/vivaldi/*
ROOTS
}

# ── SAFEGUARD 4a: cache-subdir allowlist (browser CACHE — safe to delete) ────
_disk_is_cache_name() {
    case "$1" in
        Cache|"Code Cache"|GPUCache|DawnCache|DawnGraphiteCache|DawnWebGPUCache|ShaderCache|GrShaderCache|CacheStorage|ScriptCache) return 0 ;;
    esac
    return 1
}
# ── SAFEGUARD 4b: history-file allowlist (browser HISTORY — only on request) ──
_disk_is_history_name() {
    case "$1" in
        History|History-journal|History-wal|History-shm|"Visited Links"|"Top Sites"|"Top Sites-journal"|"Archived History"|"Archived History-journal") return 0 ;;
    esac
    return 1
}
# ── SAFEGUARD 4c: hard denylist — NEVER delete these (cookies/logins/etc.) ────
# A belt-and-suspenders check applied to every browser file before deletion; even
# if a glob or allowlist were wrong, these names can never be removed.
_disk_is_protected_name() {
    case "$1" in
        Cookies|Cookies-journal|"Login Data"|"Login Data-journal"|"Login Data For Account"|"Login Data For Account-journal") return 0 ;;
        "Web Data"|"Web Data-journal"|Bookmarks|Bookmarks.bak|Favicons|Favicons-journal) return 0 ;;
        Preferences|"Secure Preferences"|"Local State"|"Affiliation Database") return 0 ;;
        "Local Storage"|"Session Storage"|IndexedDB|"Local Extension Settings"|"Sync Data"|"Sync Extension Settings"|Extensions|"Extension State"|"Extension Rules"|"Managed Extension Settings") return 0 ;;
        Network|"Trust Tokens"|"Shared Dictionary"|WebStorage) return 0 ;;
    esac
    return 1
}

# Browser CACHE dirs: for each profile, only the allowlisted cache subdirs, and
# never a denylisted name. -> DISK_BROWSER_LIST + DISK_BROWSER_KIB.
_disk_collect_browser() {
    DISK_BROWSER_LIST=(); local root prof base f k=0
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        while IFS= read -r prof; do
            [[ -d "$prof" && ! -L "$prof" ]] || continue
            _disk_guard "$prof" || continue
            for base in Cache "Code Cache" GPUCache DawnCache DawnGraphiteCache DawnWebGPUCache ShaderCache GrShaderCache "Service Worker/CacheStorage" "Service Worker/ScriptCache"; do
                f="$prof/$base"; local leaf="${base##*/}"
                [[ -e "$f" && ! -L "$f" ]] || continue
                _disk_is_protected_name "$leaf" && continue      # denylist wins
                _disk_is_cache_name "$leaf"      || continue      # allowlist
                _disk_guard "$f" || continue
                DISK_BROWSER_LIST+=("$f"); k=$((k + $(du -sk "$f" 2>/dev/null | awk 'END{print $1+0}')))
            done
        done < <(compgen -G "$root" 2>/dev/null)
    done < <(_disk_browser_profile_roots)
    DISK_BROWSER_KIB=$k
}

# Browser HISTORY files: for each profile, only the allowlisted history basenames,
# never a denylisted one. -> DISK_HISTORY_LIST + DISK_HISTORY_KIB.
_disk_collect_browser_history() {
    DISK_HISTORY_LIST=(); local root prof base f k=0
    while IFS= read -r root; do
        [[ -z "$root" ]] && continue
        while IFS= read -r prof; do
            [[ -d "$prof" && ! -L "$prof" ]] || continue
            _disk_guard "$prof" || continue
            for base in History History-journal History-wal History-shm "Visited Links" "Top Sites" "Top Sites-journal" "Archived History" "Archived History-journal"; do
                f="$prof/$base"
                [[ -e "$f" && ! -L "$f" ]] || continue
                _disk_is_protected_name "$base" && continue      # never cookies/logins/localStorage
                _disk_is_history_name "$base"    || continue      # allowlist only
                _disk_guard "$f" || continue
                DISK_HISTORY_LIST+=("$f"); k=$((k + $(du -sk "$f" 2>/dev/null | awk 'END{print $1+0}')))
            done
        done < <(compgen -G "$root" 2>/dev/null)
    done < <(_disk_browser_profile_roots)
    DISK_HISTORY_KIB=$k
}

_disk_build_dirs() {
    local root="${INPUT_root:-$HOME}" d
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        printf '%s\t%s\n' "$(du -sk "$d" 2>/dev/null | awk 'END{print $1+0}')" "$d"
    done < <(find "$root" -maxdepth 8 -type d \
                \( -name node_modules -o -name target -o -name build -o -name dist \
                   -o -name .next -o -name __pycache__ -o -name .gradle -o -name DerivedData \) \
                -prune 2>/dev/null)
}

# NOTE: -k is REQUIRED. Without it macOS/BSD `du` reports 512-byte blocks, which
# _disk_h (which assumes KiB) would then render at 2× the real size.
_disk_top_dirs() { du -kx -d 2 "${INPUT_root:-$HOME}" 2>/dev/null | sort -rn | head -15; }

# ── disk.scan — report only ──────────────────────────────────────────────────
wf_disk_scan() {
    _disk_preflight || return 1
    local root="${INPUT_root:-$HOME}"
    logmsg "$(c_info "$SYM_INFO Scanning $root for reclaimable disk (this can take a while)…")"

    _disk_collect
    local reclaimable=0 i
    logmsg ""; logmsg "$(c_bold 'Reclaimable caches:')"
    for i in "${!DISK_LABELS[@]}"; do _disk_row "$(_disk_h "${DISK_KIB[$i]}")" "${DISK_LABELS[$i]}"; reclaimable=$((reclaimable + DISK_KIB[i])); done
    [[ ${#DISK_LABELS[@]} -eq 0 ]] && logmsg "  (none over 1 MiB)"

    local tmp_kib bak_kib
    _disk_stale_temp; tmp_kib=$DISK_TMP_KIB
    _disk_bak_files;  bak_kib=$DISK_BAK_KIB
    _disk_collect_browser
    _disk_collect_browser_history
    reclaimable=$((reclaimable + tmp_kib + bak_kib + DISK_BROWSER_KIB + DISK_HISTORY_KIB))
    logmsg ""
    _disk_row "$(_disk_h "$tmp_kib")" "Stale temp (> ${INPUT_age_days:-3} days in \$TMPDIR, ${#DISK_TMP_LIST[@]} item(s))"
    _disk_row "$(_disk_h "$bak_kib")" "Old .bak backups (${#DISK_BAK_LIST[@]} file(s))"
    _disk_row "$(_disk_h "$DISK_BROWSER_KIB")" "Browser caches (${#DISK_BROWSER_LIST[@]} dir(s), Chrome/Brave/Chromium/Edge/Opera/Vivaldi)"
    _disk_row "$(_disk_h "$DISK_HISTORY_KIB")" "Browser history (${#DISK_HISTORY_LIST[@]} file(s) — cookies/logins/localStorage kept)"

    # Large temp files regardless of age — the runaway-log case the age filter misses.
    _disk_large_temp
    if [[ ${#DISK_LARGETMP_LIST[@]} -gt 0 ]]; then
        logmsg ""
        logmsg "$(c_warn "$SYM_WARN Large temp files (≥ ${INPUT_large_temp_mib:-1024} MiB, ANY age — possible runaway; report only):")"
        printf '%s\n' "${DISK_LARGETMP_LIST[@]}" | sort -rn | head -15 | while IFS=$'\t' read -r k p; do _disk_row "$(_disk_h "$k")" "$p"; done
        logmsg "$(c_dim "    a live process may still be writing one — check 'lsof <file>' before deleting")"
    fi

    logmsg ""; logmsg "$(c_bold 'Regenerable build/dep dirs (report only):')"
    _disk_build_dirs | sort -rn | head -15 | while IFS=$'\t' read -r k p; do _disk_row "$(_disk_h "$k")" "$p"; done
    logmsg ""; logmsg "$(c_bold 'Largest directories:')"
    _disk_top_dirs | while read -r k p; do _disk_row "$(_disk_h "$k")" "$p"; done

    local ltmp_h; ltmp_h=$(_disk_h "${DISK_LARGETMP_KIB:-0}")
    emit result "$(jq -n --arg r "$(_disk_h "$reclaimable")" --argjson kib "$reclaimable" \
        --argjson caches "${#DISK_LABELS[@]}" --argjson tmp "${#DISK_TMP_LIST[@]}" \
        --argjson bcache "${#DISK_BROWSER_LIST[@]}" --argjson bhist "${#DISK_HISTORY_LIST[@]}" \
        --argjson ltmp "${#DISK_LARGETMP_LIST[@]}" --argjson ltmpkib "${DISK_LARGETMP_KIB:-0}" --arg ltmph "$ltmp_h" \
        '{ok:true,summary:("~"+$r+" reclaimable"+(if $ltmp>0 then "; "+($ltmp|tostring)+" large temp file(s) ("+$ltmph+") — investigate" else "" end)),
          data:{reclaimable_kib:$kib,reclaimable_human:$r,cache_buckets:$caches,stale_temp_items:$tmp,
                browser_cache_dirs:$bcache,browser_history_files:$bhist,
                large_temp_files:$ltmp,large_temp_kib:$ltmpkib,large_temp_human:$ltmph,
                note:"run disk.clean to delete (asks permission per category); large_temp_files are report-only — check lsof before deleting"}}')"
}

# ── disk.clean — scan, then confirm + delete per category ────────────────────
wf_disk_clean() {
    _disk_preflight || return 1
    local before after freed i; _DISK_RM_COUNT=0
    before=$(_disk_avail_kib)

    _disk_collect
    local tmp_kib bak_kib
    _disk_stale_temp; tmp_kib=$DISK_TMP_KIB
    _disk_bak_files;  bak_kib=$DISK_BAK_KIB

    # Cache buckets. For a protected ROOT (e.g. ~/.cache) we delete its CONTENTS,
    # never the dir itself; deeper cache subdirs are removed directly. All via _disk_rm.
    for i in "${!DISK_LABELS[@]}"; do
        local label="${DISK_LABELS[$i]}" paths="${DISK_PATHS[$i]}" sz; sz=$(_disk_h "${DISK_KIB[$i]}")
        if confirm_action "Delete ${label} — ${sz}" "clear ${paths}"; then
            local p; for p in $paths; do
                if _disk_protected "$p"; then _disk_rm_contents "$p"; else _disk_rm "$p"; fi
            done
            logmsg "$(c_ok "$SYM_OK cleared ${label} (${sz})")"
        else
            logmsg "$(c_dim "  skipped ${label}")"
        fi
    done

    if [[ ${#DISK_TMP_LIST[@]} -gt 0 ]] && confirm_action "Delete ${#DISK_TMP_LIST[@]} stale \$TMPDIR item(s) — $(_disk_h "$tmp_kib")" "rm stale temp"; then
        local p; for p in "${DISK_TMP_LIST[@]}"; do _disk_rm "$p"; done
        logmsg "$(c_ok "$SYM_OK removed stale temp ($(_disk_h "$tmp_kib"))")"
    fi

    if [[ ${#DISK_BAK_LIST[@]} -gt 0 ]] && confirm_action "Delete ${#DISK_BAK_LIST[@]} old .bak file(s) — $(_disk_h "$bak_kib")" "rm *.bak.*"; then
        local p; for p in "${DISK_BAK_LIST[@]}"; do _disk_rm "$p"; done
        logmsg "$(c_ok "$SYM_OK removed old backups")"
    fi

    # Browser CACHES (safe/regenerable).
    _disk_collect_browser
    if [[ ${#DISK_BROWSER_LIST[@]} -gt 0 ]] && confirm_action "Delete ${#DISK_BROWSER_LIST[@]} browser cache dir(s) — $(_disk_h "$DISK_BROWSER_KIB")" "rm browser caches"; then
        local p; for p in "${DISK_BROWSER_LIST[@]}"; do _disk_rm "$p"; done
        logmsg "$(c_ok "$SYM_OK removed browser caches ($(_disk_h "$DISK_BROWSER_KIB"))")"
    fi

    # Browser HISTORY (user data — its own explicit confirm; cookies/logins/localStorage kept).
    _disk_collect_browser_history
    if [[ ${#DISK_HISTORY_LIST[@]} -gt 0 ]] && confirm_action "Delete browsing HISTORY — ${#DISK_HISTORY_LIST[@]} file(s), $(_disk_h "$DISK_HISTORY_KIB")  (cookies, saved logins, localStorage & bookmarks are KEPT)" "rm history files"; then
        local p; for p in "${DISK_HISTORY_LIST[@]}"; do _disk_rm "$p"; done
        logmsg "$(c_ok "$SYM_OK removed browsing history ($(_disk_h "$DISK_HISTORY_KIB"))")"
    fi

    # Build/dep dirs — only if explicitly opted in.
    if [[ "${INPUT_include_builds:-}" == "true" ]]; then
        local builds; builds=$(_disk_build_dirs | sort -rn)
        if [[ -n "$builds" ]]; then
            local bk cnt; bk=$(printf '%s\n' "$builds" | awk '{s+=$1} END{print s+0}'); cnt=$(printf '%s\n' "$builds" | grep -c .)
            if confirm_action "Delete ${cnt} regenerable build dir(s) (node_modules/target/…) — $(_disk_h "$bk")" "rm build dirs"; then
                printf '%s\n' "$builds" | while IFS=$'\t' read -r k p; do _disk_rm "$p"; done
                logmsg "$(c_ok "$SYM_OK removed build dirs ($(_disk_h "$bk"))")"
            fi
        fi
    fi

    after=$(_disk_avail_kib); freed=$((after - before)); (( freed < 0 )) && freed=0
    emit result "$(jq -n --arg f "$(_disk_h "$freed")" --argjson kib "$freed" --argjson n "${_DISK_RM_COUNT:-0}" \
        '{ok:true,summary:("freed "+$f),data:{freed_kib:$kib,freed_human:$f,items_removed:$n}}')"
}

wf_register "disk.scan"  wf_disk_scan  1 safe   "" "Find reclaimable disk (caches, stale temp, browser cache/history, build dirs) — report only"
wf_register "disk.clean" wf_disk_clean 1 writes "" "Reclaim disk: ask permission per category, then delete (guarded)"
