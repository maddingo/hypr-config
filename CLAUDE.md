# hypr-config

Hyprland dotfiles, based on the KooL / LinuxBeginnings dotfiles. Ubuntu 24.04, AMD GPU,
Hyprland 0.56.2.

## Layout

`~/.config/hypr` is a **symlink** to `config-hypr/` in this repo. Editing files here edits
the live config — there is no copy/install step. `hyprctl reload` applies changes.

Three monitors: `eDP-1` 1920x1200@120 (laptop), plus two Lenovo P27h-20 2560x1440@59.95
externals. Mixed refresh rates.

**DisplayPort connector names are not stable here.** The externals have shown up as
`DP-8`/`DP-10` and other numbers across reboots (MST/DP-hub enumeration order), which used
to scramble the layout and workspace bindings. `monitors.conf` and `workspaces.conf` are
therefore **hand-maintained and match on EDID description**, not connector name:

- `monitor = desc:Lenovo Group Limited P27h-20 V906YWA0,...` — middle screen
- `monitor = desc:Lenovo Group Limited P27h-20 V907BZ2P,...` — right screen
- `eDP-1` has an *empty* description, so it must be matched by connector name (fine — an
  internal panel's name is stable).

Same model twice, so the **serial is the only disambiguator**; keep it in the desc string.
Descriptions come from `hyprctl monitors -j | jq -r '.[] | "\(.name)\t\(.description)"'`.

**Do not re-run nwg-displays.** It only ever writes connector names (0.3.22 has no
description option — its flags are just `-m`, `-n`, `-v`), so it silently reintroduces the
bug and wipes the comments. To change geometry, edit the two files by hand. If it gets run
by accident: `git checkout config-hypr/monitors.conf config-hypr/workspaces.conf`.

## Update-safe vs. not

- `config-hypr/configs/*.conf` — upstream KooL defaults. **Overwritten by dotfiles updates.**
- `config-hypr/UserConfigs/*.conf` — user-owned, documented as surviving updates. **Put
  customizations here.**

Source order is in `hyprland.conf` (`configs/` then `UserConfigs/` for each pair). This
matters for tags: a `tag +foo` rule must be sourced *before* any `match:tag foo` rule.

Two local changes currently live in the **non**-update-safe `configs/` tree and will need
re-applying if an upstream update reverts them:

- `configs/SystemSettings.conf` — `on_focus_under_fullscreen = 0` (was `1`)
- `configs/WindowRules.conf:36` — added `?` so bare class `microsoft-edge` matches the
  `browser` tag, like every other browser rule in that file

## Hyprland 0.56.2 windowrule syntax

**The rule parser accepts invalid values silently.** `hyprctl keyword windowrule ...`
returning `ok` does *not* mean the rule works — verify by observed effect, never by exit
status. Invalid *field names* do error (`invalid field type X`), but bad *values* don't.

Established by testing on this machine:

- `move` takes a **vec2 expression**. The old windowrulev2 `move cursor <x> <y>` keyword no
  longer exists. Use the expression variables instead: `move (cursor_x+12) (cursor_y+20)`.
- Do **not** combine `onscreen` with expressions. `move onscreen (expr) (expr)` is accepted
  and then silently falls back to centring. There is therefore no edge clamping available
  when using expressions.
- `no_border`, `no_rounding`, `no_decorations` are **not** valid fields. Use `border_size 0`
  and `rounding 0`. Valid: `no_anim`, `no_blur`, `no_dim`, `no_shadow`, `no_focus`,
  `no_initial_focus`.
- `float` requires a value: `float on`, not bare `float`.
- Multiple `windowrule` lines with the same selector stack rather than overriding.
- `tag +name` resolves in time for a `match:tag name` rule in the same map cycle.
- `move` coordinates are monitor-relative: `move 500 300` on a monitor at origin x=274
  lands at global x=774.
- A Wayland toplevel cannot position itself, so any window forced to `float` gets
  Hyprland's default placement — **dead centre of the monitor** — unless a `move` rule
  overrides it.
- **XWayland windows are the exception, and they win.** X11 clients *can* position and
  size themselves, and their hints are applied *after* window rules. A window that sets
  `user specified location` in `WM_NORMAL_HINTS` (USPosition) silently defeats `move` and
  `center`; one whose min size equals its max size silently defeats `size`. The rule still
  matches — `workspace N` on the same selector works fine — so this looks exactly like a
  non-matching selector. Check with `xprop -id <id> WM_NORMAL_HINTS` (get the id from
  `xwininfo -root -tree`) before blaming the matcher, and fix such windows with a post-map
  `hyprctl dispatch movewindowpixel exact X Y,address:0x…` instead. Unlike rule `move`,
  `movewindowpixel exact` takes **global** coordinates.

## Debugging window behaviour: read the event socket, don't read rules

For any "the window moved / resized / lost fullscreen / flickered by itself" problem, tail
Hyprland's event socket rather than reasoning about rule files:

```sh
socat -u UNIX-CONNECT:/run/user/$UID/hypr/$HYPRLAND_INSTANCE_SIGNATURE/.socket2.sock -
```

Timestamp each line. `openwindow>>ADDR,WORKSPACE,CLASS,TITLE` and the `fullscreen>>0|1`
transitions expose causal chains that are invisible in the config. This is the only reason
the Edge issue below was found; reading window rules led to two wrong conclusions first.

## Known: Edge renders tooltips as toplevel windows

Microsoft Edge creates its tooltips as real xdg toplevels with an **empty class and an
empty title** (Chrome uses anchored popups, which is why Chrome behaves fine). They show up
as `openwindow>>ADDR,2,,`, are ~52x28 to 163x28, and live a few seconds.

Two distinct bugs came from this:

1. **Window "flickering".** Tiled, each tooltip was inserted into the dwindle layout on the
   browser's own workspace and closed moments later, forcing two layout reflows in quick
   succession. Fixed by the `edge_tooltip` tag in `UserConfigs/WindowRules.conf`, which
   floats them (keeping them out of the layout) and re-positions them at the cursor.
2. **Fullscreen dropping out immediately.** With `on_focus_under_fullscreen = 1`, a tooltip
   inherited the fullscreen state on focus and destroyed it on close, so Super+F on the
   Outlook web app bounced straight back to windowed. Fixed by setting it to `0`.

The tooltip rule's `match:class ^$, match:title ^$` selector is deliberately isolated on one
line, because it matches *any* empty-class/empty-title toplevel, not just Edge's.

## Known: JetBrains Toolbox places its popup off-screen

The Toolbox popup (`class jetbrains-toolbox`, XWayland, fixed 440x700) positions itself where
it believes its system-tray icon is. There is no tray for it to find here, so it uses a stale
guess — observed both at the top-right of eDP-1 and at global **x=-806**, i.e. off-screen to
the left of eDP-1. It sets the USPosition hint, which is why `float on, center on` in
`configs/WindowRules.conf:262` has never actually centred it, and why no `move` rule can
(see the XWayland note under windowrule syntax).

Fixed by `UserScripts/JetBrainsToolboxAtCursor.sh --listener`, an `exec-once` from
`UserConfigs/Startup_Apps.conf`. It watches the event socket for
`openwindow>>…,jetbrains-toolbox,…` and re-places the window at the pointer, clamped to the
usable area of the monitor under the pointer. Two non-obvious details:

- The offsets are **negative** (pointer ends up *inside* the popup). With a positive offset
  the popup sits beside the pointer and, under `follow_mouse = 1`, the first pixel of pointer
  drift hands focus back to the window underneath — Toolbox visible but ignoring keystrokes.
  It does not self-focus on open, so the script focuses it explicitly.
- `movewindowpixel` does not reassign the workspace, so when the pointer is on a different
  monitor than the one Toolbox opened on the script issues `movetoworkspacesilent` first;
  otherwise the window keeps a workspace belonging to the other monitor and gets clipped.

The fix deliberately depends on nothing outside this repo. Super+Shift+J launches
`$HOME/opt/jetbrains-toolbox/bin/jetbrains-toolbox` directly; the old `~/bin/toolbox`
wrapper, which did its own `sleep 0.4; centerwindow` and raced the listener, is no longer
referenced by the config.

## Gotchas when running diagnostics here

- **`pkill -f` is dangerous in this environment.** The Claude Bash shell's own command line
  contains the pattern being searched for, so `pkill -f foo` can match and kill the running
  command itself plus unrelated processes. Use `ps -eo pid,ppid,args | grep '[f]oo'` and kill
  specific PIDs.
- `scripts/Tak0-Per-Window-Switch.sh --listener` holds its own `socat` on the event socket
  (it drives per-window keyboard layout). Don't kill it when cleaning up diagnostic socats.
  It self-heals on the next Shift_L+Alt_L press, or restart manually:
  `setsid nohup bash config-hypr/scripts/Tak0-Per-Window-Switch.sh --listener &`
- `UserScripts/JetBrainsToolboxAtCursor.sh --listener` holds a second `socat` on the same
  socket. Same warning; restart it with `~/.config/hypr/UserScripts/JetBrainsToolboxAtCursor.sh`
  (no args — that mode only ensures a listener is running).
- `scripts/LuaAutoReload.sh` runs `hyprctl reload` whenever any `*.lua` under the config
  tree changes.
- `hyprctl reload` discards all dynamic `hyprctl keyword` rules. Useful for testing: apply
  rules dynamically to iterate, then reload to confirm the on-disk config alone works.
- `HYPRLAND_INSTANCE_SIGNATURE` changes when Hyprland restarts. If long-running listeners
  suddenly stop working, check whether the signature moved rather than assuming a config
  regression.
