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

This design has since been validated against a *physical* port change, not just a reboot:
on 2026-08-17 the dock was moved to a different USB-C port and the layout came up correct
with zero intervention. See "Display problems" below for why the names drift at all.

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

## Display problems: both externals share one MST link

The two externals are **not two cables**. They hang off a single physical DisplayPort
connector through an MST hub, and `DP-9` / `DP-12` are *virtual* outputs on it:

    [drm] DM_MST: DP12, 4-lane link detected

**Any symptom that hits both externals at once and spares `eDP-1` is the shared link or the
hub — not per-monitor config, and not Hyprland.** The compositor has no mechanism to blank
two outputs and leave the third alone. This is also why the connector names drift (see
Layout above): they are MST port numbers, not physical ports.

`hyprctl monitors` will not tell you which physical connector the hub is on. The kernel
does, via the `aconnector` id in the `DM_MST` lines — a *changed* id means a genuinely
different GPU connector, not merely re-enumeration.

### Two root-free tests that settle it fast

debugfs is unavailable here (see dead ends below), so these are the tools you actually have.

**Is it bandwidth?** Drop both externals to 1080p60 dynamically and watch:

```sh
hyprctl keyword monitor "desc:Lenovo Group Limited P27h-20 V906YWA0,1920x1080@60,2194x0,1"
hyprctl keyword monitor "desc:Lenovo Group Limited P27h-20 V907BZ2P,1920x1080@60,4754x0,1"
hyprctl reload   # reverts -- dynamic keyword rules never survive a reload
```

At 8-bit (`currentFormat=XRGB8888`) 2x 1440p60 needs ~13 Gbit/s, 2x 1080p60 about ~7.4:

| 4-lane link rate | Usable | Fits 2x 1440p60? |
|---|---|---|
| HBR2 (5.4 G/lane) | ~17.3 Gbit/s | yes |
| HBR (2.7 G/lane) | ~8.6 Gbit/s | **no** |
| RBR (1.62 G/lane) | ~5.2 Gbit/s | no |

A link that trained down to HBR therefore presents as exactly "both screens misbehave at
1440p, fine at 1080p". If 1080p changes nothing, bandwidth is falsified — stop pursuing it.

**Is Hyprland involved at all?** Diff the line count of the log over ~45s while the symptom
is occurring:

```sh
LOG=/run/user/$UID/hypr/$HYPRLAND_INSTANCE_SIGNATURE/hyprland.log; wc -l < "$LOG"
```

That log records individual cursor-buffer imports and libinput debounce transitions. If it
writes **zero lines** across a dozen visible glitches, the compositor is definitively not
involved and you can stop reading config entirely. For display-layer problems this is
faster and more conclusive than the event socket.

### Dead ends, written down so they are not retried

- **debugfs is blocked by kernel lockdown** (Secure Boot). `sudo cat
  /sys/kernel/debug/dri/*/DP-*/link_settings` fails *silently* and logs
  `Lockdown: cat: debugfs access is restricted` to dmesg. The negotiated DP link rate is
  simply not readable without `drm.debug=0x4` on the kernel cmdline plus a reboot.
- Since kernel ~6.10 the DRI debugfs directories are named by PCI device
  (`/sys/kernel/debug/dri/0000:c3:00.0/`), not by minor number (`dri/1`), so older
  instructions found online are wrong here twice over.
- **amdgpu does not log successful DP link retrains at the default loglevel.** Silence in
  dmesg is *not* evidence that the link is healthy.

### Incident 2026-08-17: both externals blinking black

Every few seconds, starting the moment the machine was re-docked. Bandwidth was falsified
(unchanged at 1080p); Hyprland logged nothing across ~15 blinks; VRR, PSR and 10-bit were
all already off. The cause was physical — the DP path through USB-C port `USBC000:001`
(aconnector 122). Moving the dock to `USBC000:002` (aconnector 115) fixed it with every
other variable held constant:

    10:32:58  DM_MST: stopping TM on aconnector: ... [id: 122]   <- old port
    10:33:04  DM_MST: starting TM on aconnector: ... [id: 115]   <- new port

Still open: whether port 001 or that cable end is the faulty one. Plug a *different* cable
into 001 to find out — blinking returns means the port is bad, clean means the cable is.

Leave a kernel capture running across any such experiment. It is the only channel that
records the transition:

```sh
journalctl -kf -o short-precise | grep -iE 'drm|mst|link|ucsi'
```

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
- **`systemctl --user disable` does not necessarily stick.** Some units are enabled in
  *global* scope by their Debian package via `/etc/systemd/user/*.wants/`, so a user-scope
  disable stops the unit but it returns at next login (systemd says so, in a message that
  is easy to skim past). Mask instead — `systemctl --user mask X` is user-scope, needs no
  root, and survives package upgrades, which `sudo systemctl --global disable` does not.
- `hyprpaper.service` is **masked** for this reason. It shipped globally enabled and ran
  alongside `swww-daemon`, which is the actual wallpaper daemon here (started by
  `scripts/DarkLight.sh` via `ApplyThemeMode.sh`). hyprpaper held no layer surfaces, so it
  was harmless — but two wallpaper daemons is a convincing red herring in a display
  investigation. Check `hyprctl layers` before blaming either.
