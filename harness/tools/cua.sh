# tools/cua.sh — CUA (Computer-Using Agent) driver: let an agent SEE the screen
# and DRIVE the mouse/keyboard on the local machine. This is the "computer use"
# primitive, done the same way the media/opencv categories shell out to a proven
# binary — here the binary differs per OS, and picking the wrong one silently
# no-ops, so the whole point of this file is to encode those differences.
#
# The OS matrix (the hard part — see lib/os.sh os_display_server):
#   macOS (quartz)  capture: screencapture (built in)
#                   input:   cliclick (brew install cliclick) — precise; or
#                            AppleScript System Events (built in) fallback
#                   PERMISSION: screencapture of other apps needs Screen
#                     Recording, and cliclick/System Events input needs
#                     Accessibility — both in System Settings ▸ Privacy &
#                     Security. Without them capture is black / input no-ops.
#   Linux X11       capture: maim / scrot / import (imagemagick)
#                   input:   xdotool
#   Linux Wayland   capture: grim (wlroots) / gnome-screenshot / spectacle (kde)
#                   input:   wtype (wlroots, type+keys) or ydotool (uinput,
#                            compositor-agnostic — needs the ydotoold daemon and
#                            access to /dev/uinput). xdotool does NOT drive
#                            native Wayland windows.
#   headless/other  no display — read/act tools report that honestly.
#
# Safety posture (security-first, matches the codebase's read/act split):
#   • Pure DISPLAY METADATA (size, cursor, window list, active window) is `safe`.
#   • CAPTURING PIXELS (screenshot, ocr) is gated `writes` — it reads the user's
#     screen contents (privacy) and writes a file.
#   • DRIVING INPUT (move/click/type/key/scroll/drag) is gated `writes` — it
#     changes real machine state.
# A real CUA loop runs the server with -y (pre-consented); otherwise every
# capture/act call is denied on the MCP surface, by design.

# ── Backend selection ────────────────────────────────────────────────────────
_cua_ds() { os_display_server; }

# _cua_shot_tool -> the screenshot binary to use, or empty if none present.
_cua_shot_tool() {
    case "$(_cua_ds)" in
        quartz)  command -v screencapture &>/dev/null && printf 'screencapture' ;;
        x11)     for t in maim scrot import; do command -v "$t" &>/dev/null && { printf '%s' "$t"; return; }; done ;;
        wayland)
            case "$(os_wayland_compositor)" in
                gnome) command -v gnome-screenshot &>/dev/null && { printf 'gnome-screenshot'; return; } ;;
                kde)   command -v spectacle &>/dev/null && { printf 'spectacle'; return; } ;;
            esac
            for t in grim gnome-screenshot spectacle; do command -v "$t" &>/dev/null && { printf '%s' "$t"; return; }; done ;;
    esac
}

# _cua_pointer_tool -> the mouse (move/click/scroll/drag) binary, or empty.
_cua_pointer_tool() {
    case "$(_cua_ds)" in
        quartz)  command -v cliclick &>/dev/null && printf 'cliclick' ;;
        x11)     command -v xdotool  &>/dev/null && printf 'xdotool' ;;
        wayland) command -v ydotool  &>/dev/null && printf 'ydotool' ;;
    esac
}

# _cua_key_tool -> the keyboard (type/key) binary, or empty.
_cua_key_tool() {
    case "$(_cua_ds)" in
        quartz)  if command -v cliclick &>/dev/null; then printf 'cliclick'
                 elif command -v osascript &>/dev/null; then printf 'osascript'; fi ;;
        x11)     command -v xdotool &>/dev/null && printf 'xdotool' ;;
        wayland) if command -v wtype &>/dev/null; then printf 'wtype'
                 elif command -v ydotool &>/dev/null; then printf 'ydotool'; fi ;;
    esac
}

# _cua_input_hint -> per-OS install advice for the missing input backend.
_cua_input_hint() {
    case "$(_cua_ds)" in
        quartz)  printf 'install: brew install cliclick   (and grant Accessibility in System Settings ▸ Privacy & Security ▸ Accessibility)' ;;
        x11)     printf 'install: brew install xdotool  /  apt install xdotool' ;;
        wayland) printf 'install: apt install wtype   (wlroots: sway/hyprland)   OR   ydotool + a running ydotoold with access to /dev/uinput (GNOME/KDE)' ;;
        *)       printf 'no display server detected (headless) — CUA input is unavailable here' ;;
    esac
}

# _cua_have_display -> 0 if a display server is present (not headless).
_cua_have_display() { [[ "$(_cua_ds)" != "none" ]]; }

# _cua_coord VALUE -> a non-negative integer coordinate, or empty on bad input.
_cua_coord() { [[ "$1" =~ ^[0-9]+$ ]] && printf '%s' "$1"; }

# ── doctor — the one call to run first: what OS, what backend, what's missing ──
tool_cua_doctor() {
    local ds comp out=""
    ds=$(_cua_ds)
    out+="OS: $(os_name)\n"
    out+="display server: $ds\n"
    [[ "$ds" == "wayland" ]] && { comp=$(os_wayland_compositor); out+="wayland compositor: $comp\n"; }
    local shot ptr key
    shot=$(_cua_shot_tool); ptr=$(_cua_pointer_tool); key=$(_cua_key_tool)
    out+="screenshot backend: ${shot:-MISSING}\n"
    out+="pointer backend:    ${ptr:-MISSING}\n"
    out+="keyboard backend:   ${key:-MISSING}\n"
    # Accessibility (semantic) half: ui_snapshot / act. macOS uses System Events;
    # other OSes fall back to the pixel half until an AT-SPI backend is wired.
    if [[ "$ds" == quartz ]] && command -v osascript &>/dev/null; then
        out+="a11y backend:       macOS System Events (ui_snapshot / act) — needs Accessibility permission\n"
    else
        out+="a11y backend:       none (pixel-only here; ui_diff / ui_find still work on any snapshot JSON)\n"
    fi
    [[ -z "$shot$ptr$key" ]] && out+="\nhint: $(_cua_input_hint)\n"
    case "$ds" in
        quartz)
            out+="\nmacOS permissions (System Settings ▸ Privacy & Security):\n"
            out+="  • Screen Recording — required or screenshots come back black\n"
            out+="  • Accessibility    — required or cliclick / System Events input silently does nothing\n"
            command -v cliclick &>/dev/null || out+="  • cliclick not found — precise input needs it: brew install cliclick\n" ;;
        wayland)
            out+="\nWayland notes: input injection is restricted by design.\n"
            out+="  • wlroots (sway/hyprland): grim + wtype cover shot/type/keys; ydotool for the mouse\n"
            out+="  • GNOME/KDE: mouse+key injection needs ydotool with a running ydotoold and /dev/uinput access\n"
            command -v ydotool &>/dev/null && ! pgrep -x ydotoold &>/dev/null \
                && out+="  • ydotool is installed but ydotoold does NOT appear to be running — start it first\n" ;;
        x11)
            out+="\nX11: no special permissions needed; xdotool + maim/scrot/import cover everything.\n" ;;
        none)
            out+="\nNo display detected. Screen capture and input control are unavailable on a headless host.\n" ;;
    esac
    printf '%b' "$out"
}

# ── screen_size — WxH of the primary display. Read-only. ─────────────────────
tool_cua_screen_size() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    case "$(_cua_ds)" in
        quartz)
            # The `... | awk` pipe always exits 0, so validate the value (four
            # bounds fields) BEFORE returning, else fall through to system_profiler.
            local b; b=$(osascript -e 'tell application "Finder" to get bounds of window of desktop' 2>/dev/null \
                | awk -F', *' 'NF>=4{printf "%sx%s", $3, $4}')
            [[ -n "$b" ]] && { printf '%s' "$b"; return 0; }
            system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Resolution/{print $2; exit}' ;;
        x11)
            command -v xdotool &>/dev/null && { xdotool getdisplaygeometry 2>/dev/null | awk '{printf "%sx%s\n",$1,$2}'; return 0; }
            command -v xrandr &>/dev/null && xrandr --current 2>/dev/null | awk '/\*/{print $1; exit}'
            command -v xdpyinfo &>/dev/null && xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2; exit}' ;;
        wayland)
            command -v wlr-randr &>/dev/null && { wlr-randr 2>/dev/null | awk '/current/{print $1; exit}'; return 0; }
            command -v swaymsg &>/dev/null && { swaymsg -t get_outputs 2>/dev/null | jq -r '.[] | select(.active) | "\(.current_mode.width)x\(.current_mode.height)"' | head -1; return 0; }
            command -v xrandr &>/dev/null && xrandr --current 2>/dev/null | awk '/\*/{print $1; exit}' \
                || printf 'screen size unavailable on this Wayland compositor (try wlr-randr / swaymsg)' ;;
        *) printf 'unsupported display server' ;;
    esac
}

# ── cursor_position — global mouse coordinates "x,y". Read-only. ─────────────
tool_cua_cursor_position() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    case "$(_cua_ds)" in
        quartz)
            command -v cliclick &>/dev/null || { printf 'cursor position on macOS needs cliclick: brew install cliclick'; return 1; }
            cliclick p 2>/dev/null ;;
        x11)
            command -v xdotool &>/dev/null || { printf 'need xdotool: apt install xdotool'; return 1; }
            eval "$(xdotool getmouselocation --shell 2>/dev/null)"; printf '%s,%s' "${X:-?}" "${Y:-?}" ;;
        wayland)
            printf 'the global cursor position is not queryable on Wayland (the compositor restricts it)' ; return 1 ;;
        *) printf 'unsupported display server'; return 1 ;;
    esac
}

# ── list_windows — visible windows / applications. Read-only. ────────────────
tool_cua_list_windows() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    case "$(_cua_ds)" in
        quartz)
            osascript -e 'tell application "System Events" to get name of (every process whose visible is true)' 2>/dev/null \
                | tr ',' '\n' | sed 's/^ *//' | grep -v '^$' ;;
        x11)
            command -v wmctrl &>/dev/null && { wmctrl -l 2>/dev/null; return 0; }
            command -v xdotool &>/dev/null || { printf 'need wmctrl or xdotool'; return 1; }
            xdotool search --onlyvisible --name '' getwindowname %@ 2>/dev/null | grep -v '^$' ;;
        wayland)
            if command -v swaymsg &>/dev/null; then
                swaymsg -t get_tree 2>/dev/null | jq -r '.. | objects | select(.name and .pid) | .name' 2>/dev/null | grep -v '^$'
            elif command -v hyprctl &>/dev/null; then
                hyprctl clients 2>/dev/null | awk -F': ' '/title:/{print $2}'
            else
                printf 'window listing is not available on this Wayland compositor'; return 1
            fi ;;
        *) printf 'unsupported display server'; return 1 ;;
    esac
}

# ── active_window — the frontmost / focused window title. Read-only. ─────────
tool_cua_active_window() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    case "$(_cua_ds)" in
        quartz)
            osascript -e 'tell application "System Events" to get name of first process whose frontmost is true' 2>/dev/null ;;
        x11)
            command -v xdotool &>/dev/null || { printf 'need xdotool'; return 1; }
            xdotool getactivewindow getwindowname 2>/dev/null ;;
        wayland)
            if command -v swaymsg &>/dev/null; then
                swaymsg -t get_tree 2>/dev/null | jq -r '.. | objects | select(.focused==true) | .name' 2>/dev/null | head -1
            elif command -v hyprctl &>/dev/null; then
                hyprctl activewindow 2>/dev/null | awk -F': ' '/title:/{print $2; exit}'
            else
                printf 'the focused window is not queryable on this Wayland compositor'; return 1
            fi ;;
        *) printf 'unsupported display server'; return 1 ;;
    esac
}

# ── _cua_shoot OUT [X Y W H] — capture the screen (or a region) to OUT. ───────
# Returns non-zero + a message on failure. Region is used only when W>0 && H>0.
_cua_shoot() {
    local out="$1" x="$2" y="$3" w="$4" h="$5" tool
    tool=$(_cua_shot_tool)
    [[ -n "$tool" ]] || { printf 'no screenshot backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    local region=0; [[ "${w:-0}" =~ ^[0-9]+$ && "${h:-0}" =~ ^[0-9]+$ && "$w" -gt 0 && "$h" -gt 0 ]] && region=1
    case "$tool" in
        screencapture)
            if [[ "$region" == 1 ]]; then screencapture -x -R"${x:-0},${y:-0},${w},${h}" "$out" 2>&1
            else screencapture -x "$out" 2>&1; fi ;;
        maim)  if [[ "$region" == 1 ]]; then maim -g "${w}x${h}+${x:-0}+${y:-0}" "$out" 2>&1; else maim "$out" 2>&1; fi ;;
        scrot) scrot -o "$out" 2>&1 ;;   # scrot geometry varies by version — full-screen is reliable
        import) if [[ "$region" == 1 ]]; then import -window root -crop "${w}x${h}+${x:-0}+${y:-0}" "$out" 2>&1
                else import -window root "$out" 2>&1; fi ;;
        grim)  if [[ "$region" == 1 ]]; then grim -g "${x:-0},${y:-0} ${w}x${h}" "$out" 2>&1; else grim "$out" 2>&1; fi ;;
        gnome-screenshot) gnome-screenshot -f "$out" 2>&1 ;;   # region needs interactive -a; full only here
        spectacle)        spectacle -b -n -o "$out" 2>&1 ;;
        *) printf 'unknown screenshot backend: %s' "$tool"; return 1 ;;
    esac
}

# ── screenshot — capture the screen (full or a region) to a PNG in-tree. ─────
# Gated `writes`: it reads the user's screen contents (privacy) and writes a file.
tool_cua_screenshot() {
    local out x y w h
    out=$(tool_arg out "${YCA_PROJECT_DIR}/cua_shot_$(now_stamp).png")
    path_check_allowed "$out" 2>/dev/null || { printf 'output path not allowed (must be inside the project): %s' "$out"; return 1; }
    _cua_have_display || { printf 'no display server detected (headless) — cannot screenshot'; return 1; }
    [[ -e "$out" ]] && { confirm_action "Overwrite existing file: $out" "overwrite $out" || { printf 'refusing to overwrite (pass a different .out): %s' "$out"; return 1; }; }
    x=$(_cua_coord "$(tool_arg x 0)"); y=$(_cua_coord "$(tool_arg y 0)")
    w=$(_cua_coord "$(tool_arg width 0)"); h=$(_cua_coord "$(tool_arg height 0)")
    confirm_action "Capture the screen to $out" "screenshot ($(_cua_ds))" || { confirm_denied_msg; return 1; }
    local err; err=$(_cua_shoot "$out" "${x:-0}" "${y:-0}" "${w:-0}" "${h:-0}") || { printf '%s' "$err"; return 1; }
    [[ -f "$out" ]] || { printf 'screenshot failed (no file produced). %s' "$err"; return 1; }
    printf 'screenshot: %s (%s bytes)' "$out" "$(path_size "$out")"
}

# ── ocr — screenshot (full or region) then OCR to text via tesseract. ────────
# Gated `writes` (captures the screen). Returns recognized text; the temp PNG is
# cleaned up, so nothing is persisted unless the caller asked screenshot for it.
tool_cua_ocr() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    command -v tesseract &>/dev/null || { printf 'ocr needs tesseract: brew install tesseract  /  apt install tesseract-ocr'; return 1; }
    local x y w h; x=$(_cua_coord "$(tool_arg x 0)"); y=$(_cua_coord "$(tool_arg y 0)")
    w=$(_cua_coord "$(tool_arg width 0)"); h=$(_cua_coord "$(tool_arg height 0)")
    confirm_action "Capture the screen and OCR it to text" "screenshot+tesseract ($(_cua_ds))" || { confirm_denied_msg; return 1; }
    local tmp; tmp=$(path_temp_file yca-cua-ocr .png)
    local err; err=$(_cua_shoot "$tmp" "${x:-0}" "${y:-0}" "${w:-0}" "${h:-0}") || { rm -f "$tmp"; printf '%s' "$err"; return 1; }
    local text; text=$(tesseract "$tmp" - 2>/dev/null)
    rm -f "$tmp"
    [[ -n "$text" ]] && printf '%s' "$text" || printf '(no text recognized)'
}

# ── move — move the cursor to (x,y). Gated. ──────────────────────────────────
tool_cua_move() {
    local x y tool; x=$(_cua_coord "$(tool_arg x)"); y=$(_cua_coord "$(tool_arg y)")
    [[ -n "$x" && -n "$y" ]] || { printf 'x and y (non-negative integers) required'; return 1; }
    tool=$(_cua_pointer_tool); [[ -n "$tool" ]] || { printf 'no pointer backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    confirm_action "Move the mouse to $x,$y" "cua move $x,$y" || { confirm_denied_msg; return 1; }
    case "$tool" in
        cliclick) cliclick "m:$x,$y" 2>&1 ;;
        xdotool)  xdotool mousemove "$x" "$y" 2>&1 ;;
        ydotool)  ydotool mousemove --absolute -- "$x" "$y" 2>&1 || ydotool mousemove -a "$x" "$y" 2>&1 ;;
    esac && printf 'moved to %s,%s' "$x" "$y"
}

# ── click — click at (x,y) (or the current point). button/count optional. ────
tool_cua_click() {
    local x y btn count tool
    x=$(_cua_coord "$(tool_arg x)"); y=$(_cua_coord "$(tool_arg y)")
    btn=$(tool_arg button left); count=$(int_guard "$(tool_arg count 1)" 1); (( count < 1 )) && count=1; (( count > 3 )) && count=3
    case "$btn" in left|right|middle) ;; *) printf 'button must be left|right|middle'; return 1 ;; esac
    tool=$(_cua_pointer_tool); [[ -n "$tool" ]] || { printf 'no pointer backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    local where="the current point"; [[ -n "$x" && -n "$y" ]] && where="$x,$y"
    confirm_action "Click ($btn x$count) at $where" "cua click $btn $where" || { confirm_denied_msg; return 1; }
    [[ "$btn" == middle && "$tool" == cliclick ]] && { printf 'middle click is not supported by cliclick on macOS'; return 1; }
    case "$tool" in
        cliclick)
            local pos="."; [[ -n "$x" && -n "$y" ]] && pos="$x,$y"
            if [[ "$count" -ge 2 ]]; then cliclick "dc:$pos" 2>&1
            elif [[ "$btn" == right ]]; then cliclick "rc:$pos" 2>&1
            else cliclick "c:$pos" 2>&1; fi ;;
        xdotool)
            [[ -n "$x" && -n "$y" ]] && xdotool mousemove "$x" "$y" 2>&1
            local b=1; [[ "$btn" == middle ]] && b=2; [[ "$btn" == right ]] && b=3
            xdotool click --repeat "$count" "$b" 2>&1 ;;
        ydotool)
            [[ -n "$x" && -n "$y" ]] && { ydotool mousemove --absolute -- "$x" "$y" 2>&1 || ydotool mousemove -a "$x" "$y" 2>&1; }
            # ydotool button codes: 0xC0=left,0xC1=right,0xC2=middle (down+up combined)
            local code=0xC0; [[ "$btn" == right ]] && code=0xC1; [[ "$btn" == middle ]] && code=0xC2
            local n; for ((n=0;n<count;n++)); do ydotool click "$code" 2>&1; done ;;
    esac && printf 'clicked %s (%s x%s)' "$where" "$btn" "$count"
}

# ── type — type a literal UTF-8 string wherever focus is. Gated. ─────────────
# The text is passed as a SINGLE argv to the backend (never a shell string), so
# it cannot inject a command regardless of its bytes.
tool_cua_type() {
    local text tool; text=$(tool_arg text)
    [[ -n "$text" ]] || { printf 'text required'; return 1; }
    tool=$(_cua_key_tool); [[ -n "$tool" ]] || { printf 'no keyboard backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    local preview="${text:0:40}"; [[ "${#text}" -gt 40 ]] && preview+="…"
    confirm_action "Type ${#text} character(s): \"$preview\"" "cua type" || { confirm_denied_msg; return 1; }
    case "$tool" in
        cliclick)  cliclick "t:$text" 2>&1 ;;   # `t:…` is always a cliclick command, never a flag
        osascript) osascript -e 'on run {t}' -e 'tell application "System Events" to keystroke t' -e 'end run' -- "$text" 2>&1 ;;
        xdotool)   xdotool type --clearmodifiers -- "$text" 2>&1 ;;
        wtype)     wtype -- "$text" 2>&1 || wtype "$text" 2>&1 ;;
        ydotool)   ydotool type -- "$text" 2>&1 ;;
    esac && printf 'typed %s character(s)' "${#text}"
}

# ── _cua_key_norm SPEC -> validated, lower-cased "+"-joined token list, or "". ─
# Accepts up to 5 alphanumeric tokens (modifiers + one key), e.g. "ctrl+shift+t",
# "Return", "cmd+s", "F5". Rejects anything else so a key spec can never carry
# shell metacharacters into a backend argv. Punctuation keys go through `type`.
_cua_key_norm() {
    local spec; spec=$(str_lower "$1")
    [[ "$spec" =~ ^[a-z0-9]+([+][a-z0-9]+){0,4}$ ]] || return 1
    printf '%s' "$spec"
}

# _cua_map_key BACKEND TOKEN -> that backend's name for a single key token.
_cua_map_key() {
    local be="$1" k="$2"
    case "$be" in
        xdotool)
            case "$k" in
                enter|return) printf 'Return' ;; esc|escape) printf 'Escape' ;;
                space) printf 'space' ;; tab) printf 'Tab' ;;
                backspace) printf 'BackSpace' ;; delete|del) printf 'Delete' ;;
                up) printf 'Up' ;; down) printf 'Down' ;; left) printf 'Left' ;; right) printf 'Right' ;;
                home) printf 'Home' ;; end) printf 'End' ;; pageup) printf 'Prior' ;; pagedown) printf 'Next' ;;
                ctrl|control) printf 'ctrl' ;; alt|option|opt) printf 'alt' ;; shift) printf 'shift' ;;
                cmd|command|super|meta|win) printf 'super' ;;
                f[0-9]|f1[0-9]|f2[0-4]) printf 'F%s' "${k#f}" ;;
                *) printf '%s' "$k" ;;
            esac ;;
        wtype)
            case "$k" in
                enter|return) printf 'Return' ;; esc|escape) printf 'Escape' ;;
                space) printf 'space' ;; tab) printf 'Tab' ;;
                backspace) printf 'BackSpace' ;; delete|del) printf 'Delete' ;;
                up) printf 'Up' ;; down) printf 'Down' ;; left) printf 'Left' ;; right) printf 'Right' ;;
                home) printf 'Home' ;; end) printf 'End' ;; pageup) printf 'Prior' ;; pagedown) printf 'Next' ;;
                ctrl|control) printf 'ctrl' ;; alt|option|opt) printf 'alt' ;; shift) printf 'shift' ;;
                cmd|command|super|meta|win) printf 'logo' ;;
                f[0-9]|f1[0-9]|f2[0-4]) printf 'F%s' "${k#f}" ;;
                *) printf '%s' "$k" ;;
            esac ;;
    esac
}

# _cua_is_mod TOKEN -> 0 if TOKEN is a modifier key.
_cua_is_mod() { case "$(str_lower "$1")" in ctrl|control|alt|option|opt|shift|cmd|command|super|meta|win) return 0 ;; *) return 1 ;; esac; }

# ── key — press a key or chord (e.g. "Return", "cmd+s", "ctrl+shift+t"). ─────
tool_cua_press_key() {
    local spec norm tool; spec=$(tool_arg key)
    [[ -n "$spec" ]] || { printf 'key required (e.g. "Return", "cmd+s", "ctrl+shift+t")'; return 1; }
    norm=$(_cua_key_norm "$spec") || { printf 'invalid key spec: use up to 5 alphanumeric tokens joined by "+" (punctuation goes through cua_type)'; return 1; }
    tool=$(_cua_key_tool); [[ -n "$tool" ]] || { printf 'no keyboard backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    confirm_action "Press key: $spec" "cua key $norm" || { confirm_denied_msg; return 1; }
    local -a toks=(); IFS='+' read -ra toks <<< "$norm"
    local last="${toks[-1]}"; local -a mods=(); local t
    for t in "${toks[@]:0:${#toks[@]}-1}"; do mods+=("$t"); done
    case "$tool" in
        xdotool)
            local chain="" m; for m in "${mods[@]}"; do chain+="$(_cua_map_key xdotool "$m")+"; done
            chain+="$(_cua_map_key xdotool "$last")"
            xdotool key --clearmodifiers "$chain" 2>&1 && printf 'pressed %s' "$spec" ;;
        wtype)
            local -a args=(); local m
            for m in "${mods[@]}"; do args+=(-M "$(_cua_map_key wtype "$m")"); done
            args+=(-k "$(_cua_map_key wtype "$last")")
            for m in "${mods[@]}"; do args+=(-m "$(_cua_map_key wtype "$m")"); done
            wtype "${args[@]}" 2>&1 && printf 'pressed %s' "$spec" ;;
        cliclick)
            # cliclick: named keys via kp:; a lettered/number key via t: (held under
            # any modifiers with kd:/ku:). Modifier names: cmd,ctrl,alt,shift,fn.
            local -a cmods=(); local m mm
            for m in "${mods[@]}"; do
                case "$m" in ctrl|control) mm=ctrl ;; alt|option|opt) mm=alt ;; shift) mm=shift ;; cmd|command|super|meta|win) mm=cmd ;; *) mm="" ;; esac
                [[ -n "$mm" ]] && cmods+=("$mm")
            done
            local named=""
            case "$last" in
                enter|return) named=return ;; esc|escape) named=esc ;; space) named=space ;; tab) named=tab ;;
                delete|del) named=delete ;; up) named=arrow-up ;; down) named=arrow-down ;; left) named=arrow-left ;; right) named=arrow-right ;;
                home) named=home ;; end) named=end ;; pageup) named=page-up ;; pagedown) named=page-down ;;
                f[0-9]|f1[0-9]) named="$last" ;;
            esac
            local mod_csv; mod_csv=$(IFS=,; printf '%s' "${cmods[*]}")
            if [[ ${#cmods[@]} -gt 0 ]]; then
                if [[ -n "$named" ]]; then cliclick "kd:$mod_csv" "kp:$named" "ku:$mod_csv" 2>&1
                else cliclick "kd:$mod_csv" "t:$last" "ku:$mod_csv" 2>&1; fi
            else
                if [[ -n "$named" ]]; then cliclick "kp:$named" 2>&1
                else cliclick "t:$last" 2>&1; fi
            fi && printf 'pressed %s' "$spec" ;;
        osascript)
            # System Events fallback: chords with a single character via `keystroke`.
            local using="" m
            for m in "${mods[@]}"; do case "$m" in cmd|command|super|meta|win) using+="command down, " ;; ctrl|control) using+="control down, " ;; alt|option|opt) using+="option down, " ;; shift) using+="shift down, " ;; esac; done
            using="${using%, }"
            if [[ "$last" =~ ^[a-z0-9]$ ]]; then
                if [[ -n "$using" ]]; then osascript -e "tell application \"System Events\" to keystroke \"$last\" using {$using}" 2>&1
                else osascript -e "tell application \"System Events\" to keystroke \"$last\"" 2>&1; fi && printf 'pressed %s' "$spec"
            else
                printf 'named-key chords need cliclick on macOS (System Events fallback handles only single-character chords): brew install cliclick'; return 1
            fi ;;
    esac
}

# ── scroll — scroll vertically by `amount` ticks (negative = up). Gated. ─────
tool_cua_scroll() {
    local amt tool; amt=$(tool_arg amount 3)
    [[ "$amt" =~ ^-?[0-9]+$ ]] || { printf 'amount must be an integer (negative scrolls up)'; return 1; }
    tool=$(_cua_pointer_tool); [[ -n "$tool" ]] || { printf 'no pointer backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    confirm_action "Scroll by $amt tick(s)" "cua scroll $amt" || { confirm_denied_msg; return 1; }
    local n abs=$amt dir=down; [[ "$amt" -lt 0 ]] && { abs=$(( -amt )); dir=up; }
    case "$tool" in
        xdotool)
            local b=5; [[ "$dir" == up ]] && b=4
            for ((n=0;n<abs;n++)); do xdotool click "$b" 2>&1; done && printf 'scrolled %s %s' "$dir" "$abs" ;;
        cliclick)
            # cliclick has no wheel; use a tiny AppleScript via System Events is not
            # reliable either — fall back to python3 + Quartz when available.
            if command -v python3 &>/dev/null; then
                python3 - "$dir" "$abs" <<'PY' 2>&1 && printf 'scrolled %s %s' "$dir" "$abs"
import sys
try:
    import Quartz
except Exception:
    sys.exit("macOS scroll needs pyobjc Quartz (pip install pyobjc-framework-Quartz) or use xdotool on X11")
d, n = sys.argv[1], int(sys.argv[2])
step = 3 if d == "up" else -3
for _ in range(n):
    e = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, step)
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, e)
PY
            else
                printf 'macOS scroll needs python3 + pyobjc Quartz (pip install pyobjc-framework-Quartz)'; return 1
            fi ;;
        ydotool)
            # ydotool wheel: `ydotool mousemove --wheel` is not universal; try the
            # click-based wheel codes, else report honestly.
            local code=0x02; [[ "$dir" == up ]] && code=0x01
            for ((n=0;n<abs;n++)); do ydotool click "$code" 2>&1; done && printf 'scrolled %s %s' "$dir" "$abs" \
                || { printf 'scroll may be unsupported by this ydotool build'; return 1; } ;;
    esac
}

# ── drag — press at (x1,y1), move to (x2,y2), release. Gated. ────────────────
tool_cua_drag() {
    local x1 y1 x2 y2 tool
    x1=$(_cua_coord "$(tool_arg x1)"); y1=$(_cua_coord "$(tool_arg y1)")
    x2=$(_cua_coord "$(tool_arg x2)"); y2=$(_cua_coord "$(tool_arg y2)")
    [[ -n "$x1" && -n "$y1" && -n "$x2" && -n "$y2" ]] || { printf 'x1,y1,x2,y2 (non-negative integers) required'; return 1; }
    tool=$(_cua_pointer_tool); [[ -n "$tool" ]] || { printf 'no pointer backend for %s — %s' "$(_cua_ds)" "$(_cua_input_hint)"; return 1; }
    confirm_action "Drag from $x1,$y1 to $x2,$y2" "cua drag" || { confirm_denied_msg; return 1; }
    case "$tool" in
        cliclick) cliclick "dd:$x1,$y1" "du:$x2,$y2" 2>&1 ;;
        xdotool)  xdotool mousemove "$x1" "$y1" mousedown 1 mousemove "$x2" "$y2" mouseup 1 2>&1 ;;
        ydotool)  { ydotool mousemove --absolute -- "$x1" "$y1" && ydotool click 0x40 && ydotool mousemove --absolute -- "$x2" "$y2" && ydotool click 0x80; } 2>&1 ;;
    esac && printf 'dragged %s,%s -> %s,%s' "$x1" "$y1" "$x2" "$y2"
}

# ── find_text — OCR the screen and locate a word/phrase, optionally click it. ─
# This is the piece that makes the CUA loop usable by a model that CANNOT see the
# screen: instead of guessing pixel coordinates, it asks "where does it say
# 'Submit'?" and gets back {x,y} (and can click). Composes a screenshot backend +
# tesseract (word-box TSV) + a pointer backend. Coordinates are OCR pixel centers
# scaled to logical points (a Retina screenshot is 2x the points the pointer
# tools expect). Gated `writes` — it captures the screen and may click.
tool_cua_find_text() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    command -v tesseract &>/dev/null || { printf 'cua_find_text needs tesseract: brew install tesseract  /  apt install tesseract-ocr'; return 1; }
    local query; query=$(tool_arg text)
    [[ -n "$query" ]] || { printf 'text required (the on-screen word/phrase to find)'; return 1; }
    [[ "$query" == *$'\n'* ]] && { printf 'text must be a single line'; return 1; }
    local click; click=$(tool_arg click false)
    confirm_action "Capture the screen and OCR-search for \"$query\"$([[ "$click" == true ]] && printf ' then click it')" "cua find_text ($(_cua_ds))" || { confirm_denied_msg; return 1; }

    local tmp; tmp=$(path_temp_file yca-cua-find .png)
    local err; err=$(_cua_shoot "$tmp" 0 0 0 0) || { rm -f "$tmp"; printf '%s' "$err"; return 1; }
    [[ -f "$tmp" ]] || { printf 'screenshot failed (no file produced). %s' "$err"; return 1; }

    # px -> pt scale: screenshot pixel width vs logical screen width. Unknown → 1:1.
    local shot_w=0 screen_w scale="1"
    if command -v sips &>/dev/null; then shot_w=$(sips -g pixelWidth "$tmp" 2>/dev/null | awk '/pixelWidth/{print $2}')
    elif command -v identify &>/dev/null; then shot_w=$(identify -format '%w' "$tmp" 2>/dev/null); fi
    screen_w=$(tool_cua_screen_size 2>/dev/null | grep -oE '[0-9]+' | head -1)
    [[ "$shot_w" =~ ^[0-9]+$ && "$screen_w" =~ ^[0-9]+$ && "$shot_w" -gt 0 ]] \
        && scale=$(awk -v s="$screen_w" -v p="$shot_w" 'BEGIN{printf "%.6f", s/p}')

    # OCR to word-box TSV (psm 11 = sparse text, best for scattered UI labels),
    # then match the query as consecutive words on one line; emit scaled centers.
    local matches
    matches=$(tesseract "$tmp" - --psm 11 tsv 2>/dev/null | awk -v q="$query" -v scale="$scale" '
        BEGIN{ n=split(tolower(q), qw, /[ \t]+/); FS="\t" }
        NR==1 { next }
        $1==5 && $12!="" {
            key=$2"_"$3"_"$4"_"$5; i=++cnt[key]
            wt[key,i]=tolower($12); L[key,i]=$7; T[key,i]=$8; W[key,i]=$9; H[key,i]=$10; C[key,i]=$11
        }
        END{
            for (k in cnt) { m=cnt[k]
                for (s=1; s+n-1<=m; s++) {
                    ok=1; for (j=1;j<=n;j++) if (wt[k,s+j-1]!=qw[j]) { ok=0; break }
                    if (!ok) continue
                    x1=L[k,s]; x2=L[k,s+n-1]+W[k,s+n-1]
                    cx=int((x1+x2)/2*scale); cy=int((T[k,s]+H[k,s]/2)*scale)
                    conf=0; for (j=1;j<=n;j++) conf+=C[k,s+j-1]; conf=int(conf/n)
                    printf "%d\t%d\t%d\n", cx, cy, conf
                }
            }
        }' | sort -t"$(printf '\t')" -k3 -rn | head -10)
    rm -f "$tmp"
    [[ -n "$matches" ]] || { printf 'no on-screen text matched "%s"' "$query"; return 1; }

    local json
    json=$(printf '%s' "$matches" | jq -R -s --arg q "$query" \
        'split("\n")|map(select(length>0)|split("\t"))|{matches:map({text:$q,x:(.[0]|tonumber),y:(.[1]|tonumber),confidence:(.[2]|tonumber)})}')

    if [[ "$click" == "true" ]]; then
        local bx by ptool; bx=$(printf '%s' "$matches" | head -1 | cut -f1); by=$(printf '%s' "$matches" | head -1 | cut -f2)
        ptool=$(_cua_pointer_tool)
        if [[ -n "$ptool" && -n "$bx" && -n "$by" ]]; then
            case "$ptool" in
                cliclick) cliclick "c:$bx,$by" >/dev/null 2>&1 ;;
                xdotool)  xdotool mousemove "$bx" "$by" click 1 >/dev/null 2>&1 ;;
                ydotool)  { ydotool mousemove --absolute -- "$bx" "$by" 2>/dev/null || ydotool mousemove -a "$bx" "$by"; ydotool click 0xC0; } >/dev/null 2>&1 ;;
            esac
            printf 'clicked best match at %s,%s\n%s' "$bx" "$by" "$json"; return 0
        fi
        printf 'found match(es) but no pointer backend to click — %s\n%s' "$(_cua_input_hint)" "$json"; return 0
    fi
    printf '%s' "$json"
}

# ── Semantic / accessibility half (the pi-computer-use "act_ui" model) ────────
# The pixel half above (screenshot / click-by-coord / find_text) is fragile. This
# half is the accessibility approach from the pi-computer-use architecture: build
# a structured SNAPSHOT of the UI's elements, ACT on an element by its semantic
# identity (role + name) instead of its pixels, and DIFF two snapshots into the
# MINIMAL change-set. Those are the reconciler's Snapshot Collector, act_ui, and
# Tree Differ — shipped as stateless, composable tools (the MCP host owns the
# snapshot→find→act→snapshot→diff loop, exactly as Yantra assigns the loop to the
# host). snapshot/act are per-OS (macOS AX via System Events is implemented;
# Linux AT-SPI is an honest degrade for now); diff/find are pure JSON and work
# everywhere. snapshot (reads on-screen text) and act (drives the UI) are gated.

# _cua_ax_perm TXT -> 0 if TXT is a macOS accessibility permission/authorisation error.
_cua_ax_perm() { case "$1" in *[Nn]ot\ authoris*|*[Nn]ot\ authoriz*|*-1743*|*-25211*|*assistive*) return 0 ;; *) return 1 ;; esac; }
_cua_ax_perm_msg() { printf 'macOS refused accessibility access. Grant it in System Settings ▸ Privacy & Security ▸ Accessibility (and Automation) for the terminal/host running Yantra, then retry.'; }

# _cua_atspi_unavailable — the honest Linux message (AT-SPI backend not wired yet).
_cua_atspi_unavailable() { printf 'accessibility snapshot/act is implemented for macOS (System Events). On Linux it needs an AT-SPI backend (python3 + pyatspi) that is not wired up yet — use the pixel half (screenshot/ocr/find_text/click) meanwhile. ui_diff and ui_find work on any snapshot JSON.'; }

# ── ui_snapshot — the frontmost (or named) app's accessibility elements as JSON.
# Flat element list: {ref, role, name, value, enabled, x, y}. Gated `writes` — it
# reads all on-screen text/values (privacy), like a screenshot.
tool_cua_ui_snapshot() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    local app maxn; app=$(tool_arg app "$(tool_arg window '')"); maxn=$(int_guard "$(tool_arg max 150)" 150)
    (( maxn < 1 )) && maxn=1; (( maxn > 500 )) && maxn=500
    confirm_action "Read the accessibility tree of ${app:-the frontmost app}" "cua ui_snapshot ($(_cua_ds))" || { confirm_denied_msg; return 1; }
    case "$(_cua_ds)" in
        quartz)
            command -v osascript &>/dev/null || { printf 'osascript missing (macOS only)'; return 1; }
            local raw; raw=$(osascript - "$maxn" "$app" <<'OSA' 2>&1
on run argv
  set maxN to (item 1 of argv) as integer
  set procName to item 2 of argv
  with timeout of 20 seconds
    tell application "System Events"
      if procName is "" then set procName to name of first process whose frontmost is true
      if not (exists process procName) then return "ERR: no such app: " & procName
      tell process procName
        if (count of windows) is 0 then return "ERR: app has no window: " & procName
        set allEls to entire contents of window 1
      end tell
    end tell
  end timeout
  set out to procName & tab & "__APP__" & linefeed
  set n to 0
  repeat with e in allEls
    if n >= maxN then exit repeat
    set r to ""
    set nm to ""
    set vl to ""
    set en to "false"
    set px to ""
    set py to ""
    try
      set r to (role of e) as text
    end try
    try
      set nm to (name of e) as text
    end try
    try
      set vl to (value of e) as text
    end try
    try
      if (enabled of e) then set en to "true"
    end try
    try
      set pp to position of e
      set px to (item 1 of pp) as text
      set py to (item 2 of pp) as text
    end try
    set out to out & r & tab & nm & tab & vl & tab & en & tab & px & tab & py & linefeed
    set n to n + 1
  end repeat
  return out
end run
OSA
)
            _cua_ax_perm "$raw" && { _cua_ax_perm_msg; return 1; }
            case "$raw" in 'ERR: '*) printf '%s' "${raw#ERR: }"; return 1 ;; esac
            local appname; appname=$(printf '%s' "$raw" | head -1 | cut -f1)
            printf '%s' "$raw" | tail -n +2 | jq -R -s --arg app "$appname" '
                {app:$app, backend:"macos-ax",
                 elements: (split("\n") | map(select(length>0) | split("\t"))
                   | to_entries
                   | map({ref:(.key+1), role:.value[0], name:.value[1], value:.value[2],
                          enabled:(.value[3]=="true"),
                          x:(.value[4]|tonumber?), y:(.value[5]|tonumber?)}))}
                | .count=(.elements|length)' 2>/dev/null \
                || { printf 'could not parse the accessibility tree'; return 1; }
            ;;
        x11|wayland) _cua_atspi_unavailable; return 1 ;;
        *) printf 'no accessibility backend for this display server'; return 1 ;;
    esac
}

# ── act — perform an action on an element by its semantic identity (role+name),
# not its pixels (the act_ui primitive). action: press (default; toggles a
# checkbox), focus, or setvalue (+ .value). .index disambiguates duplicate names.
tool_cua_act() {
    _cua_have_display || { printf 'no display server detected (headless)'; return 1; }
    local name role action value idx
    name=$(tool_arg name); [[ -n "$name" ]] || { printf 'name required (the element'\''s accessible name/label)'; return 1; }
    role=$(tool_arg role ''); action=$(tool_arg action press); value=$(tool_arg value '')
    idx=$(int_guard "$(tool_arg index 1)" 1); (( idx < 1 )) && idx=1
    local ax; case "$action" in
        press|click|toggle) ax=press ;;
        focus)              ax=focus ;;
        setvalue|set)       ax=setvalue ;;
        *) printf 'action must be press|toggle|focus|setvalue'; return 1 ;;
    esac
    confirm_action "act '$action' on element ${role:+$role }\"$name\"${idx:+ #$idx}" "cua act ($(_cua_ds))" || { confirm_denied_msg; return 1; }
    case "$(_cua_ds)" in
        quartz)
            command -v osascript &>/dev/null || { printf 'osascript missing (macOS only)'; return 1; }
            local out; out=$(osascript - "$role" "$name" "$ax" "$value" "$idx" <<'OSA' 2>&1
on run argv
  set R to item 1 of argv
  set NM to item 2 of argv
  set ACT to item 3 of argv
  set VAL to item 4 of argv
  set IDX to (item 5 of argv) as integer
  with timeout of 20 seconds
    tell application "System Events"
      set procName to name of first process whose frontmost is true
      tell process procName
        if (count of windows) is 0 then return "ERR: app has no window"
        set allEls to entire contents of window 1
        set c to 0
        repeat with e in allEls
          set okr to true
          set okn to false
          try
            if R is not "" then set okr to ((role of e) as text is R)
          end try
          try
            set okn to ((name of e) as text is NM)
          end try
          if okr and okn then
            set c to c + 1
            if c is IDX then
              try
                if ACT is "setvalue" then
                  set value of e to VAL
                else if ACT is "focus" then
                  set focused of e to true
                else
                  perform action "AXPress" of e
                end if
                return "OK"
              on error errm
                return "ERR: " & errm
              end try
            end if
          end if
        end repeat
        return "NOTFOUND"
      end tell
    end tell
  end timeout
end run
OSA
)
            _cua_ax_perm "$out" && { _cua_ax_perm_msg; return 1; }
            case "$out" in
                OK) printf 'acted (%s) on "%s"' "$action" "$name" ;;
                NOTFOUND) printf 'no element matching %s"%s"%s — snapshot first (cua_ui_snapshot) to see exact roles/names' "${role:+role=$role }" "$name" "$([[ "$idx" -gt 1 ]] && printf " at index $idx")"; return 1 ;;
                'ERR: '*) printf 'action failed: %s' "${out#ERR: }"; return 1 ;;
                *) printf '%s' "$out"; return 1 ;;
            esac
            ;;
        x11|wayland) _cua_atspi_unavailable; return 1 ;;
        *) printf 'no accessibility backend for this display server'; return 1 ;;
    esac
}

# ── ui_diff — the MINIMAL change-set between two ui_snapshot JSONs (the Tree
# Differ / Change Encoder). Elements are matched by semantic identity
# (role + name + Nth occurrence); reports added / removed / changed props. Pure
# JSON, deterministic, cross-platform, `safe`. This is the diagram's ui_diff.
tool_cua_ui_diff() {
    local before after
    before=$(tool_arg before); after=$(tool_arg after)
    [[ -n "$before" && -n "$after" ]] || { printf 'before and after (two ui_snapshot JSON objects) required'; return 1; }
    local be ae
    be=$(printf '%s' "$before" | jq -c '.elements // .' 2>/dev/null) || { printf 'before is not valid JSON'; return 1; }
    ae=$(printf '%s' "$after"  | jq -c '.elements // .' 2>/dev/null) || { printf 'after is not valid JSON'; return 1; }
    jq -n --argjson b "$be" --argjson a "$ae" '
      def occkey:
        . as $arr
        | reduce range(0; ($arr|length)) as $i ({s:{}, o:[]};
            ($arr[$i]) as $e
            | (($e.role//"") + "" + ($e.name//"")) as $g
            | (.s[$g] // 0) as $c
            | .s[$g] = ($c+1)
            | .o += [ $e + {k: ($g + "" + ($c|tostring))} ]
          ) | .o;
      ($b | occkey) as $B | ($a | occkey) as $A
      | ($B | map({(.k): .}) | add // {}) as $bm
      | ($A | map({(.k): .}) | add // {}) as $am
      | { added:   [ $A[] | select($bm[.k]==null) | {role, name, value, enabled} ],
          removed: [ $B[] | select($am[.k]==null) | {role, name, value, enabled} ],
          changed: [ $A[] | select($bm[.k]!=null) | . as $x | ($bm[.k]) as $o
                     | select(($x.value!=$o.value) or ($x.enabled!=$o.enabled))
                     | {role, name,
                        value:   (if $x.value!=$o.value     then [$o.value,$x.value]     else null end),
                        enabled: (if $x.enabled!=$o.enabled then [$o.enabled,$x.enabled] else null end)} ] }
      | . + {summary: "added=\(.added|length) removed=\(.removed|length) changed=\(.changed|length)"}' 2>/dev/null \
      || { printf 'diff failed — are both arguments valid ui_snapshot JSON?'; return 1; }
}

# ── ui_find — query a ui_snapshot JSON for elements by role/name/value substring
# (case-insensitive). Pure JSON, `safe`. Composes with ui_snapshot → act.
tool_cua_ui_find() {
    local tree role name value
    tree=$(tool_arg tree "$(tool_arg snapshot '')")
    [[ -n "$tree" ]] || { printf 'tree (a ui_snapshot JSON object) required'; return 1; }
    role=$(tool_arg role ''); name=$(tool_arg name ''); value=$(tool_arg value '')
    local els; els=$(printf '%s' "$tree" | jq -c '.elements // .' 2>/dev/null) || { printf 'tree is not valid JSON'; return 1; }
    printf '%s' "$els" | jq --arg r "$role" --arg n "$name" --arg v "$value" '
      [ .[] | select(
          ($r=="" or ((.role//"") |ascii_downcase|contains($r|ascii_downcase))) and
          ($n=="" or ((.name//"") |ascii_downcase|contains($n|ascii_downcase))) and
          ($v=="" or ((.value//""|tostring)|ascii_downcase|contains($v|ascii_downcase)))) ]
      | {count:length, matches:.}' 2>/dev/null || { printf 'find failed (is tree a valid snapshot?)'; return 1; }
}

# ── llm_explain — suggest the next CUA action toward a goal. LLM (mid). ──────
# Grounds on the current window list + active window (+ optional OCR text passed
# in), since the model can't see raw pixels here.
tool_cua_llm_explain() {
    local goal; goal=$(tool_arg goal "$1")
    [[ -n "$goal" ]] || { printf 'a goal (what you want to accomplish) is required'; return 1; }
    local ctx=""
    ctx+="display: $(_cua_ds)\n"
    ctx+="active window: $(tool_cua_active_window 2>/dev/null)\n"
    ctx+="visible windows:\n$(tool_cua_list_windows 2>/dev/null | head -30)\n"
    local system_prompt='You are a computer-use (CUA) operator. Given the current display context and the user goal, recommend the SINGLE next yantra cua_* call to make (one of: screenshot, ocr, move, click, type, key, scroll, drag) with exact arguments, and say briefly why. Prefer taking a screenshot/ocr first when you cannot yet locate the target on screen.'
    llm_analyze "$system_prompt" "$(printf 'GOAL: %s\n\nCONTEXT:\n%b' "$goal" "$ctx")"
}

# ── Register (category: cua) ─────────────────────────────────────────────────
tool_register "cua_doctor"          tool_cua_doctor          '{"type":"object","properties":{}}' safe all cua
tool_register "cua_screen_size"     tool_cua_screen_size     '{"type":"object","properties":{}}' safe all cua
tool_register "cua_cursor_position" tool_cua_cursor_position '{"type":"object","properties":{}}' safe all cua
tool_register "cua_list_windows"    tool_cua_list_windows    '{"type":"object","properties":{}}' safe all cua
tool_register "cua_active_window"   tool_cua_active_window   '{"type":"object","properties":{}}' safe all cua
tool_register "cua_screenshot"      tool_cua_screenshot      '{"type":"object","properties":{"out":{"type":"string","description":"output PNG path in-tree (default: cua_shot_<time>.png)"},"x":{"type":"integer","description":"region left (with width/height)"},"y":{"type":"integer","description":"region top"},"width":{"type":"integer","description":"region width (0 = full screen)"},"height":{"type":"integer","description":"region height"}}}' writes all cua
tool_register "cua_ocr"             tool_cua_ocr             '{"type":"object","properties":{"x":{"type":"integer","description":"region left"},"y":{"type":"integer","description":"region top"},"width":{"type":"integer","description":"region width (0 = full screen)"},"height":{"type":"integer","description":"region height"}}}' writes all cua
tool_register "cua_move"            tool_cua_move            '{"type":"object","properties":{"x":{"type":"integer","description":"target x"},"y":{"type":"integer","description":"target y"}},"required":["x","y"]}' writes all cua
tool_register "cua_click"           tool_cua_click           '{"type":"object","properties":{"x":{"type":"integer","description":"click x (omit to click the current point)"},"y":{"type":"integer","description":"click y"},"button":{"type":"string","enum":["left","right","middle"],"description":"mouse button (default left)"},"count":{"type":"integer","description":"click count 1-3 (2 = double)"}}}' writes all cua
tool_register "cua_type"            tool_cua_type            '{"type":"object","properties":{"text":{"type":"string","description":"the literal text to type"}},"required":["text"]}' writes all cua
tool_register "cua_press_key"             tool_cua_press_key             '{"type":"object","properties":{"key":{"type":"string","description":"a key or chord, e.g. Return, Escape, cmd+s, ctrl+shift+t"}},"required":["key"]}' writes all cua
tool_register "cua_scroll"          tool_cua_scroll          '{"type":"object","properties":{"amount":{"type":"integer","description":"scroll ticks; negative scrolls up"}}}' writes all cua
tool_register "cua_drag"            tool_cua_drag            '{"type":"object","properties":{"x1":{"type":"integer","description":"start x"},"y1":{"type":"integer","description":"start y"},"x2":{"type":"integer","description":"end x"},"y2":{"type":"integer","description":"end y"}},"required":["x1","y1","x2","y2"]}' writes all cua
tool_register "cua_find_text"       tool_cua_find_text       '{"description":"OCR the screen, locate a word/phrase, return its coordinates (and optionally click it)","type":"object","properties":{"text":{"type":"string","description":"the on-screen word or phrase to find"},"click":{"type":"boolean","description":"click the best match (default false)"}},"required":["text"]}' writes all cua
tool_register "cua_ui_snapshot"     tool_cua_ui_snapshot     '{"description":"Structured accessibility snapshot of the frontmost (or named) app: elements with role/name/value/enabled/position (the reconciler Snapshot Collector). macOS via System Events.","type":"object","properties":{"app":{"type":"string","description":"app/process name (default: the frontmost app)"},"max":{"type":"integer","description":"max elements 1-500 (default 150)"}}}' writes all cua
tool_register "cua_act"             tool_cua_act             '{"description":"Act on a UI element by its semantic identity (role+name), not pixels — the act_ui primitive.","type":"object","properties":{"name":{"type":"string","description":"the element'"'"'s accessible name/label"},"role":{"type":"string","description":"optional role filter, e.g. AXButton, AXCheckBox"},"action":{"type":"string","enum":["press","toggle","focus","setvalue"],"description":"press (default; toggles a checkbox), focus, or setvalue"},"value":{"type":"string","description":"new value when action=setvalue"},"index":{"type":"integer","description":"which match if the name repeats (1-based, default 1)"}},"required":["name"]}' writes all cua
tool_register "cua_ui_diff"         tool_cua_ui_diff         '{"description":"Minimal change-set between two ui_snapshot JSONs (added/removed/changed elements) — the reconciler Tree Differ. Pure JSON, deterministic.","type":"object","properties":{"before":{"type":"object","description":"an earlier ui_snapshot result"},"after":{"type":"object","description":"a later ui_snapshot result"}},"required":["before","after"]}' safe all cua
tool_register "cua_ui_find"         tool_cua_ui_find         '{"description":"Query a ui_snapshot JSON for elements by role/name/value substring (case-insensitive).","type":"object","properties":{"tree":{"type":"object","description":"a ui_snapshot result"},"role":{"type":"string","description":"role substring filter"},"name":{"type":"string","description":"name substring filter"},"value":{"type":"string","description":"value substring filter"}},"required":["tree"]}' safe all cua
tool_register "cua_llm_explain"     tool_cua_llm_explain     '{"type":"object","properties":{"goal":{"type":"string","description":"what you want to accomplish on screen"}},"required":["goal"]}' safe all cua mid
