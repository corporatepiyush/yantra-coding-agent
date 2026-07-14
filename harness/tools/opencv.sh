# tools/opencv.sh — Computer Vision tools (OpenCV 4.13, via python3 + cv2).
#
# The same "shell out to a proven binary" discipline the media category uses for
# ffmpeg, applied to OpenCV: every call is a small, self-contained python3
# snippet that imports cv2, does ONE well-scoped vision task, and prints a result
# (JSON for read-only analysis, a sibling output file for transforms). Derived
# outputs never overwrite their source and must stay inside the allowed tree.
#
# The calls chosen here are the ones that recur across industries — manufacturing
# QC (edges/compare/count/template), logistics & retail (qr/dominant_colors),
# security & surveillance (faces/motion/blur_faces), finance & insurance doc
# intake (document_scan/threshold), medical & low-light imaging (denoise), and
# drone/real-estate capture (stitch/extract_frames) — not a full OpenCV mirror.

# ── Availability / guards ────────────────────────────────────────────────────
_cv_missing() {
    printf 'opencv unavailable: python3 with the cv2 module (OpenCV) was not found\ninstall: pip install "opencv-python>=4.13" numpy   (or opencv-contrib-python for barcode/QR extras)'
}

# _cv_available — true only when python3 exists AND `import cv2` succeeds.
_cv_available() {
    command -v python3 &>/dev/null || return 1
    python3 -c 'import cv2' &>/dev/null
}

_cv_guard() {
    local file="$1"
    [[ -n "$file" ]] || { printf 'file required'; return 1; }
    path_check_allowed "$file" 2>/dev/null || { printf 'path not allowed: %s' "$file"; return 1; }
    [[ -f "$file" ]] || { printf 'file not found: %s' "$file"; return 1; }
}

# _cv_out FILE SUFFIX EXT -> sibling output path, verified writable in-tree.
_cv_out() {
    local file="$1" suffix="$2" ext="$3"
    local out="${file%.*}${suffix}.${ext}"
    path_check_allowed "$out" 2>/dev/null || { printf ''; return 1; }
    printf '%s' "$out"
}

# ── doctor — is OpenCV present and does it meet the 4.13 floor? ───────────────
tool_opencv_doctor() {
    if ! command -v python3 &>/dev/null; then
        printf 'python3: not installed\ninstall: brew install python  /  apt install python3'
        return 1
    fi
    if ! python3 -c 'import cv2' &>/dev/null; then
        printf 'python3: ok\ncv2 (OpenCV): not importable\n'; _cv_missing; return 1
    fi
    python3 - <<'PY'
import cv2
v = cv2.__version__
parts = []
for p in v.split('.'):
    n = ''.join(ch for ch in p if ch.isdigit())
    parts.append(int(n) if n else 0)
parts += [0, 0]
major, minor = parts[0], parts[1]
floor = (4, 13)
meets = (major, minor) >= floor
print(f"python3: ok")
print(f"cv2 (OpenCV): ok  version={v}")
print(f"4.13 floor: {'met' if meets else 'BELOW — some calls still work, upgrade with: pip install --upgrade \"opencv-python>=4.13\"'}")
try:
    import numpy as np
    print(f"numpy: ok  version={np.__version__}")
except Exception:
    print("numpy: MISSING — install: pip install numpy")
# Optional contrib features used by read_qr's barcode fallback.
print(f"barcode detector: {'ok' if hasattr(cv2, 'barcode') else 'absent (QR still works; pip install opencv-contrib-python for 1D barcodes)'}")
PY
}

# ── info — dimensions, channels, dtype (image) or fps/frames (video) ─────────
# Retail/medical/QC: know what you are looking at before you process it.
tool_opencv_info() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    python3 - "$file" <<'PY' 2>&1
import sys, os, json, cv2
src = sys.argv[1]
ext = os.path.splitext(src)[1].lower()
video = ext in ('.mp4', '.mov', '.mkv', '.webm', '.avi', '.m4v')
info = {"path": src, "bytes": os.path.getsize(src)}
if video:
    cap = cv2.VideoCapture(src)
    if not cap.isOpened():
        sys.exit("cannot open video: " + src)
    info.update({
        "kind": "video",
        "width": int(cap.get(cv2.CAP_PROP_FRAME_WIDTH)),
        "height": int(cap.get(cv2.CAP_PROP_FRAME_HEIGHT)),
        "fps": round(cap.get(cv2.CAP_PROP_FPS), 3),
        "frames": int(cap.get(cv2.CAP_PROP_FRAME_COUNT)),
    })
    fps = info["fps"] or 0
    info["duration_s"] = round(info["frames"] / fps, 2) if fps else None
    cap.release()
else:
    img = cv2.imread(src, cv2.IMREAD_UNCHANGED)
    if img is None:
        sys.exit("cannot read image: " + src)
    h, w = img.shape[:2]
    info.update({
        "kind": "image",
        "width": w, "height": h,
        "channels": 1 if img.ndim == 2 else img.shape[2],
        "dtype": str(img.dtype),
        "megapixels": round(w * h / 1e6, 3),
    })
print(json.dumps(info, indent=2))
PY
}

# ── detect_faces — count + bounding boxes (JSON). Read-only. ─────────────────
# Security/access control, retail footfall analytics, photo tooling.
tool_opencv_detect_faces() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    python3 - "$file" <<'PY' 2>&1
import sys, os, json, cv2
def _cascade():
    d = getattr(getattr(cv2, "data", None), "haarcascades", None)
    for c in ([os.path.join(d, "haarcascade_frontalface_default.xml")] if d else []) + \
             [os.path.join(os.path.dirname(cv2.__file__), "data", "haarcascade_frontalface_default.xml")]:
        if os.path.exists(c):
            return c
    return None
src = sys.argv[1]
img = cv2.imread(src)
if img is None:
    sys.exit("cannot read image: " + src)
cp = _cascade()
if not cp:
    sys.exit("haarcascade data not found; install a full build: pip install opencv-contrib-python")
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
cascade = cv2.CascadeClassifier(cp)
faces = cascade.detectMultiScale(gray, scaleFactor=1.1, minNeighbors=5, minSize=(30, 30))
boxes = [{"x": int(x), "y": int(y), "w": int(w), "h": int(h)} for (x, y, w, h) in faces]
print(json.dumps({"faces": len(boxes), "boxes": boxes}, indent=2))
PY
}

# ── read_qr — decode QR codes (and 1D barcodes when contrib present). ─────────
# Logistics, retail checkout/inventory, manufacturing part tracking. Read-only.
tool_opencv_read_qr() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    python3 - "$file" <<'PY' 2>&1
import sys, json, cv2
src = sys.argv[1]
img = cv2.imread(src)
if img is None:
    sys.exit("cannot read image: " + src)
results = []
qr = cv2.QRCodeDetector()
try:
    ok, decoded, points, _ = qr.detectAndDecodeMulti(img)
    if ok:
        for text in decoded:
            if text:
                results.append({"type": "qr", "text": text})
except Exception:
    text, points, _ = qr.detectAndDecode(img)
    if text:
        results.append({"type": "qr", "text": text})
if not results and hasattr(cv2, "barcode"):
    try:
        bd = cv2.barcode.BarcodeDetector()
        ok, decoded, types, _ = bd.detectAndDecode(img)
        if ok:
            for t, ty in zip(decoded, types):
                if t:
                    results.append({"type": str(ty) or "barcode", "text": t})
    except Exception:
        pass
print(json.dumps({"count": len(results), "codes": results}, indent=2))
PY
}

# ── compare — similarity between two images (SSIM + mean abs diff). ──────────
# QC (golden-sample vs part), surveillance/change detection, doc de-dup. Read-only.
tool_opencv_compare() {
    local a="$1" b
    _cv_guard "$a" || return 1
    b=$(tool_arg other)
    [[ -n "$b" && "$b" != "null" ]] || { printf 'second image required: --other PATH'; return 1; }
    _cv_guard "$b" || return 1
    _cv_available || { _cv_missing; return 1; }
    python3 - "$a" "$b" <<'PY' 2>&1
import sys, json, cv2, numpy as np
a = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
b = cv2.imread(sys.argv[2], cv2.IMREAD_GRAYSCALE)
if a is None or b is None:
    sys.exit("cannot read one of the images")
if a.shape != b.shape:
    b = cv2.resize(b, (a.shape[1], a.shape[0]))
a = a.astype(np.float64); b = b.astype(np.float64)
# Global SSIM (no windowing — fast, good enough for change detection).
mu_a, mu_b = a.mean(), b.mean()
va, vb = a.var(), b.var()
cov = ((a - mu_a) * (b - mu_b)).mean()
c1, c2 = (0.01 * 255) ** 2, (0.03 * 255) ** 2
ssim = ((2 * mu_a * mu_b + c1) * (2 * cov + c2)) / ((mu_a**2 + mu_b**2 + c1) * (va + vb + c2))
mad = float(np.abs(a - b).mean())
print(json.dumps({
    "ssim": round(float(ssim), 4),
    "mean_abs_diff": round(mad, 3),
    "identical": bool(mad == 0.0),
    "verdict": "identical" if mad == 0 else ("very similar" if ssim > 0.95 else ("similar" if ssim > 0.8 else "different")),
}, indent=2))
PY
}

# ── count_objects — contour count above an area threshold. Read-only. ────────
# Agriculture (fruit/cell counts), manufacturing (parts on a belt), inventory.
tool_opencv_count_objects() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local minarea; minarea=$(int_guard "$(tool_arg min_area 100)" 100)
    python3 - "$file" "$minarea" <<'PY' 2>&1
import sys, json, cv2
src, min_area = sys.argv[1], int(sys.argv[2])
img = cv2.imread(src, cv2.IMREAD_GRAYSCALE)
if img is None:
    sys.exit("cannot read image: " + src)
img = cv2.GaussianBlur(img, (5, 5), 0)
_, th = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
# Objects are the minority region; if foreground covers >half the frame the
# polarity is inverted (light objects on dark bg, or vice versa) — flip it.
if (th > 0).mean() > 0.5:
    th = cv2.bitwise_not(th)
contours, _ = cv2.findContours(th, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
kept = [c for c in contours if cv2.contourArea(c) >= min_area]
areas = sorted((round(cv2.contourArea(c), 1) for c in kept), reverse=True)
print(json.dumps({"count": len(kept), "min_area": min_area, "areas_top": areas[:20]}, indent=2))
PY
}

# ── dominant_colors — top-K colors via k-means (retail/fashion/agri ripeness). ─
tool_opencv_dominant_colors() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local k; k=$(int_guard "$(tool_arg k 5)" 5)
    python3 - "$file" "$k" <<'PY' 2>&1
import sys, json, cv2, numpy as np
src, k = sys.argv[1], max(1, min(12, int(sys.argv[2])))
img = cv2.imread(src)
if img is None:
    sys.exit("cannot read image: " + src)
img = cv2.resize(img, (200, 200))  # speed: colors are scale-invariant
data = img.reshape(-1, 3).astype(np.float32)
criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 20, 1.0)
_, labels, centers = cv2.kmeans(data, k, None, criteria, 3, cv2.KMEANS_PP_CENTERS)
counts = np.bincount(labels.flatten(), minlength=k)
order = np.argsort(-counts)
total = float(counts.sum())
out = []
for i in order:
    b, g, r = centers[i].astype(int)
    out.append({"hex": "#%02x%02x%02x" % (r, g, b), "rgb": [int(r), int(g), int(b)],
                "share": round(float(counts[i]) / total, 4)})
print(json.dumps({"k": k, "colors": out}, indent=2))
PY
}

# ── template_match — find a sub-image; return best location + score. ─────────
# Factory automation, UI/screenshot testing, "is this logo/part present?". Read-only.
tool_opencv_template_match() {
    local file="$1"; _cv_guard "$file" || return 1
    local tpl; tpl=$(tool_arg template)
    [[ -n "$tpl" && "$tpl" != "null" ]] || { printf 'template (path) required: --template PATH'; return 1; }
    _cv_guard "$tpl" || return 1
    _cv_available || { _cv_missing; return 1; }
    local thr; thr=$(tool_arg threshold 0.8)
    python3 - "$file" "$tpl" "$thr" <<'PY' 2>&1
import sys, json, cv2, numpy as np
img = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
tpl = cv2.imread(sys.argv[2], cv2.IMREAD_GRAYSCALE)
thr = float(sys.argv[3])
if img is None or tpl is None:
    sys.exit("cannot read image or template")
if tpl.shape[0] > img.shape[0] or tpl.shape[1] > img.shape[1]:
    sys.exit("template is larger than the image")
res = cv2.matchTemplate(img, tpl, cv2.TM_CCOEFF_NORMED)
_, max_val, _, max_loc = cv2.minMaxLoc(res)
h, w = tpl.shape[:2]
ys, xs = np.where(res >= thr)
print(json.dumps({
    "best_score": round(float(max_val), 4),
    "matched": bool(max_val >= thr),
    "best_box": {"x": int(max_loc[0]), "y": int(max_loc[1]), "w": int(w), "h": int(h)},
    "match_count": int(len(xs)),
    "threshold": thr,
}, indent=2))
PY
}

# ── motion — detect motion across a video; report frames/timestamps. ─────────
# Security/surveillance, wildlife/agri camera traps, "trim dead footage". Read-only.
tool_opencv_detect_motion() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local sens; sens=$(int_guard "$(tool_arg sensitivity 25)" 25)
    python3 - "$file" "$sens" <<'PY' 2>&1
import sys, json, cv2
cap = cv2.VideoCapture(sys.argv[1])
if not cap.isOpened():
    sys.exit("cannot open video: " + sys.argv[1])
thresh = int(sys.argv[2])
fps = cap.get(cv2.CAP_PROP_FPS) or 25.0
prev = None
events = []
idx = 0
active = False
while True:
    ok, frame = cap.read()
    if not ok:
        break
    gray = cv2.GaussianBlur(cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY), (21, 21), 0)
    if prev is not None:
        delta = cv2.absdiff(prev, gray)
        _, mask = cv2.threshold(delta, thresh, 255, cv2.THRESH_BINARY)
        moving = (int(mask.sum()) / 255) > (mask.size * 0.01)  # >1% of pixels changed
        if moving and not active:
            events.append({"start_s": round(idx / fps, 2)})
            active = True
        elif not moving and active:
            events[-1]["end_s"] = round(idx / fps, 2)
            active = False
    prev = gray
    idx += 1
if active and events:
    events[-1]["end_s"] = round(idx / fps, 2)
cap.release()
print(json.dumps({"frames": idx, "fps": round(fps, 2), "motion_segments": len(events), "events": events[:50]}, indent=2))
PY
}

# ── edges — Canny edge map. Writes a sibling PNG. ────────────────────────────
# Inspection/QC, part outline extraction, feature prep.
tool_opencv_detect_edges() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out lo hi
    out=$(_cv_out "$file" "_edges" "png") || { printf 'output path not allowed'; return 1; }
    lo=$(int_guard "$(tool_arg low 100)" 100); hi=$(int_guard "$(tool_arg high 200)" 200)
    python3 - "$file" "$out" "$lo" "$hi" <<'PY' 2>&1
import sys, cv2
img = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
edges = cv2.Canny(img, int(sys.argv[3]), int(sys.argv[4]))
if not cv2.imwrite(sys.argv[2], edges):
    sys.exit("cannot write: " + sys.argv[2])
print("edges: " + sys.argv[2])
PY
}

# ── threshold — adaptive/Otsu binarization (OCR prep, defect isolation). ─────
tool_opencv_threshold() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out mode; out=$(_cv_out "$file" "_thresh" "png") || { printf 'output path not allowed'; return 1; }
    mode=$(tool_arg mode adaptive)
    python3 - "$file" "$out" "$mode" <<'PY' 2>&1
import sys, cv2
img = cv2.imread(sys.argv[1], cv2.IMREAD_GRAYSCALE)
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
mode = sys.argv[3]
if mode == "otsu":
    _, out = cv2.threshold(img, 0, 255, cv2.THRESH_BINARY + cv2.THRESH_OTSU)
else:
    out = cv2.adaptiveThreshold(img, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 10)
if not cv2.imwrite(sys.argv[2], out):
    sys.exit("cannot write: " + sys.argv[2])
print("threshold(%s): %s" % (mode, sys.argv[2]))
PY
}

# ── blur_faces — detect faces and Gaussian-blur them (privacy/GDPR). Writes. ─
tool_opencv_blur_faces() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out; out=$(_cv_out "$file" "_redacted" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    python3 - "$file" "$out" <<'PY' 2>&1
import sys, os, cv2
def _cascade():
    d = getattr(getattr(cv2, "data", None), "haarcascades", None)
    for c in ([os.path.join(d, "haarcascade_frontalface_default.xml")] if d else []) + \
             [os.path.join(os.path.dirname(cv2.__file__), "data", "haarcascade_frontalface_default.xml")]:
        if os.path.exists(c):
            return c
    return None
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
cp = _cascade()
if not cp:
    sys.exit("haarcascade data not found; install a full build: pip install opencv-contrib-python")
gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
cascade = cv2.CascadeClassifier(cp)
faces = cascade.detectMultiScale(gray, 1.1, 5, minSize=(30, 30))
for (x, y, w, h) in faces:
    roi = img[y:y+h, x:x+w]
    k = max(15, (w // 3) | 1)  # odd kernel proportional to face size
    img[y:y+h, x:x+w] = cv2.GaussianBlur(roi, (k, k), 0)
if not cv2.imwrite(sys.argv[2], img):
    sys.exit("cannot write: " + sys.argv[2])
print("redacted %d face(s): %s" % (len(faces), sys.argv[2]))
PY
}

# ── denoise — Non-Local-Means denoise (medical, low-light security). Writes. ─
tool_opencv_denoise() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out strength; out=$(_cv_out "$file" "_denoised" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    strength=$(int_guard "$(tool_arg strength 10)" 10)
    python3 - "$file" "$out" "$strength" <<'PY' 2>&1
import sys, cv2
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
h = float(sys.argv[3])
out = cv2.fastNlMeansDenoisingColored(img, None, h, h, 7, 21) if img.ndim == 3 else cv2.fastNlMeansDenoising(img, None, h, 7, 21)
if not cv2.imwrite(sys.argv[2], out):
    sys.exit("cannot write: " + sys.argv[2])
print("denoised: " + sys.argv[2])
PY
}

# ── sharpen — unsharp mask (scans, blurry captures). Writes. ─────────────────
tool_opencv_sharpen() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out; out=$(_cv_out "$file" "_sharp" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    python3 - "$file" "$out" <<'PY' 2>&1
import sys, cv2
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
blur = cv2.GaussianBlur(img, (0, 0), 3)
out = cv2.addWeighted(img, 1.5, blur, -0.5, 0)
if not cv2.imwrite(sys.argv[2], out):
    sys.exit("cannot write: " + sys.argv[2])
print("sharpened: " + sys.argv[2])
PY
}

# ── document_scan — find the page, warp to a flat top-down B/W scan. Writes. ─
# Finance/insurance/logistics: turn a phone photo of a form into a clean scan.
tool_opencv_document_scan() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local out; out=$(_cv_out "$file" "_scan" "png") || { printf 'output path not allowed'; return 1; }
    python3 - "$file" "$out" <<'PY' 2>&1
import sys, cv2, numpy as np
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
ratio = img.shape[0] / 500.0
small = cv2.resize(img, (int(img.shape[1] / ratio), 500))
gray = cv2.GaussianBlur(cv2.cvtColor(small, cv2.COLOR_BGR2GRAY), (5, 5), 0)
edged = cv2.Canny(gray, 75, 200)
contours, _ = cv2.findContours(edged, cv2.RETR_LIST, cv2.CHAIN_APPROX_SIMPLE)
contours = sorted(contours, key=cv2.contourArea, reverse=True)[:5]
quad = None
for c in contours:
    peri = cv2.arcLength(c, True)
    approx = cv2.approxPolyDP(c, 0.02 * peri, True)
    if len(approx) == 4:
        quad = approx.reshape(4, 2) * ratio
        break
if quad is None:
    # No page contour found — fall back to a straight adaptive-threshold scan.
    g = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    out = cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 10)
    cv2.imwrite(sys.argv[2], out)
    print("scan (no page edge found; thresholded whole image): " + sys.argv[2]); sys.exit(0)
# Order corners: tl, tr, br, bl.
s = quad.sum(axis=1); d = np.diff(quad, axis=1)
rect = np.array([quad[np.argmin(s)], quad[np.argmin(d)], quad[np.argmax(s)], quad[np.argmax(d)]], dtype="float32")
(tl, tr, br, bl) = rect
wA = np.linalg.norm(br - bl); wB = np.linalg.norm(tr - tl)
hA = np.linalg.norm(tr - br); hB = np.linalg.norm(tl - bl)
W, H = max(int(wA), int(wB)), max(int(hA), int(hB))
dst = np.array([[0, 0], [W - 1, 0], [W - 1, H - 1], [0, H - 1]], dtype="float32")
M = cv2.getPerspectiveTransform(rect, dst)
warped = cv2.warpPerspective(img, M, (W, H))
g = cv2.cvtColor(warped, cv2.COLOR_BGR2GRAY)
out = cv2.adaptiveThreshold(g, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C, cv2.THRESH_BINARY, 31, 10)
if not cv2.imwrite(sys.argv[2], out):
    sys.exit("cannot write: " + sys.argv[2])
print("scan: " + sys.argv[2])
PY
}

# ── extract_frames — sample frames from a video at a fixed interval. Writes. ─
# Dataset building, surveillance review, drone-survey stills.
tool_opencv_extract_frames() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local every; every=$(int_guard "$(tool_arg every 30)" 30)
    # Cap the number of frames written — an hour of 30fps video at every=1 is
    # ~108k files (disk-fill DoS). Bounded to 5000 regardless of the request.
    local maxf; maxf=$(int_guard "$(tool_arg max 500)" 500); (( maxf > 5000 )) && maxf=5000; (( maxf < 1 )) && maxf=1
    local base="${file%.*}_frame"
    path_check_allowed "${base}_0.jpg" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    python3 - "$file" "$base" "$every" "$maxf" <<'PY' 2>&1
import sys, cv2
cap = cv2.VideoCapture(sys.argv[1])
if not cap.isOpened():
    sys.exit("cannot open video: " + sys.argv[1])
base, every, maxf = sys.argv[2], max(1, int(sys.argv[3])), max(1, int(sys.argv[4]))
idx = written = 0
while written < maxf:
    ok, frame = cap.read()
    if not ok:
        break
    if idx % every == 0:
        cv2.imwrite("%s_%d.jpg" % (base, idx), frame)
        written += 1
    idx += 1
cap.release()
note = " (capped at %d)" % maxf if written >= maxf else ""
print("extracted %d frame(s) (every %d)%s from %d, e.g. %s_0.jpg" % (written, every, note, idx, base))
PY
}

# ── stitch — panorama from overlapping images (drone/real-estate/agri). Writes ─
tool_opencv_stitch() {
    _cv_available || { _cv_missing; return 1; }
    local files; files=$(tool_arg files)
    [[ -n "$files" && "$files" != "null" ]] || { printf 'files (JSON array of >=2 image paths) required'; return 1; }
    local -a paths=(); local f ok=1
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        { [[ -f "$f" ]] && path_check_allowed "$f" 2>/dev/null; } || { ok=0; break; }
        paths+=("$f")
    done < <(printf '%s' "$files" | jq -r '.[]?' 2>/dev/null)
    [[ "$ok" == 1 ]] || { printf 'one or more inputs missing/not allowed'; return 1; }
    [[ "${#paths[@]}" -ge 2 ]] || { printf 'need at least 2 images to stitch'; return 1; }
    local out; out=$(tool_arg out "${paths[0]%.*}_pano.jpg")
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed'; return 1; }
    python3 - "$out" "${paths[@]}" <<'PY' 2>&1
import sys, cv2
out = sys.argv[1]
imgs = [cv2.imread(p) for p in sys.argv[2:]]
if any(i is None for i in imgs):
    sys.exit("cannot read one or more images")
stitcher = cv2.Stitcher_create() if hasattr(cv2, "Stitcher_create") else cv2.createStitcher()
status, pano = stitcher.stitch(imgs)
if status != cv2.Stitcher_OK:
    sys.exit("stitch failed (status %d) — images may not overlap enough" % status)
if not cv2.imwrite(out, pano):
    sys.exit("cannot write: " + out)
print("panorama: " + out)
PY
}

# ── annotate — draw boxes+labels from a JSON spec onto an image. Writes. ─────
# Turn detect_faces / template_match / count_objects output into a review image.
tool_opencv_annotate() {
    local file="$1"; _cv_guard "$file" || return 1
    _cv_available || { _cv_missing; return 1; }
    local boxes; boxes=$(tool_arg boxes)
    [[ -n "$boxes" && "$boxes" != "null" ]] || { printf 'boxes (JSON array of {x,y,w,h,label?}) required'; return 1; }
    printf '%s' "$boxes" | jq empty 2>/dev/null || { printf 'boxes must be valid JSON'; return 1; }
    local out; out=$(_cv_out "$file" "_annotated" "$(path_ext "$file")") || { printf 'output path not allowed'; return 1; }
    # boxes JSON goes via argv, not stdin: `python3 -` already reads its program
    # from stdin (the heredoc), so sys.stdin is not available for data.
    python3 - "$file" "$out" "$boxes" <<'PY' 2>&1
import sys, json, cv2
img = cv2.imread(sys.argv[1])
if img is None:
    sys.exit("cannot read image: " + sys.argv[1])
try:
    boxes = json.loads(sys.argv[3])
except Exception as e:
    sys.exit("bad boxes JSON: %s" % e)
for b in boxes:
    x, y, w, h = int(b["x"]), int(b["y"]), int(b["w"]), int(b["h"])
    cv2.rectangle(img, (x, y), (x + w, y + h), (0, 200, 0), 2)
    label = str(b.get("label", ""))
    if label:
        cv2.putText(img, label, (x, max(0, y - 6)), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 200, 0), 2)
if not cv2.imwrite(sys.argv[2], img):
    sys.exit("cannot write: " + sys.argv[2])
print("annotated %d box(es): %s" % (len(boxes), sys.argv[2]))
PY
}

# ── llm_explain — interpret a CV result / pick the next processing step. ─────
tool_opencv_llm_explain() {
    local input="$1"
    [[ -n "$input" ]] || { printf 'a file, a JSON result, or a question is required'; return 1; }
    local content="$input"
    [[ -f "$input" ]] && content=$(tool_opencv_info "$input")
    local system_prompt='You are an OpenCV computer-vision expert. Given the image info, a JSON detection/analysis result, or a question below, explain what it means in plain language and recommend the exact next yantra opencv <call> (with fields) to solve the user"s goal — e.g. which of detect_faces/read_qr/compare/count_objects/template_match/motion/edges/threshold/blur_faces/denoise/document_scan/stitch fits, and why.'
    llm_analyze "$system_prompt" "$content"
}

# ── Register ─────────────────────────────────────────────────────────────────
tool_register "opencv_doctor"           tool_opencv_doctor           '{"type":"object","properties":{}}' safe all opencv
tool_register "opencv_info"             tool_opencv_info             '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all opencv
tool_register "opencv_detect_faces"     tool_opencv_detect_faces     '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all opencv
tool_register "opencv_read_qr"          tool_opencv_read_qr          '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all opencv
tool_register "opencv_compare"          tool_opencv_compare          '{"type":"object","properties":{"file":{"type":"string","description":"path to the first image"},"other":{"type":"string","description":"path to the second image to compare against"}},"required":["file"]}' safe all opencv
tool_register "opencv_count_objects"    tool_opencv_count_objects    '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"min_area":{"type":"integer","description":"the min area"}},"required":["file"]}' safe all opencv
tool_register "opencv_dominant_colors"  tool_opencv_dominant_colors  '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"k":{"type":"integer","description":"number of nearest results to return"}},"required":["file"]}' safe all opencv
tool_register "opencv_template_match"   tool_opencv_template_match   '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"template":{"type":"string","description":"the template"},"threshold":{"type":"string","description":"the threshold"}},"required":["file","template"]}' safe all opencv
tool_register "opencv_detect_motion"           tool_opencv_detect_motion           '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"sensitivity":{"type":"integer","description":"the sensitivity"}},"required":["file"]}' safe all opencv
tool_register "opencv_detect_edges"            tool_opencv_detect_edges            '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"low":{"type":"integer","description":"the low"},"high":{"type":"integer","description":"the high"}},"required":["file"]}' writes all opencv
tool_register "opencv_threshold"        tool_opencv_threshold        '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"mode":{"type":"string","enum":["adaptive","otsu"],"description":"the mode"}},"required":["file"]}' writes all opencv
tool_register "opencv_blur_faces"       tool_opencv_blur_faces       '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all opencv
tool_register "opencv_denoise"          tool_opencv_denoise          '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"strength":{"type":"integer","description":"the strength"}},"required":["file"]}' writes all opencv
tool_register "opencv_sharpen"          tool_opencv_sharpen          '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all opencv
tool_register "opencv_document_scan"    tool_opencv_document_scan    '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' writes all opencv
tool_register "opencv_extract_frames"   tool_opencv_extract_frames   '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"every":{"type":"integer","description":"the every"}},"required":["file"]}' writes all opencv
tool_register "opencv_stitch"           tool_opencv_stitch           '{"type":"object","properties":{"files":{"type":"array","items":{"type":"string"},"description":"list of file paths relative to the project root"},"out":{"type":"string","description":"output path"}},"required":["files"]}' writes all opencv
tool_register "opencv_annotate"         tool_opencv_annotate         '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"},"boxes":{"type":"array","items":{"type":"object"},"description":"the boxes"}},"required":["file","boxes"]}' writes all opencv
tool_register "opencv_llm_explain"      tool_opencv_llm_explain      '{"type":"object","properties":{"file":{"type":"string","description":"path to the target file, relative to the project root"}},"required":["file"]}' safe all opencv mid
