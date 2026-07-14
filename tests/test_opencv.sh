#!/usr/bin/env bash
# Test: the opencv (Computer Vision / OpenCV 4.13) tool category — over MCP.
#
# Two tiers, so the suite is meaningful on any CI box:
#   1. Structural + guard tests that DO NOT need OpenCV installed — registration,
#      category gating, danger classification, schemas, path/arg guards.
#   2. End-to-end vision tests that DO need python3 + cv2 — only run when cv2 is
#      importable; otherwise skipped with a printed note (never a failure).
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
rm -f .harness.db
git init -q
git config user.email t@t
git config user.name t
echo a > a.txt; git add a.txt; git commit -qm init >/dev/null 2>&1

export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

fail() { echo "FAIL: $*"; exit 1; }

# cv TOOL [ARGS_JSON] [y] — one opencv tool call with the category enabled.
cv() { MCP_FLAGS="--enable opencv" mcp_call "$HARNESS" "opencv_$1" "${2:-}" "${3:-}"; }
grep_cv() { local pat="$1" t="$2" a="${3:-}" y="${4:-}" o; o=$(cv "$t" "$a" "$y") || true; grep -qi -- "$pat" <<<"$o"; }
jq_cv()   { local expr="$1" t="$2" a="${3:-}" y="${4:-}" o; o=$(cv "$t" "$a" "$y") || true; jq -e "$expr" <<<"$o" >/dev/null; }

# ── 1. Registration ──────────────────────────────────────────────────────────
REG=$(registry_dump "$PROJ_ROOT")
EXPECTED_TOOLS="doctor info detect_faces read_qr compare count_objects dominant_colors \
template_match detect_motion detect_edges threshold blur_faces denoise sharpen document_scan \
extract_frames stitch annotate llm_explain"
for t in $EXPECTED_TOOLS; do
    grep -q "^opencv_${t}|" <<<"$REG" || fail "opencv tool not registered: opencv_${t}"
done
NOPENCV=$(grep -c '|opencv|' <<<"$REG")
[[ "$NOPENCV" -ge 18 ]] || fail "opencv registers only $NOPENCV tools (expected >=18)"

# Category label is wired.
mcp_wf "$HARNESS" tools.status '{}' y | grep -qi opencv || fail "opencv category missing from tools.status"

# ── 2. Danger classification ─────────────────────────────────────────────────
for w in detect_edges threshold blur_faces denoise sharpen document_scan extract_frames stitch annotate; do
    grep -q "^opencv_${w}|writes|" <<<"$REG" || fail "opencv_${w} should be danger=writes"
done
for r in doctor info detect_faces read_qr compare count_objects dominant_colors template_match detect_motion; do
    grep -q "^opencv_${r}|safe|" <<<"$REG" || fail "opencv_${r} should be danger=safe"
done
grep -qE '^opencv_llm_explain\|[a-z]+\|[a-z]+\|mid$' <<<"$REG" \
    || fail "opencv_llm_explain should be complexity=mid"

# ── 3. Every opencv schema parses (a broken schema would poison the wire) ────
BADSCHEMA=$(YCA_DIR="$PROJ_ROOT" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  for n in "${!YCA_TOOL_SCHEMAS[@]}"; do
    [[ "$n" == opencv_* ]] || continue
    printf "%s" "${YCA_TOOL_SCHEMAS[$n]}" | jq -e . >/dev/null 2>&1 || echo "$n"
  done')
[[ -z "$BADSCHEMA" ]] || fail "opencv schemas are not valid JSON: $BADSCHEMA"

# ── 4. Category gating on the MCP dispatch path ──────────────────────────────
GATED=$(mcp_call "$HARNESS" opencv_info '{"file":"a.txt"}') && fail "opencv_info should be gated when category is off"
grep -qi 'disabled' <<<"$GATED" || fail "gate message should say disabled: $GATED"
mcp_wf "$HARNESS" tools.enable '{"category":"opencv"}' y >/dev/null || fail "tools.enable opencv failed"

# ── 5. Guards that run BEFORE the cv2 import (work without OpenCV) ────────────
touch "$TMP/img.png" "$TMP/img2.png"   # _cv_guard only checks path-allowed + exists

grep_cv 'not allowed' info '{"file":"/etc/hosts"}' || fail "info should reject an out-of-tree path"
grep_cv 'not found' info "{\"file\":\"$TMP/does_not_exist.png\"}" || fail "info should report a missing file"
grep_cv 'second image required' compare "{\"file\":\"$TMP/img.png\"}" || fail "compare should require a second image"
grep_cv 'template' template_match "{\"file\":\"$TMP/img.png\"}" || fail "template_match should require a template"

# ── 6. Doctor always runs and reports python3/opencv state ───────────────────
DOC=$(cv doctor) || true
grep -qiE 'python3|opencv|cv2' <<<"$DOC" || fail "opencv doctor produced no recognizable status: $DOC"

# ── 7. End-to-end vision tests (only when cv2 is importable) ──────────────────
if python3 -c 'import cv2' >/dev/null 2>&1; then
    python3 - "$TMP" <<'PY'
import sys, cv2, numpy as np
d = sys.argv[1]
img = np.full((240, 320, 3), 255, np.uint8)
for c in [(70, 70), (170, 110), (250, 180)]:
    cv2.circle(img, c, 25, (30, 30, 30), -1)
cv2.imwrite(f"{d}/base.png", img)
cv2.imwrite(f"{d}/same.png", img.copy())
cv2.imwrite(f"{d}/diff.png", np.zeros((240, 320, 3), np.uint8))
cv2.imwrite(f"{d}/tpl.png", img[45:95, 45:95])
enc = getattr(cv2, "QRCodeEncoder_create", None)
if enc:
    code = cv2.resize(enc().encode("YANTRA-CV"), (240, 240), interpolation=cv2.INTER_NEAREST)
    cv2.imwrite(f"{d}/qr.png", code)
vw = cv2.VideoWriter(f"{d}/clip.mp4", cv2.VideoWriter_fourcc(*"mp4v"), 10.0, (160, 160))
for i in range(24):
    fr = np.zeros((160, 160, 3), np.uint8)
    if i > 8:
        cv2.rectangle(fr, (i * 4, 40), (i * 4 + 15, 55), (255, 255, 255), -1)
    vw.write(fr)
vw.release()
print("fixtures ok")
PY
    [[ -f "$TMP/base.png" ]] || fail "cv2 fixtures were not created"

    jq_cv '.width==320 and .height==240 and .kind=="image"' info "{\"file\":\"$TMP/base.png\"}" \
        || fail "info JSON wrong for base.png"

    N=$(cv count_objects "{\"file\":\"$TMP/base.png\"}"); N=$(jq -r '.count' <<<"$N")
    [[ "$N" -eq 3 ]] || fail "count_objects expected 3, got $N"

    jq_cv '.identical==true' compare "{\"file\":\"$TMP/base.png\",\"other\":\"$TMP/same.png\"}" \
        || fail "compare(base,same) should be identical"
    jq_cv '.verdict=="different"' compare "{\"file\":\"$TMP/base.png\",\"other\":\"$TMP/diff.png\"}" \
        || fail "compare(base,diff) should be different"

    jq_cv '.matched==true' template_match "{\"file\":\"$TMP/base.png\",\"template\":\"$TMP/tpl.png\"}" \
        || fail "template_match should match its own crop"

    jq_cv '(.colors|length)==3' dominant_colors "{\"file\":\"$TMP/base.png\",\"k\":3}" \
        || fail "dominant_colors should return 3 colors"

    if [[ -f "$TMP/qr.png" ]]; then
        jq_cv '.codes[0].text=="YANTRA-CV"' read_qr "{\"file\":\"$TMP/qr.png\"}" \
            || fail "read_qr should decode the fixture QR payload"
    fi

    # Write ops create sibling outputs and never touch the source.
    cv detect_edges "{\"file\":\"$TMP/base.png\"}" y >/dev/null || true
    [[ -f "$TMP/base_edges.png" ]] || fail "detect_edges did not write base_edges.png"
    cv threshold "{\"file\":\"$TMP/base.png\",\"mode\":\"otsu\"}" y >/dev/null || true
    [[ -f "$TMP/base_thresh.png" ]] || fail "threshold did not write base_thresh.png"
    cv sharpen "{\"file\":\"$TMP/base.png\"}" y >/dev/null || true
    [[ -f "$TMP/base_sharp.png" ]] || fail "sharpen did not write base_sharp.png"
    cv document_scan "{\"file\":\"$TMP/base.png\"}" y >/dev/null || true
    [[ -f "$TMP/base_scan.png" ]] || fail "document_scan did not write base_scan.png"
    cv annotate "{\"file\":\"$TMP/base.png\",\"boxes\":[{\"x\":10,\"y\":10,\"w\":40,\"h\":40,\"label\":\"x\"}]}" y >/dev/null || true
    [[ -f "$TMP/base_annotated.png" ]] || fail "annotate did not write base_annotated.png"
    [[ -f "$TMP/base.png" ]] || fail "source image must be preserved by write ops"

    # annotate rejects malformed boxes (either the tool's own JSON guard or the
    # T7 schema validator — both are corrective, neither runs the tool).
    grep_cv 'valid JSON\|array' annotate "{\"file\":\"$TMP/base.png\",\"boxes\":\"nope\"}" y \
        || fail "annotate should reject invalid boxes"

    jq_cv '.kind=="video" and .frames>0' info "{\"file\":\"$TMP/clip.mp4\"}" \
        || fail "info should read the video clip"
    jq_cv '.motion_segments>=1' detect_motion "{\"file\":\"$TMP/clip.mp4\"}" \
        || fail "detect_motion should detect the moving rectangle"
    grep_cv 'extracted' extract_frames "{\"file\":\"$TMP/clip.mp4\",\"every\":8}" y \
        || fail "extract_frames should report extracted frames"
    ls "$TMP"/clip_frame_*.jpg >/dev/null 2>&1 || fail "extract_frames wrote no frames"

    grep -qi '4.13 floor' <<<"$DOC" || fail "doctor should evaluate the 4.13 floor when cv2 is present"

    echo "opencv OK (with cv2 end-to-end)"
else
    echo "opencv OK (structural; cv2 not installed, vision tests skipped)"
fi
exit 0
