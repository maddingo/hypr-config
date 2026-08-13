# Working in this repo

Hyprland + Noctalia dotfiles. `install.sh` builds things; `link-config.sh` only
symlinks.

## The configs are live

`~/.config/hypr`, `~/.config/noctalia` and `~/.config/alacritty` are **symlinks**
to `config-hypr/`, `config-noctalia/` and `config-alacritty/` here. Editing a
file in this repo edits the running config — there is nothing to copy or sync.

Check with `ls -ld ~/.config/hypr`, not `ls -la ~/.config/hypr/` — the latter
follows the link and looks like a plain directory.

Apply changes with `hyprctl reload`. Note what that does *not* do:

- Window rules and `window.open` hooks run when a window **maps**, so existing
  windows are unaffected. Reopen the app to test a rule.
- It clears any `hl.on(...)` subscriptions registered ad hoc (see below), so
  debug hooks do not leak past a reload.
- `link-config.sh` refuses to run while Hyprland is up (Hyprland would recreate
  a stock `~/.config/hypr/hyprland.lua` over the symlink). Relinking needs a TTY.

## Hyprland Lua config

This is Hyprland 0.56's Lua config, not `hyprland.conf`. The authoritative field
list is the API stub at `/usr/share/hypr/stubs/hl.meta.lua` — read it instead of
guessing, since the docs and most examples online are for the old text format.

`hyprctl dispatch 'function() ... end'` runs **arbitrary Lua inside Hyprland**.
This is the fastest way to check an API shape or test a fix: write a script to
the scratchpad that logs to a file, then `dofile` it from a dispatched function.
It beats editing the config and reloading for each guess.

Things that cost time to discover:

- Window properties are **read-only**. `win.at = {x, y}` fails with "attempt to
  modify read-only hl object". Positioning goes through dispatchers.
- Working dispatcher forms: `hl.dsp.window.move({ window = w, x = , y = })`,
  `hl.dsp.window.move({ window = w, workspace = id })`, and
  `hl.dsp.window.center({ window = w })`. Other shapes (`position`, `exact`,
  `to`) raise "unrecognized arguments", and `hl.dispatch` rejects plain strings.
- `win.at` and `win.size` are indexed `.x` / `.y`, not `[1]` / `[2]`. Indexing
  numerically returns nil silently.
- A `move` window rule takes plain coordinates only (`"20 monitor_h-120"`). The
  `onscreen` and `cursor` keywords from the text config are **silently ignored**
  — the rule just does nothing, with no error on reload.
- Monitor `width`/`height` are **physical** pixels, window coordinates are
  logical. Divide by `mon.scale`: eDP-1 is 2560x1600 @ 1.6 = 1600x1000 logical.
- Lua errors during a reload do not show up in `hyprland.log`. A rule or hook
  that silently does nothing is the normal failure mode — verify by observing
  the window, e.g. polling `hyprctl -j clients`.

## Monitor layout

HDMI-A-1 (BenQ, 1920x1080, scale 1) at `0x0`; eDP-1 (2560x1600, scale 1.6 =
1600x1000 logical) at `1920x0`. So the laptop is on the right and the global
coordinate space starts at x=0 on the BenQ — a negative x is off-layout
entirely, not merely on the other screen.

## JetBrains Toolbox

Toolbox anchors its popup to where it thinks its tray icon is, and under
XWayland it gets that wrong: it requests `x = -440`, off the left edge of the
layout. The window maps fine, focused and alive, but invisible, on whatever
workspace the leftmost monitor happens to show — it looks like it never opened.

The `window.open` hook in `config-hypr/hyprland.lua` places it under the cursor
instead. Two non-obvious constraints shaped it:

- The tray lives in the Noctalia bar on **both** monitors, so the cursor is the
  only reliable hint about which screen the click came from. A fixed position
  would be wrong on the other one.
- Placing it once is not enough — Toolbox re-asserts its own off-screen position
  ~100ms after the window maps. The hook holds the position on a repeating timer
  for ~1.2s, which is why dragging the window during that first second snaps back.
