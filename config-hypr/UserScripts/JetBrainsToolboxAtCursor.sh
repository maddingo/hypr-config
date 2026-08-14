#!/usr/bin/env bash
# ==================================================
#  Place the JetBrains Toolbox popup at the mouse pointer.
# ==================================================
#
# Toolbox is an XWayland window that positions itself where it believes its
# system-tray icon is. Under Hyprland there is no tray it can locate, so it
# picks a stale guess -- observed at global x=-806 (off-screen, left of eDP-1)
# and at the top-right corner of whichever monitor it last computed. The window
# is 440x700 with WM_NORMAL_HINTS min size == max size, and it sets
# `user specified location`, i.e. the X11 USPosition hint.
#
# Window rules cannot fix this. Verified by testing on Hyprland 0.56.2:
#   - `match:class ^jetbrains-toolbox$, workspace 7`  -> works, so the rule
#     itself matches (initialClass is already "jetbrains-toolbox" at map time).
#   - `... move 300 300` and `... center on`          -> silently ignored; the
#     USPosition hint is applied after the rule and wins.
#   - `... size 800 600`                              -> ignored; min == max
#     size hints.
# So the position has to be corrected *after* the window maps, which is what
# this script does. `movewindowpixel exact` does stick (re-checked 3s later).
#
# Usage:
#   --listener   subscribe to the Hyprland event socket and reposition every
#                Toolbox window as it opens (exec-once from Startup_Apps.conf).
#                This covers every way the popup can be raised -- tray icon,
#                keybind, Toolbox's own global shortcut.
#   --place      reposition the currently focused window once, by hand.
#   (no args)    make sure a listener is running, then exit -- for restarting it
#                without logging out. Nothing in the config depends on this mode.

set -uo pipefail

CLASS="jetbrains-toolbox"
# Offsets are negative on purpose: the top-left corner goes slightly *above and
# left* of the pointer, so the pointer ends up just inside the popup. With a
# positive offset the popup lands next to the pointer instead, and with
# follow_mouse = 1 the first pixel of pointer drift hands focus straight back to
# the window underneath -- Toolbox is then open but not accepting keystrokes.
OFFSET_X=-16
OFFSET_Y=-16

SCRIPT_NAME="$(basename "$0")"
SCRIPT_PATH="$(readlink -f "$0")"

socket2_path() {
    local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
    local sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$sig/.socket2.sock"
    if [[ ! -S "$sock" ]]; then
        # HYPRLAND_INSTANCE_SIGNATURE moves when Hyprland restarts and is not
        # always inherited by whatever spawned us.
        sig=$(hyprctl instances -j | jq -r '.[0].instance' 2>/dev/null)
        sock="${XDG_RUNTIME_DIR:-/run/user/$UID}/hypr/$sig/.socket2.sock"
    fi
    printf '%s\n' "$sock"
}

# Move window $1 (bare address, no 0x) next to the pointer, clamped so the whole
# window stays inside the usable area of the monitor the pointer is on.
place_at_cursor() {
    local addr="0x${1#0x}"
    local cx cy ww wh win_ws mx my mw mh mon_ws x y batch

    IFS=', ' read -r cx cy <<<"$(hyprctl cursorpos)"
    [[ -n "${cx:-}" && -n "${cy:-}" ]] || return 1

    read -r ww wh win_ws <<<"$(hyprctl -j clients |
        jq -r --arg a "$addr" '.[] | select(.address == $a) | "\(.size[0]) \(.size[1]) \(.workspace.id)"')"
    [[ -n "${ww:-}" && -n "${wh:-}" ]] || return 1

    # Logical monitor geometry minus reserved space (waybar), so the popup never
    # lands under the bar. A 90/270 transform swaps width and height.
    read -r mx my mw mh mon_ws <<<"$(hyprctl -j monitors | jq -r --argjson cx "$cx" --argjson cy "$cy" '
        map(.lw = ((if (.transform % 2) == 1 then .height else .width end) / .scale | floor)
          | .lh = ((if (.transform % 2) == 1 then .width else .height end) / .scale | floor))
        | map(select($cx >= .x and $cx < (.x + .lw) and $cy >= .y and $cy < (.y + .lh)))
        | first
        | "\(.x + .reserved[0]) \(.y + .reserved[1]) \(.lw - .reserved[0] - .reserved[2]) \(.lh - .reserved[1] - .reserved[3]) \(.activeWorkspace.id)"')"
    [[ -n "${mx:-}" && "$mx" != "null" ]] || return 1

    x=$((cx + OFFSET_X))
    y=$((cy + OFFSET_Y))
    # Clamp bottom/right first, then top/left, so a window taller than the
    # usable area still starts at the top edge instead of above it.
    ((x + ww > mx + mw)) && x=$((mx + mw - ww))
    ((y + wh > my + mh)) && y=$((my + mh - wh))
    ((x < mx)) && x=$mx
    ((y < my)) && y=$my

    batch="dispatch movewindowpixel exact $x $y,address:$addr ; dispatch focuswindow address:$addr"
    # movewindowpixel does not reassign the workspace, so if the pointer is on a
    # different monitor than the one Toolbox opened on, the window would keep a
    # workspace belonging to the old monitor and get clipped away. Hand it to the
    # workspace that is actually visible where we are about to draw it.
    if [[ -n "${win_ws:-}" && "$win_ws" != "$mon_ws" ]]; then
        batch="dispatch movetoworkspacesilent $mon_ws,address:$addr ; $batch"
    fi

    hyprctl --batch "$batch" >/dev/null
}

subscribe() {
    local sock line addr
    sock=$(socket2_path)
    [[ -S "$sock" ]] || {
        echo "Error: Hyprland event socket not found." >&2
        exit 1
    }

    socat -u UNIX-CONNECT:"$sock" - | while read -r line; do
        # openwindow>>ADDRESS,WORKSPACE,CLASS,TITLE -- the class is already set
        # here, unlike in some XWayland cases.
        case "$line" in
        "openwindow>>"*",$CLASS,"*)
            addr=${line#openwindow>>}
            addr=${addr%%,*}
            # Let the app finish applying its own USPosition before overriding.
            sleep 0.1
            place_at_cursor "$addr"
            ;;
        esac
    done
}

ensure_listener() {
    # pgrep only -- never pkill -f here: -f matches any shell whose command line
    # merely contains this pattern, including the one that invoked us.
    pgrep -f "$SCRIPT_NAME --listener" | grep -qv "^$$\$" && return 0
    setsid "$SCRIPT_PATH" --listener >/dev/null 2>&1 &
}

case "${1:-}" in
--listener)
    subscribe
    ;;
--place)
    place_at_cursor "$(hyprctl activewindow -j | jq -r '.address')"
    ;;
"")
    ensure_listener
    ;;
*)
    echo "Usage: $SCRIPT_NAME [--listener|--place]" >&2
    exit 1
    ;;
esac
