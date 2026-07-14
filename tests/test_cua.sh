#!/usr/bin/env bash
# Test: the cua (Computer-Using Agent / computer-use driver) tool category — over MCP.
#
# Two tiers, meaningful on any box (incl. headless CI):
#   1. Structural + guard tests that need NO display and NO input binaries:
#      registration, danger classification, schemas, category gating, the OS
#      backend selection (via doctor), and every arg guard that fires before a
#      backend is touched.
#   2. A SINGLE, best-effort screen CAPTURE when a display + a screenshot backend
#      are actually present. This suite NEVER exercises move/click/type/key/
#      scroll/drag — those would move the real cursor and type into the focused
#      window, which is unacceptable in an automated test.
set -uo pipefail
HARNESS="$1"; TMP="$2"
PROJ_ROOT="$(cd "$(dirname "$HARNESS")" && pwd)"
source "$PROJ_ROOT/tests/lib_mcp.sh"
cd "$TMP"
rm -f .harness.db
git init -q; git config user.email t@t; git config user.name t
echo a > a.txt; git add a.txt; git commit -qm init >/dev/null 2>&1
export HARNESS_UPDATE_ENABLED=false HARNESS_CONFIG_GLOBAL="$TMP/none.json"

fail() { echo "FAIL: $*"; exit 1; }

# cua TOOL [ARGS_JSON] [y] — one cua call with the category enabled.
cua() { MCP_FLAGS="--enable cua" mcp_call "$HARNESS" "cua_$1" "${2:-}" "${3:-}"; }
grep_cua() { local pat="$1" t="$2" a="${3:-}" y="${4:-}" o; o=$(cua "$t" "$a" "$y") || true; grep -qi -- "$pat" <<<"$o"; }

# ── 1. Registration ──────────────────────────────────────────────────────────
REG=$(registry_dump "$PROJ_ROOT")
EXPECTED="doctor screen_size cursor_position list_windows active_window screenshot \
ocr move click type press_key scroll drag find_text ui_snapshot act ui_diff ui_find llm_explain"
for t in $EXPECTED; do
    grep -q "^cua_${t}|" <<<"$REG" || fail "cua tool not registered: cua_${t}"
done
NCUA=$(grep -c '|cua|' <<<"$REG")
[[ "$NCUA" -ge 14 ]] || fail "cua registers only $NCUA tools (expected >=14)"
mcp_wf "$HARNESS" tools.status '{}' y | grep -qi cua || fail "cua category missing from tools.status"

# ── 2. Danger classification (the read/capture/act split) ────────────────────
for r in doctor screen_size cursor_position list_windows active_window ui_diff ui_find; do
    grep -q "^cua_${r}|safe|" <<<"$REG" || fail "cua_${r} should be danger=safe (read half)"
done
for w in screenshot ocr move click type press_key scroll drag find_text ui_snapshot act; do
    grep -q "^cua_${w}|writes|" <<<"$REG" || fail "cua_${w} should be danger=writes (capture/act half must be gated)"
done

# ── Semantic half: ui_diff computes the MINIMAL change-set; ui_find queries it.
# Pure JSON — deterministic, no display needed (the diagram's Switch#4 example).
BEFORE='{"elements":[{"role":"AXButton","name":"General"},{"role":"AXCheckBox","name":"Switch4","value":"0","enabled":true}]}'
AFTER='{"elements":[{"role":"AXButton","name":"General"},{"role":"AXCheckBox","name":"Switch4","value":"1","enabled":true}]}'
DIFF=$(MCP_FLAGS="--enable cua" mcp_call "$HARNESS" cua_ui_diff "{\"before\":$BEFORE,\"after\":$AFTER}")
echo "$DIFF" | jq -e '.summary=="added=0 removed=0 changed=1"' >/dev/null || fail "cua_ui_diff wrong summary: $DIFF"
echo "$DIFF" | jq -e '.changed[0].name=="Switch4" and .changed[0].value==["0","1"]' >/dev/null || fail "cua_ui_diff missed the Switch4 value change: $DIFF"
FIND=$(MCP_FLAGS="--enable cua" mcp_call "$HARNESS" cua_ui_find "{\"tree\":$AFTER,\"role\":\"checkbox\"}")
echo "$FIND" | jq -e '.count==1 and .matches[0].name=="Switch4"' >/dev/null || fail "cua_ui_find did not locate the checkbox: $FIND"
# ui_snapshot / act are consent-gated (writes); without -y they auto-deny.
GATED=$(MCP_FLAGS="--enable cua" mcp_call "$HARNESS" cua_ui_snapshot '{}') && fail "cua_ui_snapshot ran without consent"
echo "$GATED" | grep -qi 'confirm\|consent\|auto-den' || fail "cua_ui_snapshot denial message unexpected: $GATED"
grep -qE '^cua_llm_explain\|[a-z]+\|[a-z]+\|mid$' <<<"$REG" || fail "cua_llm_explain should be complexity=mid"

# ── 3. Schemas parse ─────────────────────────────────────────────────────────
BAD=$(YCA_DIR="$PROJ_ROOT" bash -c '
  set -u; export YCA_DIR
  source "$YCA_DIR/harness/main.sh" </dev/null 2>/dev/null
  for n in "${!YCA_TOOL_SCHEMAS[@]}"; do
    [[ "$n" == cua_* ]] || continue
    printf "%s" "${YCA_TOOL_SCHEMAS[$n]}" | jq -e . >/dev/null 2>&1 || echo "$n"
  done')
[[ -z "$BAD" ]] || fail "cua schemas are not valid JSON: $BAD"

# ── 4. Category gating on the MCP dispatch path ──────────────────────────────
GATED=$(mcp_call "$HARNESS" cua_doctor '{}') && fail "cua_doctor should be gated when category is off"
grep -qi 'disabled' <<<"$GATED" || fail "gate message should say disabled: $GATED"

# ── 5. doctor reports OS + display server + backend selection (always runs) ──
DOC=$(cua doctor) || true
grep -qiE 'display server|OS:' <<<"$DOC" || fail "cua doctor produced no OS/display status: $DOC"
grep -qiE 'screenshot backend|pointer backend|keyboard backend' <<<"$DOC" \
    || fail "cua doctor should report the per-OS backend selection: $DOC"

# ── 6. Arg guards that fire BEFORE any backend/display is touched ─────────────
# screenshot validates the output path first, so an out-of-tree path is rejected
# on every box (headless included).
grep_cua 'not allowed' screenshot '{"out":"/etc/yantra_evil.png"}' y \
    || fail "screenshot must reject an out-of-tree output path"
# move requires coordinates before it looks for a pointer backend.
grep_cua 'required' move '{}' y || fail "move must require x and y"
grep_cua 'required' drag '{"x1":1,"y1":2}' y || fail "drag must require all four coordinates"
# key validates the spec (blocks shell metacharacters) before choosing a backend.
grep_cua 'invalid key spec' press_key '{"key":"a++b"}' y || fail "key must reject a malformed spec"
grep_cua 'invalid key spec' press_key '{"key":"ctrl+;rm"}' y || fail "key must reject metacharacters in the spec"
# click validates the button name before choosing a backend.
grep_cua 'button must be' click '{"button":"sideways"}' y || fail "click must validate the button name"
# missing `text` is caught by the schema validator; an empty-but-present value
# exercises the tool's own non-empty guard.
grep_cua 'required' type '{}' y || fail "type must reject missing text (schema validator)"
grep_cua 'text required' type '{"text":""}' y || fail "type must reject empty text (in-function guard)"

# ── 7. Black-box: injection-safety + correct backend argv via STUBBED backends ─
# The act tools (type/click/key/move/scroll/drag) would drive the real cursor and
# keyboard, which is unsafe in CI. So we shadow every backend binary on PATH with
# a stub that just records the argv it received, then fire hostile payloads and
# assert (a) no shell injection ran, (b) the payload reached the backend as ONE
# intact argument, (c) the backend got the right verb/coords. A forced display
# server + stubbed binaries make this deterministic on macOS AND headless Linux.
LOG="$TMP/argv.log"
FAKE="$TMP/fakebin"; mkdir -p "$FAKE"
for b in cliclick xdotool ydotool wtype screencapture maim scrot grim gnome-screenshot spectacle import tesseract; do
    cat > "$FAKE/$b" <<EOF
#!/usr/bin/env bash
{ printf 'CMD[%s]' "$b"; for a in "\$@"; do printf ' {%s}' "\$a"; done; printf '\n'; } >> "$LOG"
case "$b" in
  screencapture|maim|scrot|grim|import|gnome-screenshot|spectacle) : > "\${@: -1}" 2>/dev/null ;;
  tesseract) echo "OCR_STUB_TEXT" ;;
esac
exit 0
EOF
    chmod +x "$FAKE/$b"
done
export PATH="$FAKE:$PATH"
# Force a concrete display server so the backend selection is deterministic.
[[ "$(uname)" != Darwin ]] && export DISPLAY=":99" XDG_SESSION_TYPE="x11"

: > "$LOG"; rm -f "$TMP/PWNED" "$TMP/PWNED2"
# (a) type: a shell-injection payload must NOT execute, and must reach the backend
#     as a single literal argument.
PAYLOAD="a; touch $TMP/PWNED \$(touch $TMP/PWNED2)"
OUT=$(cua type "$(jq -cn --arg t "$PAYLOAD" '{text:$t}')" y) || true
grep -qi 'typed' <<<"$OUT" || fail "type should report success through the stub backend: $OUT"
[[ ! -e "$TMP/PWNED" && ! -e "$TMP/PWNED2" ]] || fail "SHELL INJECTION in cua_type — payload was executed, not passed literally"
grep -qF 'touch' "$LOG" || fail "the type payload should have reached the backend argv"
# The payload must sit inside ONE argv brace-group (no splitting on ; or space).
grep -qF "{t:$PAYLOAD}" "$LOG" || grep -qF "$PAYLOAD}" "$LOG" \
    || fail "type payload was split across args (should be one literal argv): $(cat "$LOG")"

# (b) click: right button + coordinates reach the backend.
: > "$LOG"
cua click '{"x":137,"y":241,"button":"right"}' y >/dev/null || true
grep -q '137' "$LOG" && grep -q '241' "$LOG" || fail "click coords 137,241 did not reach the backend: $(cat "$LOG")"

# (c) move + drag + key exercise the backend without error.
: > "$LOG"
cua move '{"x":11,"y":22}' y >/dev/null || true
grep -q '11' "$LOG" && grep -q '22' "$LOG" || fail "move coords did not reach the backend"
: > "$LOG"
cua press_key '{"key":"cmd+s"}' y >/dev/null || true
[[ -s "$LOG" ]] || fail "key cmd+s produced no backend call"

# (d) screenshot: the stub creates the output file; assert success + in-tree file.
rm -f "$TMP/shot.png"; : > "$LOG"
OUT=$(cua screenshot "{\"out\":\"$TMP/shot.png\"}" y) || true
grep -qi 'screenshot:' <<<"$OUT" || fail "screenshot should report success via the stub: $OUT"
[[ -f "$TMP/shot.png" ]] || fail "screenshot did not produce the output file"
grep -q 'shot.png' "$LOG" || fail "screenshot output path did not reach the backend"

# (e) ocr: stub tesseract returns text; assert it is surfaced.
OUT=$(cua ocr '{}' y) || true
grep -qi 'OCR_STUB_TEXT' <<<"$OUT" || fail "ocr should surface the recognized text: $OUT"

echo "cua OK (structural + injection-safety + backend-argv via stubs)"
exit 0
