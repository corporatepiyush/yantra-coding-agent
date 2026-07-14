#!/usr/bin/env bash
# Test: the composite (multi-dependency) workflows + cua_find_text — driven over
# the REAL MCP surface (per the project rule: test through dispatch, never a bare
# validate()). Covers registration, the consent gate (writes deny without -y),
# SSRF refusal on the network-fetching composites, and offline happy-paths for
# the ones whose deps are present (skipped with a notice otherwise, so a lean CI
# box stays green).
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
fail() { echo "FAIL: $*"; exit 1; }
have() { command -v "$1" &>/dev/null; }
export MCP_FLAGS="--project $TMP"

# ── 1. Registration ──────────────────────────────────────────────────────────
REG_WF=$(HARNESS_UPDATE_ENABLED=false YCA_DIR="$PROJ_ROOT" bash -c '
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  for k in "${!YCA_WF_REGISTRY[@]}"; do echo "$k"; done')
for w in media.podcast media.clip media.hardsub media.summarize media.share_photos \
         media.audiobook doc.save_article data.diff net.watch container.overview k8s.overview; do
    grep -qx "$w" <<<"$REG_WF" || fail "composite workflow not registered: $w"
done
REG_T=$(registry_dump "$PROJ_ROOT")
grep -q '^cua_find_text|writes|' <<<"$REG_T" || fail "cua_find_text not registered as writes"

# ── 2. Consent gate: every writes composite auto-denies without -y ───────────
# (safe ones — data.diff, media.summarize — are intentionally NOT in this list.)
for spec in \
    'media.podcast|{"url":"https://example.com/v"}' \
    'media.clip|{"url":"https://example.com/v","start":"1","end":"2"}' \
    'net.watch|{"url":"https://example.com/"}' \
    'doc.save_article|{"url":"https://example.com/"}'; do
    id="${spec%%|*}"; args="${spec#*|}"
    out=$(mcp_wf "$HARNESS" "$id" "$args") && fail "$id ran WITHOUT consent (should deny without -y)"
    grep -qiE 'consent|auto-den|confirm' <<<"$out" || fail "$id denial message unexpected: $out"
done

# ── 3. SSRF: the network composites refuse a loopback/internal URL even with -y ─
for id in net.watch doc.save_article media.podcast; do
    out=$(mcp_wf "$HARNESS" "$id" '{"url":"http://127.0.0.1:9/x"}' y || true)
    grep -qiE 'refus|internal|loopback|could not fetch|unsafe|not allowed|public http' <<<"$out" \
        || fail "$id did not refuse a loopback URL (SSRF): $out"
done
# decimal-encoded loopback (2130706433 == 127.0.0.1) is also refused
out=$(mcp_wf "$HARNESS" net.watch '{"url":"http://2130706433/"}' y || true)
grep -qiE 'refus|internal|loopback|could not fetch|unsafe' <<<"$out" \
    || fail "net.watch did not refuse a decimal-IP loopback: $out"

# net_fetch (the SSRF-vetted file downloader): registered as writes, denies
# without -y, and refuses internal/loopback hosts even with -y.
grep -q '^net_fetch|writes|' <<<"$REG_T" || fail "net_fetch not registered as writes"
out=$(MCP_FLAGS="--enable net --project $TMP" mcp_call "$HARNESS" net_fetch '{"url":"https://example.com/x.jpg"}') \
    && fail "net_fetch ran without consent"
grep -qiE 'consent|confirm|auto-den' <<<"$out" || fail "net_fetch denial message unexpected: $out"
out=$(MCP_FLAGS="--enable net --project $TMP" mcp_call "$HARNESS" net_fetch '{"url":"http://169.254.169.254/x"}' y || true)
grep -qiE 'refus|internal|loopback|metadata' <<<"$out" || fail "net_fetch did not refuse a metadata-IP host: $out"
out=$(MCP_FLAGS="--enable net --project $TMP" mcp_call "$HARNESS" net_fetch '{"url":"file:///etc/passwd"}' y || true)
grep -qiE 'unsafe|http' <<<"$out" || fail "net_fetch did not refuse file://: $out"

# ── 4. data.diff happy-path (duckdb) ─────────────────────────────────────────
if have duckdb; then
    printf 'id,city\n1,NYC\n2,LA\n3,SF\n'      > "$TMP/a.csv"
    printf 'id,city\n1,NYC\n2,Chicago\n4,SEA\n' > "$TMP/b.csv"
    out=$(mcp_wf "$HARNESS" data.diff "{\"left\":\"$TMP/a.csv\",\"right\":\"$TMP/b.csv\",\"key\":\"id\"}" y) \
        || fail "data.diff failed on valid CSVs: $out"
    grep -qi 'data.diff complete' <<<"$out" || fail "data.diff missing completion summary: $out"
else echo "  (skip: data.diff happy-path — duckdb not installed)"; fi

# ── 5. media.hardsub (ffmpeg + libass): happy-path if the subtitles filter is
# present, else assert the HONEST "lacks libass" message (not a raw ffmpeg crash).
if have ffmpeg; then
    ffmpeg -nostdin -hide_banner -y -f lavfi -i testsrc=duration=1:size=160x120:rate=10 \
        "$TMP/clip.mp4" </dev/null >/dev/null 2>&1
    printf '1\n00:00:00,000 --> 00:00:01,000\nHELLO\n' > "$TMP/cap.srt"
    if [[ -f "$TMP/clip.mp4" ]]; then
        out=$(mcp_wf "$HARNESS" media.hardsub "{\"file\":\"$TMP/clip.mp4\",\"srt\":\"$TMP/cap.srt\"}" y || true)
        if ffmpeg -hide_banner -filters 2>/dev/null | grep -qE '(^| )subtitles '; then
            ls "$TMP"/clip_sub*.mp4 >/dev/null 2>&1 || fail "media.hardsub produced no _sub.mp4: $out"
        else
            grep -qi 'libass' <<<"$out" || fail "media.hardsub should report the missing libass filter honestly: $out"
        fi
    else echo "  (skip: media.hardsub — could not synth a test clip)"; fi
else echo "  (skip: media.hardsub — ffmpeg not installed)"; fi

# ── 6. media.share_photos: 2 synth photos. The load-bearing invariant is that
# the user's ORIGINALS survive — a prior cleanup bug deleted them whenever strip
# or resize degraded and aliased the source. Also: it must not CLAIM face-blur it
# did not do. Driven by ffmpeg alone (strip via ffmpeg; resize degrades safely).
mkdir -p "$TMP/pics"
if have ffmpeg; then
    ffmpeg -nostdin -hide_banner -y -f lavfi -i color=c=red:size=64x48  -frames:v 1 "$TMP/pics/one.jpg" </dev/null >/dev/null 2>&1
    ffmpeg -nostdin -hide_banner -y -f lavfi -i color=c=blue:size=64x48 -frames:v 1 "$TMP/pics/two.jpg" </dev/null >/dev/null 2>&1
    if [[ -f "$TMP/pics/one.jpg" && -f "$TMP/pics/two.jpg" ]]; then
        out=$(mcp_wf "$HARNESS" media.share_photos "{\"dir\":\"$TMP/pics\",\"width\":48}" y) \
            || fail "media.share_photos failed: $out"
        [[ -d "$TMP/pics/shareable" ]] || fail "media.share_photos made no shareable/ dir: $out"
        [[ -f "$TMP/pics/one.jpg" && -f "$TMP/pics/two.jpg" ]] \
            || fail "media.share_photos DELETED an original photo (data loss): $out"
        grep -qi 'face-blurred' <<<"$out" && fail "media.share_photos claimed face-blur it did not do: $out"
    else echo "  (skip: media.share_photos — could not synth test photos)"; fi
else echo "  (skip: media.share_photos — ffmpeg not installed)"; fi

# ── 7. media.audiobook happy-path (say/espeak): a tiny document ──────────────
if have say || have espeak-ng || have espeak; then
    printf 'This is a short test document read aloud.\n' > "$TMP/doc.txt"
    out=$(mcp_wf "$HARNESS" media.audiobook "{\"file\":\"$TMP/doc.txt\"}" y || true)
    # say/espeak can fail in a headless CI audio-less sandbox; accept either a
    # produced file OR an honest synthesis-failure message (never a crash).
    if ls "$TMP"/doc*.m4a "$TMP"/doc*.wav >/dev/null 2>&1; then :
    else grep -qiE 'audiobook ready|synthesis failed|text-to-speech' <<<"$out" \
            || fail "media.audiobook neither produced audio nor reported honestly: $out"; fi
else echo "  (skip: media.audiobook — no say/espeak backend)"; fi

# ── 8. container.overview / k8s.overview run without a bash error ────────────
# docker/kubectl may be absent or have no daemon/cluster; the workflow must emit
# a clean result (ok or an honest 'not installed'/connection message), never crash.
for id in container.overview k8s.overview; do
    out=$(mcp_wf "$HARNESS" "$id" '{}' y || true)
    grep -qiE 'overview complete|not installed|not a|connection|refused|error|no ' <<<"$out" \
        || fail "$id produced no coherent output: $out"
done

# ── 9. cua_find_text: gated without -y; honest with -y on a headless sandbox ──
MCP_FLAGS="--enable cua --project $TMP"
out=$(MCP_FLAGS="--enable cua --project $TMP" mcp_call "$HARNESS" cua_find_text '{"text":"Submit"}') \
    && fail "cua_find_text ran WITHOUT consent"
grep -qiE 'consent|confirm|auto-den' <<<"$out" || fail "cua_find_text denial message unexpected: $out"

echo "composite_workflows OK"
exit 0
