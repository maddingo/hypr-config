# Noctalia plugin: `maddingo/workspace-monitor`

## Purpose

A Noctalia panel plugin for Hyprland that shows connected monitors as ordered
cards and lets the user:

- edit each monitor's mode (resolution/refresh), scale, rotation, and
  enabled/disabled state
- reorder monitors (drag left/right) to set their physical left-to-right
  position
- drag workspace-ID chips onto a monitor card to bind that workspace to that
  monitor

It is a visual, drag-driven tool in the spirit of `nwg-displays`, adapted to
what Noctalia's plugin UI can actually do (see Constraints).

## Constraints (confirmed against the running system and Noctalia's docs)

- Noctalia plugin panels use a **strictly nested flexbox** layout
  (`ui.row`/`ui.column`/`ui.box` with `gap`/`padding`/`align`/`justify`).
  There is no absolute/free x,y canvas positioning primitive. A literal
  drag-anywhere 2D layout editor like `nwg-displays` is not buildable as-is.
  → Monitors are rendered as an ordered row of cards instead of a spatial
  canvas.
- Drag-and-drop exists (`ui.dragSource` / `ui.dropZone`), proven in the
  `blackbartblues/keymap` plugin's category/reorder UI. This plugin reuses
  the same pattern for (a) reordering monitor cards and (b) dragging
  workspace chips onto a card.
- The current plugin API in active use on this system is **Luau**
  (`plugin_api` 3–9: `maddingo/hypr-layout-switcher`, `blackbartblues/keymap`),
  not the older QML entry-point API bundled under `config-noctalia/plugins/`.
  This plugin targets the Luau API.
- Noctalia's runtime has no Hyprland-specific helper API; monitor/workspace
  data and mutation go through `noctalia.runAsync("hyprctl ...")`, same as
  `hypr-layout-switcher` already does.
- `hyprctl workspacerules -j` returns configured persistent workspace→monitor
  bindings (confirmed: returns `[]` when none are set), independent of which
  workspaces happen to be active. This is the source of truth for which chip
  is bound to which card on panel open.
- `hyprctl output create headless` / `hyprctl output remove <name>` can add
  and remove virtual outputs at runtime (confirmed working on this machine).
  This is the primary way to test multi-monitor behavior without a second
  physical display.

## Scope

In scope:
- Per-monitor settings: mode (from `availableModes`), scale, transform
  (rotation/flip), enabled/disabled.
- Monitor left-to-right ordering via drag, translated to explicit `x,y`
  positions.
- Workspace→monitor binding via drag-and-drop of workspace chips.
- A configurable workspace-ID range (`workspace_count` setting, default 10)
  that generates the chip palette — no workspace naming, no per-workspace
  layout/gap rules.
- Live apply (immediate effect via `hyprctl`) **and** persistence into a
  managed Lua file included from the user's `hyprland.lua`.

Out of scope:
- A true free-form 2D spatial layout canvas.
- Workspace naming, workspace count semantics beyond the chip range, or any
  other per-workspace Hyprland rule (gaps, default layout, persistent flag).
- Publishing to `noctalia-dev/community-plugins`. This is a standalone repo
  the user controls, added as a `path` or `git` source locally.
- Any compositor other than Hyprland.

## Plugin structure

New repo at `~/Develop/noctalia-workspace-monitor`, plugin id
`maddingo/workspace-monitor`:

```
noctalia-workspace-monitor/
  plugin.toml           -- id, plugin_api, dependencies=["hyprland"],
                            [[setting]] hyprland_config, workspace_count
  panel.luau             -- card UI, drag sources/drop zones, edit controls
  writer_service.luau    -- transactional writer (render/validate/commit/reload)
  widget.luau             -- small bar-widget entry that opens the panel
  README.md
  translations/en.json
  tests/                 -- plain Lua/Luau unit tests for pure logic (see Testing)
```

This mirrors the shape of `maddingo/hypr-layout-switcher` (service + widget)
and `blackbartblues/keymap` (settings schema + panel + writer service), both
already installed and working on this system.

## Data sources

Read on panel open and on an explicit refresh action:

- `hyprctl monitors -j` → `name`, `width`, `height`, `x`, `y`, `scale`,
  `transform`, `refreshRate`, `availableModes`, `disabled`.
- `hyprctl workspacerules -j` → existing persistent `workspace`/`monitor`
  bindings, used to pre-select which chip renders as "bound" on which card.
- `workspace_count` setting → drives how many chips (`1..N`) exist in the
  unbound-chip palette.

All reads go through `noctalia.runAsync(...)` + `noctalia.json.decode(...)`,
following the exact pattern already used in `hypr-layout-switcher`'s
`service.luau`.

## Panel UI

- Root: `ui.row` of monitor cards, ordered ascending by current `x`.
- Each card (`ui.column`):
  - Header: monitor name, an enabled/disabled toggle.
  - `ui.select` for mode, populated from `availableModes`.
  - `ui.select` (or `ui.slider`) for scale.
  - `ui.select` for rotation/transform (`normal`, `90`, `180`, `270`, flipped
    variants — Hyprland's `transform` values).
  - A `ui.dragSource` handle on the card itself, and a `ui.dropZone`
    "insertion zone" between cards (same technique as keymap's
    `reorderInsertionZone`), to reorder cards.
  - A chip strip at the bottom: a `ui.dropZone` that accepts workspace-chip
    drops (`onWorkspaceAssigned(workspaceId, monitorName)`), rendering any
    chip currently bound to that monitor as filled/highlighted.
- A shared unbound-chip palette (`ui.dragSource` per workspace id 1..N) below
  the card row, showing only chips not currently bound to any monitor.

## Applying a change

Every edit (reorder, mode/scale/rotation change, chip drop) triggers the same
two-step sequence:

1. **Live apply** — immediate effect via `noctalia.runAsync`:
   - `hyprctl keyword monitor "<name>,<mode>,<x>x<y>,<scale>,transform,<n>"`
     for monitor edits/reordering (x is recomputed for every card from the
     new left-to-right order and each preceding card's scaled width).
   - `hyprctl keyword workspace "<id>, monitor:<name>"` for a new binding;
     `hyprctl dispatch moveworkspacetomonitor <id> <name>` additionally if
     that workspace is currently active, so the visible workspace moves too.
2. **Persist** — `writer_service.luau` re-renders the *entire* managed file
   from current in-memory state (all monitors + all bindings, full
   re-render, not a diff) as a block of `hl.monitor({...})` and
   `hl.workspace_rule({workspace = N, monitor = "NAME"})` calls. It:
   - writes to a temp file,
   - validates with `Hyprland --verify-config -c <temp-file>`,
   - only on success moves it into place and runs `hyprctl reload`,
   - on failure, leaves the previously-committed managed file untouched and
     reports the error back to the panel via `noctalia.state.set(...)`.

   This is the same write→validate→commit→reload transaction
   `blackbartblues/keymap`'s `writer_service.luau` already uses, chosen
   specifically so a bad generated value can't leave `hyprland.lua` in a
   broken state.

   `[[setting]]` fields (matching keymap's `hyprland_config` pattern):
   - `hyprland_config` (type `file`, default `~/.config/hypr/hyprland.lua`) —
     where the plugin ensures a `require("workspace-monitor")` include line
     exists (inserted once, idempotently, if absent).
   - `workspace_count` (type `int`, default `10`, min 1, max 36).

## Error handling

- If `hyprctl` is not on `PATH`, or `Hyprland --verify-config` fails, the
  panel surfaces the error (via `noctalia.notifyError` and an inline banner)
  and does not touch the previously-committed managed file.
- Dropping a chip on a disabled monitor is rejected client-side (drop zone
  reports `enabled = false` for disabled monitors).
- Reordering/mode changes that would leave zero enabled monitors are
  rejected client-side.

## Testing

- **Multi-monitor scenarios**: `hyprctl output create headless` /
  `hyprctl output remove <name>` to add/remove virtual outputs at will,
  confirmed working on this machine. Used to exercise reordering and
  chip-binding across 2-3 monitors without physical hardware.
- **Local dev loop**: register the repo as a source —
  `noctalia msg plugins source add workspace-monitor-dev path ~/Develop/noctalia-workspace-monitor`,
  then `noctalia msg plugins enable maddingo/workspace-monitor`. Luau file
  edits hot-reload; `plugin.toml` changes need `noctalia msg config-reload`.
- **Driving without the UI**: `noctalia msg panel-toggle
  maddingo/workspace-monitor:panel` to open the panel directly;
  `noctalia msg plugin maddingo/workspace-monitor:writer_service all
  <event>` to fire specific IPC events at the writer service for scripted
  testing.
- **Persistence path verification**: after a change, inspect the generated
  managed `.lua` file by hand, run `Hyprland --verify-config -c <path>`
  independently to confirm the plugin's own gate would have caught a bad
  value, confirm the `require(...)` line is present exactly once in
  `hyprland.lua`, confirm `hyprctl reload` doesn't error.
- **Pure-logic unit tests**: following `keymap`'s `tests/*.lua` pattern
  (run with a standalone Lua/Luau interpreter, no Noctalia runtime needed),
  cover the card-order → `x,y` position math and the JSON parsing of
  `hyprctl monitors -j` / `hyprctl workspacerules -j` output.

## Open decisions deferred to the implementation plan

- Exact Hyprland `transform` value set to expose (all 8 wlroots transforms
  vs. just the 4 rotations).
- Whether `ui.slider` or `ui.select` is the better fit for scale (continuous
  vs. a curated list of common scale factors).
- Exact wording/i18n keys, thumbnail/README content for the new repo.
