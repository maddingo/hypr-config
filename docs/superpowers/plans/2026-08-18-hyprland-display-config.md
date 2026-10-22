# Hyprland Display Config Plugin Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `maddingo/hyprland-display-config`, a Luau Noctalia panel plugin that shows Hyprland monitors as ordered cards, lets the user edit each monitor's mode/scale/rotation/enabled state and reorder them, and lets the user drag workspace-ID chips onto a card to bind that workspace to that monitor — applying live and persisting into the user's Hyprland Lua config.

**Architecture:** Two Luau services split by responsibility (read vs. write), one panel, one bar widget — the same shape already proven by the `blackbartblues/keymap` plugin installed on this system. `service.luau` polls `hyprctl monitors all -j` / `hyprctl workspacerules -j`, normalizes them into an ordered snapshot, and publishes it via `noctalia.state.set`. `panel.luau` renders that snapshot as cards and turns user interactions into a single "apply request" object. `writer_service.luau` receives that request, live-applies it via `hyprctl eval` (this Hyprland build rejects `hyprctl keyword`/legacy `hyprctl dispatch` outright — confirmed below), then renders/validates/commits/reloads a managed Lua file included from the user's `hyprland.lua`.

**Tech Stack:** Luau (Noctalia plugin API, `plugin_api = 9`), Hyprland's native Lua config eval (`hl.monitor`, `hl.workspace_rule`, `hl.dsp.workspace.move`), plain Lua 5.x for the standalone test suite (`/usr/bin/lua`, confirmed installed, Lua 5.5.1).

## Global Constraints

These are facts verified live against the user's running system (Hyprland
`0.56.2`, native Lua config parser) during design. Every task below assumes
them; do not substitute the more commonly-documented legacy Hyprland syntax.

- **`hyprctl keyword ...` is broken on this system**: it returns
  `error: keyword can't work with non-legacy parsers. Use eval.` Never use it.
- **Legacy `hyprctl dispatch <name> <args>` is also broken**: it gets routed
  through the Lua evaluator and fails to parse. All dispatches must go
  through `hyprctl eval 'hl.dispatch(hl.dsp.<category>.<method>({...}))'`.
- **Live-apply calls, confirmed working via `hyprctl eval`:**
  - `hl.monitor({ output = "<name>", mode = "<mode>", position = "<x>x<y>", scale = <number>, transform = <int>, disabled = <bool> })`
    — `mode` accepts `"preferred"`, `"auto"`, or any exact string from that
    monitor's `availableModes` (e.g. `"1920x1080@60.03Hz"`, `"Hz"` suffix and
    all — verified byte-for-byte against `hyprctl monitors -j` output).
    `position` accepts `"auto"` or an exact `"<x>x<y>"` string.
  - `hl.workspace_rule({ workspace = "<id-as-string>", monitor = "<name>" })`
    — persists a workspace→monitor rule, visible afterward in
    `hyprctl workspacerules -j`.
  - `hl.dispatch(hl.dsp.workspace.move({ workspace = "<id-as-string>", monitor = "<name>" }))`
    — instantly moves an existing workspace (active or not) to a monitor.
    Confirmed by moving a non-active workspace live.
- **`hyprctl monitors -j` hides disabled monitors; `hyprctl monitors all -j`
  does not.** Confirmed: disabling a monitor via `hl.monitor({..., disabled
  = true})` removes it from the plain `monitors -j` listing but it still
  appears (with `"disabled": true`) under `monitors all -j`. The plugin
  must always read with `all`, or a disabled monitor becomes permanently
  invisible (and unrecoverable) inside its own UI.
- **`hyprctl workspacerules -j` entries use the field name
  `workspaceString`** (a string, e.g. `"5"`), not `workspace`. Also present:
  `monitor` (string), `enabled` (bool).
- **`hyprctl monitors [all] -j` entries used by this plugin**: `name`
  (string), `width`/`height` (int, physical pixels), `x`/`y` (int, layout
  position), `scale` (number), `transform` (int, 0-7), `refreshRate`
  (number), `availableModes` (array of strings), `disabled` (bool).
- **Monitor layout position formula**: a monitor's layout-space width is
  `width / scale`; placing monitors left-to-right means each one's `x` is
  the running sum of previous monitors' `width / scale`, `y = 0`. This
  matches the convention already documented in this repo's
  `config-hypr/config/monitors.lua` (`-- Monitor wiki
  https://wiki.hypr.land/Configuring/Basics/Monitors/`).
- **Test harness convention** (copied from the already-installed
  `blackbartblues/keymap` plugin's `tests/*.lua`): each test file sets a
  global `noctalia` table stubbing exactly the runtime functions the
  production file under test calls, then does
  `assert(loadfile("<file>.luau"))()` from the plugin root, then asserts on
  values the stub captured (state writes, file writes, or the return value
  of an exposed pure function). Tests run via `lua tests/<name>_test.lua`
  from the plugin repo root, matching keymap's
  `for test_file in tests/*.lua; do lua "$test_file"; done`. Files loaded
  this way must stick to Lua 5.x-compatible syntax (no `+=`, no Luau type
  annotations) — `panel.luau` uses `ui.*` calls and Luau-only operators, so
  it is never loaded this way; it is verified manually instead (Task 10).

---

## File Structure

```
~/Develop/hyprland-display-config/
  plugin.toml            -- manifest: settings, service/widget/panel entries
  service.luau            -- read-only poller: hyprctl -> normalized snapshot
  writer_service.luau      -- apply pipeline: live-apply + persist + reload
  panel.luau               -- card UI, drag-and-drop, dispatches apply requests
  widget.luau               -- bar widget that opens the panel
  README.md
  LICENSE
  translations/en.json
  tests/
    parse_monitors_test.lua
    parse_workspace_rules_test.lua
    build_snapshot_test.lua
    service_poll_test.lua
    compute_positions_test.lua
    render_managed_file_test.lua
    ensure_require_line_test.lua
    writer_apply_test.lua
    writer_apply_validation_failure_test.lua
```

---

### Task 1: Repo scaffold and plugin manifest

**Files:**
- Create: `~/Develop/hyprland-display-config/plugin.toml`
- Create: `~/Develop/hyprland-display-config/LICENSE`
- Create: `~/Develop/hyprland-display-config/.gitignore`
- Create: `~/Develop/hyprland-display-config/translations/en.json`
- Create: `~/Develop/hyprland-display-config/service.luau` (empty stub, see step 3)

**Interfaces:**
- Produces: the plugin id `maddingo/hyprland-display-config`, settings keys
  `hyprland_config` (string, path) and `workspace_count` (int), and the
  service/widget/panel entry ids (`service`, `writer_service`, `widget`,
  `panel`) that every later task's `[[service]]`/`[[widget]]`/`[[panel]]`
  code must match exactly.

- [ ] **Step 1: Create the repo**

```bash
mkdir -p ~/Develop/hyprland-display-config/translations
mkdir -p ~/Develop/hyprland-display-config/tests
cd ~/Develop/hyprland-display-config
git init
```

- [ ] **Step 2: Write `plugin.toml`**

```toml
id = "maddingo/hyprland-display-config"
name = "Hyprland Display Config"
description = "Visually configure monitor layout and assign workspaces to monitors"
version = "0.1.0"
plugin_api = 9
author = "maddingo"
license = "MIT"
icon = "layout-grid"
tags = ["hyprland", "panel", "monitors", "workspaces"]
dependencies = ["hyprland"]

[[setting]]
key = "hyprland_config"
type = "file"
label_key = "settings.hyprland_config.label"
description_key = "settings.hyprland_config.description"
default = "~/.config/hypr/hyprland.lua"

[[setting]]
key = "workspace_count"
type = "int"
label_key = "settings.workspace_count.label"
description_key = "settings.workspace_count.description"
default = 10
min = 1
max = 36

[[service]]
id = "service"
entry = "service.luau"

[[service]]
id = "writer_service"
entry = "writer_service.luau"

[[widget]]
id = "widget"
entry = "widget.luau"

[[panel]]
id = "panel"
entry = "panel.luau"
width = 1200
height = 700
placement = "floating"
position = "center"
```

- [ ] **Step 3: Write a placeholder `service.luau` so the manifest is valid**

```lua
--!nonstrict
-- Filled in by Task 2 onward.
```

- [ ] **Step 4: Write `translations/en.json`**

```json
{
  "title": "Hyprland Display Config",
  "settings": {
    "hyprland_config": {
      "label": "Hyprland config file",
      "description": "Path to the hyprland.lua that require()s the plugin's generated config"
    },
    "workspace_count": {
      "label": "Workspace count",
      "description": "How many workspace-ID chips to offer for monitor assignment"
    }
  },
  "panel": {
    "refresh": "Refresh",
    "apply_error": "Failed to apply: {message}",
    "unbound_workspaces": "Unassigned workspaces"
  },
  "widget": {
    "tooltip": "Configure displays and workspaces"
  }
}
```

- [ ] **Step 5: Write `LICENSE` (MIT, matching the other installed plugins)**

```
MIT License

Copyright (c) 2026 Martin Goldhahn

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to
deal in the Software without restriction, including without limitation the
rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
sell copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.
```

- [ ] **Step 6: Write `.gitignore`**

```
*.tmp
```

- [ ] **Step 7: Commit**

```bash
cd ~/Develop/hyprland-display-config
git add plugin.toml LICENSE .gitignore translations/en.json service.luau
git commit -m "Scaffold hyprland-display-config plugin"
```

---

### Task 2: `parseMonitors` — pure JSON-to-table parsing

**Files:**
- Modify: `~/Develop/hyprland-display-config/service.luau`
- Create: `~/Develop/hyprland-display-config/tests/parse_monitors_test.lua`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `parseMonitors(jsonText)` — returns an array of tables with
  fields `name` (string), `width`/`height` (number), `x`/`y` (number),
  `scale` (number), `transform` (number), `refreshRate` (number),
  `availableModes` (array of strings), `disabled` (bool). Task 4
  (`buildSnapshot`) and Task 6 (`computePositions`) consume tables shaped
  exactly like this.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/parse_monitors_test.lua
local fixture = [[
[
  {"name":"eDP-1","width":1920,"height":1080,"x":0,"y":0,"scale":1.5,
   "transform":0,"refreshRate":60.033,"disabled":false,
   "availableModes":["1920x1080@60.03Hz","1920x1080@48.03Hz"]},
  {"name":"HEADLESS-1","width":1280,"height":720,"x":1280,"y":0,"scale":1,
   "transform":0,"refreshRate":60.0,"disabled":true,
   "availableModes":["1280x720@60.00Hz"]}
]
]]

noctalia = {
  json = {
    decode = function(text)
      assert(text == fixture, "decode called with unexpected text")
      return {
        { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
          scale = 1.5, transform = 0, refreshRate = 60.033, disabled = false,
          availableModes = { "1920x1080@60.03Hz", "1920x1080@48.03Hz" } },
        { name = "HEADLESS-1", width = 1280, height = 720, x = 1280, y = 0,
          scale = 1, transform = 0, refreshRate = 60.0, disabled = true,
          availableModes = { "1280x720@60.00Hz" } },
      }
    end,
  },
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

_G.__PARSE_MONITORS_TEST_FIXTURE = fixture

assert(loadfile("service.luau"))()

local monitors = parseMonitors(fixture)
assert(#monitors == 2, "expected 2 monitors, got " .. tostring(#monitors))
assert(monitors[1].name == "eDP-1", "monitor 1 name mismatch")
assert(monitors[1].scale == 1.5, "monitor 1 scale mismatch")
assert(monitors[1].disabled == false, "monitor 1 should be enabled")
assert(#monitors[1].availableModes == 2, "monitor 1 availableModes count mismatch")
assert(monitors[2].name == "HEADLESS-1", "monitor 2 name mismatch")
assert(monitors[2].disabled == true, "monitor 2 should be disabled")

print("parse_monitors_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/parse_monitors_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'parseMonitors')`

- [ ] **Step 3: Implement `parseMonitors` in `service.luau`**

Replace the placeholder content of `service.luau` with:

```lua
--!nonstrict

local SNAPSHOT_KEY = "hyprland-display-config.snapshot"

function parseMonitors(jsonText)
  local decoded = noctalia.json.decode(jsonText)
  if type(decoded) ~= "table" then return {} end
  local monitors = {}
  for _, entry in ipairs(decoded) do
    monitors[#monitors + 1] = {
      name = tostring(entry.name or ""),
      width = tonumber(entry.width) or 0,
      height = tonumber(entry.height) or 0,
      x = tonumber(entry.x) or 0,
      y = tonumber(entry.y) or 0,
      scale = tonumber(entry.scale) or 1,
      transform = tonumber(entry.transform) or 0,
      refreshRate = tonumber(entry.refreshRate) or 0,
      availableModes = entry.availableModes or {},
      disabled = entry.disabled == true,
    }
  end
  return monitors
end
```

Note: `parseMonitors` is declared with `function parseMonitors(...)` (a
global, no `local`) so that `loadfile("service.luau")()` in a test leaves it
reachable from the test file afterward — the same technique
`blackbartblues/keymap`'s test suite relies on for the functions it probes.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/parse_monitors_test.lua`
Expected: `parse_monitors_test: ok`

- [ ] **Step 5: Commit**

```bash
git add service.luau tests/parse_monitors_test.lua
git commit -m "Add parseMonitors to service.luau"
```

---

### Task 3: `parseWorkspaceRules` — pure JSON-to-table parsing

**Files:**
- Modify: `~/Develop/hyprland-display-config/service.luau`
- Create: `~/Develop/hyprland-display-config/tests/parse_workspace_rules_test.lua`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `parseWorkspaceRules(jsonText)` — returns an array of
  `{ workspace = <number>, monitor = <string> }`. Task 4 (`buildSnapshot`)
  consumes this shape.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/parse_workspace_rules_test.lua
local fixture = "workspacerules-fixture"

noctalia = {
  json = {
    decode = function(text)
      assert(text == fixture)
      return {
        { workspaceString = "5", monitor = "eDP-1", enabled = true },
        { workspaceString = "2", monitor = "HEADLESS-1", enabled = true },
        { workspaceString = "special:scratch", monitor = "eDP-1", enabled = true },
      }
    end,
  },
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("service.luau"))()

local bindings = parseWorkspaceRules(fixture)
assert(#bindings == 2, "named workspace rule should be skipped, got " .. tostring(#bindings))
local byId = {}
for _, binding in ipairs(bindings) do byId[binding.workspace] = binding.monitor end
assert(byId[5] == "eDP-1", "workspace 5 binding mismatch")
assert(byId[2] == "HEADLESS-1", "workspace 2 binding mismatch")

print("parse_workspace_rules_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/parse_workspace_rules_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'parseWorkspaceRules')`

- [ ] **Step 3: Implement `parseWorkspaceRules` in `service.luau`**

Append below `parseMonitors`:

```lua
function parseWorkspaceRules(jsonText)
  local decoded = noctalia.json.decode(jsonText)
  if type(decoded) ~= "table" then return {} end
  local bindings = {}
  for _, entry in ipairs(decoded) do
    local id = tonumber(entry.workspaceString)
    local monitor = entry.monitor
    if id ~= nil and type(monitor) == "string" and monitor ~= "" then
      bindings[#bindings + 1] = { workspace = id, monitor = monitor }
    end
  end
  return bindings
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/parse_workspace_rules_test.lua`
Expected: `parse_workspace_rules_test: ok`

- [ ] **Step 5: Commit**

```bash
git add service.luau tests/parse_workspace_rules_test.lua
git commit -m "Add parseWorkspaceRules to service.luau"
```

---

### Task 4: `buildSnapshot` — normalize monitors + bindings into panel-ready state

**Files:**
- Modify: `~/Develop/hyprland-display-config/service.luau`
- Create: `~/Develop/hyprland-display-config/tests/build_snapshot_test.lua`

**Interfaces:**
- Consumes: `parseMonitors` output shape (Task 2), `parseWorkspaceRules`
  output shape (Task 3).
- Produces: `buildSnapshot(monitors, bindings, workspaceCount)` returning
  `{ status = "ready", monitors = { {name, width, height, x, y, scale,
  transform, refreshRate, availableModes, disabled, workspaces = {ids...}},
  ... } (ascending by x), unboundWorkspaces = {ids not bound to any
  monitor, ascending} }`. Task 9 (`panel.luau`) renders this shape directly.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/build_snapshot_test.lua
noctalia = {
  json = { decode = function() return {} end },
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("service.luau"))()

local monitors = {
  { name = "HEADLESS-1", width = 1280, height = 720, x = 1280, y = 0,
    scale = 1, transform = 0, refreshRate = 60, availableModes = {}, disabled = false },
  { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
    scale = 1.5, transform = 0, refreshRate = 60, availableModes = {}, disabled = false },
}
local bindings = {
  { workspace = 3, monitor = "eDP-1" },
  { workspace = 1, monitor = "eDP-1" },
  { workspace = 2, monitor = "HEADLESS-1" },
}

local snapshot = buildSnapshot(monitors, bindings, 4)

assert(snapshot.status == "ready", "status should be ready")
assert(#snapshot.monitors == 2, "expected 2 monitors in snapshot")
assert(snapshot.monitors[1].name == "eDP-1", "eDP-1 (x=0) should sort first, got " .. snapshot.monitors[1].name)
assert(snapshot.monitors[2].name == "HEADLESS-1", "HEADLESS-1 (x=1280) should sort second")
assert(#snapshot.monitors[1].workspaces == 2, "eDP-1 should have 2 bound workspaces")
assert(snapshot.monitors[1].workspaces[1] == 1, "eDP-1 workspaces should be sorted ascending")
assert(snapshot.monitors[1].workspaces[2] == 3, "eDP-1 workspaces should be sorted ascending")
assert(#snapshot.monitors[2].workspaces == 1, "HEADLESS-1 should have 1 bound workspace")
assert(snapshot.monitors[2].workspaces[1] == 2, "HEADLESS-1 workspace mismatch")
assert(#snapshot.unboundWorkspaces == 1, "workspace 4 should be unbound")
assert(snapshot.unboundWorkspaces[1] == 4, "unbound workspace id mismatch")

print("build_snapshot_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/build_snapshot_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'buildSnapshot')`

- [ ] **Step 3: Implement `buildSnapshot` in `service.luau`**

Append below `parseWorkspaceRules`:

```lua
function buildSnapshot(monitors, bindings, workspaceCount)
  local boundByMonitor = {}
  local boundWorkspaceIds = {}
  for _, binding in ipairs(bindings) do
    local list = boundByMonitor[binding.monitor]
    if list == nil then
      list = {}
      boundByMonitor[binding.monitor] = list
    end
    list[#list + 1] = binding.workspace
    boundWorkspaceIds[binding.workspace] = true
  end

  local orderedMonitors = {}
  for _, monitor in ipairs(monitors) do
    orderedMonitors[#orderedMonitors + 1] = monitor
  end
  table.sort(orderedMonitors, function(a, b) return a.x < b.x end)

  local snapshotMonitors = {}
  for _, monitor in ipairs(orderedMonitors) do
    local workspaces = boundByMonitor[monitor.name] or {}
    table.sort(workspaces)
    snapshotMonitors[#snapshotMonitors + 1] = {
      name = monitor.name,
      width = monitor.width,
      height = monitor.height,
      x = monitor.x,
      y = monitor.y,
      scale = monitor.scale,
      transform = monitor.transform,
      refreshRate = monitor.refreshRate,
      availableModes = monitor.availableModes,
      disabled = monitor.disabled,
      workspaces = workspaces,
    }
  end

  local unbound = {}
  for id = 1, workspaceCount do
    if not boundWorkspaceIds[id] then
      unbound[#unbound + 1] = id
    end
  end

  return {
    status = "ready",
    monitors = snapshotMonitors,
    unboundWorkspaces = unbound,
  }
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/build_snapshot_test.lua`
Expected: `build_snapshot_test: ok`

- [ ] **Step 5: Commit**

```bash
git add service.luau tests/build_snapshot_test.lua
git commit -m "Add buildSnapshot to service.luau"
```

---

### Task 5: Wire `service.luau` polling and publish the snapshot

**Files:**
- Modify: `~/Develop/hyprland-display-config/service.luau`
- Create: `~/Develop/hyprland-display-config/tests/service_poll_test.lua`

**Interfaces:**
- Consumes: `parseMonitors`, `parseWorkspaceRules`, `buildSnapshot` (all
  from this file, Tasks 2-4).
- Produces: publishes the snapshot to `noctalia.state` under key
  `"hyprland-display-config.snapshot"` every 2 seconds and once at load.
  Task 9 (`panel.luau`) reads this exact key via `noctalia.state.watch`.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/service_poll_test.lua
local stateValues = {}
local monitorsJson = "monitors-json"
local rulesJson = "rules-json"

noctalia = {
  json = {
    decode = function(text)
      if text == monitorsJson then
        return {
          { name = "eDP-1", width = 1920, height = 1080, x = 0, y = 0,
            scale = 1, transform = 0, refreshRate = 60, disabled = false,
            availableModes = { "1920x1080@60.00Hz" } },
        }
      elseif text == rulesJson then
        return { { workspaceString = "1", monitor = "eDP-1", enabled = true } }
      end
      error("unexpected json.decode input: " .. tostring(text))
    end,
  },
  commandExists = function(name) return name == "hyprctl" end,
  runAsync = function(command, callback)
    if command == "hyprctl monitors all -j" then
      callback({ exitCode = 0, stdout = monitorsJson })
    elseif command == "hyprctl workspacerules -j" then
      callback({ exitCode = 0, stdout = rulesJson })
    else
      error("unexpected command: " .. tostring(command))
    end
    return true
  end,
  getConfig = function(key)
    if key == "workspace_count" then return 3 end
    return nil
  end,
  state = {
    set = function(key, value) stateValues[key] = value end,
    get = function(key) return stateValues[key] end,
    watch = function() end,
  },
  setUpdateInterval = function() end,
}

assert(loadfile("service.luau"))()

local snapshot = stateValues["hyprland-display-config.snapshot"]
assert(type(snapshot) == "table", "service did not publish a snapshot")
assert(snapshot.status == "ready", "snapshot status should be ready")
assert(#snapshot.monitors == 1, "expected 1 monitor")
assert(snapshot.monitors[1].name == "eDP-1")
assert(#snapshot.monitors[1].workspaces == 1 and snapshot.monitors[1].workspaces[1] == 1)
assert(#snapshot.unboundWorkspaces == 2, "workspaces 2 and 3 should be unbound")

print("service_poll_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/service_poll_test.lua`
Expected: FAIL — `state did not publish a snapshot` (poll/update not wired yet)

- [ ] **Step 3: Wire polling in `service.luau`**

Append at the very end of the file (after `buildSnapshot`):

```lua
local function workspaceCount()
  local value = tonumber(noctalia.getConfig("workspace_count"))
  if value == nil or value < 1 then return 10 end
  return math.floor(value)
end

local function poll()
  if not noctalia.commandExists("hyprctl") then return end
  noctalia.runAsync("hyprctl monitors all -j", function(monitorsResult)
    if monitorsResult.exitCode ~= 0 then return end
    local monitors = parseMonitors(monitorsResult.stdout)
    noctalia.runAsync("hyprctl workspacerules -j", function(rulesResult)
      if rulesResult.exitCode ~= 0 then return end
      local bindings = parseWorkspaceRules(rulesResult.stdout)
      local snapshot = buildSnapshot(monitors, bindings, workspaceCount())
      noctalia.state.set(SNAPSHOT_KEY, snapshot)
    end)
  end)
end

noctalia.setUpdateInterval(2000)

function update()
  poll()
end

poll()
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/service_poll_test.lua`
Expected: `service_poll_test: ok`

- [ ] **Step 5: Commit**

```bash
git add service.luau tests/service_poll_test.lua
git commit -m "Wire service.luau polling and snapshot publishing"
```

---

### Task 6: `computePositions` — reorder-to-layout-coordinates math

**Files:**
- Create: `~/Develop/hyprland-display-config/writer_service.luau`
- Create: `~/Develop/hyprland-display-config/tests/compute_positions_test.lua`

**Interfaces:**
- Consumes: nothing from other tasks (takes plain monitor-shaped tables).
- Produces: `computePositions(orderList, monitorsByName)` where
  `orderList` is an array of monitor names in desired left-to-right order
  and `monitorsByName` maps name to `{width, scale, ...}`. Returns a map
  `name -> {x = <number>, y = 0}`. Task 8 (`renderManagedFile`) and the
  apply pipeline (Task 9) consume this map.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/compute_positions_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local monitorsByName = {
  ["eDP-1"] = { width = 1920, height = 1080, scale = 1.5 },
  ["HEADLESS-1"] = { width = 1280, height = 720, scale = 1 },
  ["DP-2"] = { width = 2560, height = 1440, scale = 2 },
}

local positions = computePositions({ "eDP-1", "HEADLESS-1", "DP-2" }, monitorsByName)

assert(positions["eDP-1"].x == 0, "first monitor x should be 0")
assert(positions["eDP-1"].y == 0)
-- 1920 / 1.5 = 1280
assert(positions["HEADLESS-1"].x == 1280, "got " .. tostring(positions["HEADLESS-1"].x))
-- 1280 + 1280 / 1 = 2560
assert(positions["DP-2"].x == 2560, "got " .. tostring(positions["DP-2"].x))

print("compute_positions_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/compute_positions_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'loadfile'... file not found)` since `writer_service.luau` doesn't exist yet

- [ ] **Step 3: Create `writer_service.luau` with `computePositions`**

```lua
--!nonstrict

local REQUEST_KEY = "hyprland-display-config.apply_request"
local RESULT_KEY = "hyprland-display-config.apply_result"

function computePositions(orderList, monitorsByName)
  local positions = {}
  local cursorX = 0
  for _, name in ipairs(orderList) do
    local monitor = monitorsByName[name]
    if monitor ~= nil then
      positions[name] = { x = cursorX, y = 0 }
      local scale = monitor.scale
      if scale == nil or scale <= 0 then scale = 1 end
      cursorX = cursorX + math.floor(monitor.width / scale)
    end
  end
  return positions
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/compute_positions_test.lua`
Expected: `compute_positions_test: ok`

- [ ] **Step 5: Commit**

```bash
git add writer_service.luau tests/compute_positions_test.lua
git commit -m "Add computePositions to writer_service.luau"
```

---

### Task 7: `renderManagedFile` — pure Lua-source generation

**Files:**
- Modify: `~/Develop/hyprland-display-config/writer_service.luau`
- Create: `~/Develop/hyprland-display-config/tests/render_managed_file_test.lua`

**Interfaces:**
- Consumes: an array of monitor tables shaped like `buildSnapshot`'s
  `snapshot.monitors` entries, but each with `x`/`y` already set from
  `computePositions` (Task 6).
- Produces: `renderManagedFile(monitors)` returning a single Lua source
  string. The apply pipeline (Task 9) writes this string to disk.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/render_managed_file_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local monitors = {
  { name = "eDP-1", x = 0, y = 0, scale = 1.5, transform = 0,
    mode = "1920x1080@60.00Hz", disabled = false, workspaces = { 1, 3 } },
  { name = "HEADLESS-1", x = 1280, y = 0, scale = 1, transform = 0,
    mode = "preferred", disabled = false, workspaces = { 2 } },
}

local rendered = renderManagedFile(monitors)

assert(rendered:find('hl.monitor({ output = "eDP-1", mode = "1920x1080@60.00Hz", position = "0x0", scale = 1.5, transform = 0, disabled = false })', 1, true) ~= nil,
  "eDP-1 monitor line missing or malformed:\n" .. rendered)
assert(rendered:find('hl.monitor({ output = "HEADLESS-1", mode = "preferred", position = "1280x0", scale = 1, transform = 0, disabled = false })', 1, true) ~= nil,
  "HEADLESS-1 monitor line missing or malformed:\n" .. rendered)
assert(rendered:find('hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })', 1, true) ~= nil)
assert(rendered:find('hl.workspace_rule({ workspace = "3", monitor = "eDP-1" })', 1, true) ~= nil)
assert(rendered:find('hl.workspace_rule({ workspace = "2", monitor = "HEADLESS-1" })', 1, true) ~= nil)

print("render_managed_file_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/render_managed_file_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'renderManagedFile')`

- [ ] **Step 3: Implement `renderManagedFile` in `writer_service.luau`**

Append below `computePositions`:

```lua
local function formatScale(value)
  if value == math.floor(value) then
    return string.format("%d", value)
  end
  return tostring(value)
end

function renderManagedFile(monitors)
  local lines = {
    "-- Generated by maddingo/hyprland-display-config. Do not edit by hand;",
    "-- changes made here are overwritten the next time the plugin applies.",
    "",
  }
  for _, monitor in ipairs(monitors) do
    local position = string.format("%dx%d", monitor.x, monitor.y)
    lines[#lines + 1] = string.format(
      'hl.monitor({ output = %q, mode = %q, position = %q, scale = %s, transform = %d, disabled = %s })',
      monitor.name, monitor.mode, position, formatScale(monitor.scale),
      monitor.transform, tostring(monitor.disabled)
    )
  end
  lines[#lines + 1] = ""
  for _, monitor in ipairs(monitors) do
    for _, workspaceId in ipairs(monitor.workspaces) do
      lines[#lines + 1] = string.format(
        'hl.workspace_rule({ workspace = "%d", monitor = %q })',
        workspaceId, monitor.name
      )
    end
  end
  lines[#lines + 1] = ""
  return table.concat(lines, "\n")
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/render_managed_file_test.lua`
Expected: `render_managed_file_test: ok`

- [ ] **Step 5: Commit**

```bash
git add writer_service.luau tests/render_managed_file_test.lua
git commit -m "Add renderManagedFile to writer_service.luau"
```

---

### Task 8: `ensureRequireLine` — idempotent include-line insertion

**Files:**
- Modify: `~/Develop/hyprland-display-config/writer_service.luau`
- Create: `~/Develop/hyprland-display-config/tests/ensure_require_line_test.lua`

**Interfaces:**
- Consumes: nothing from other tasks.
- Produces: `ensureRequireLine(text, requireLine)` returning updated text
  with `requireLine` present exactly once. The apply pipeline (Task 9)
  uses this on the user's `hyprland.lua` contents.

- [ ] **Step 1: Write the failing test**

```lua
-- tests/ensure_require_line_test.lua
noctalia = {
  commandExists = function() return false end,
  runAsync = function() return false end,
  getConfig = function() return nil end,
  writeFile = function() return true end,
  readFile = function() return nil end,
  state = { set = function() end, get = function() end, watch = function() end },
}

assert(loadfile("writer_service.luau"))()

local requireLine = 'require("hyprland-display-config")'

-- Case 1: line absent, gets appended with a trailing newline preserved
local original = 'require("config.monitors")\n'
local updated = ensureRequireLine(original, requireLine)
assert(updated == 'require("config.monitors")\n' .. requireLine .. '\n',
  "unexpected result:\n" .. updated)

-- Case 2: line already present, text unchanged
local alreadyThere = 'require("config.monitors")\n' .. requireLine .. '\n'
local unchanged = ensureRequireLine(alreadyThere, requireLine)
assert(unchanged == alreadyThere, "should be idempotent")

-- Case 3: file has no trailing newline
local noTrailingNewline = 'require("config.monitors")'
local withNewlineAdded = ensureRequireLine(noTrailingNewline, requireLine)
assert(withNewlineAdded == 'require("config.monitors")\n' .. requireLine .. '\n',
  "unexpected result:\n" .. withNewlineAdded)

print("ensure_require_line_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/ensure_require_line_test.lua`
Expected: FAIL — `attempt to call a nil value (global 'ensureRequireLine')`

- [ ] **Step 3: Implement `ensureRequireLine` in `writer_service.luau`**

Append below `renderManagedFile`:

```lua
function ensureRequireLine(text, requireLine)
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    if line == requireLine then
      return text
    end
  end
  if text:sub(-1) ~= "\n" then
    text = text .. "\n"
  end
  return text .. requireLine .. "\n"
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd ~/Develop/hyprland-display-config && lua tests/ensure_require_line_test.lua`
Expected: `ensure_require_line_test: ok`

- [ ] **Step 5: Commit**

```bash
git add writer_service.luau tests/ensure_require_line_test.lua
git commit -m "Add ensureRequireLine to writer_service.luau"
```

---

### Task 9: Wire the full apply pipeline (live-apply + validate + commit + reload)

**Files:**
- Modify: `~/Develop/hyprland-display-config/writer_service.luau`
- Create: `~/Develop/hyprland-display-config/tests/writer_apply_test.lua`
- Create: `~/Develop/hyprland-display-config/tests/writer_apply_validation_failure_test.lua`

**Interfaces:**
- Consumes: `computePositions` (Task 6), `renderManagedFile` (Task 7),
  `ensureRequireLine` (Task 8).
- Produces: watches `noctalia.state` key
  `"hyprland-display-config.apply_request"` for requests shaped
  `{ request_id = <string>, monitors = { {name, width, mode, scale,
  transform, disabled, workspaces = {ids...}}, ... } }` (array order = desired
  left-to-right order). Publishes
  `{ request_id = <string>, status = "ok" | "error", message = <string,
  only when status == "error"> }` to
  `"hyprland-display-config.apply_result"`. Task 10 (`panel.luau`)
  dispatches requests in this exact shape and watches this exact result key.

This is the largest task in the plan. Read it fully before starting.

- [ ] **Step 1: Write the failing success-path test**

```lua
-- tests/writer_apply_test.lua
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local ranCommands = {}
local hyprlandConfigPath = "/tmp/hdc-test/hyprland.lua"
local managedFilePath = "/tmp/hdc-test/hyprland-display-config.lua"

noctalia = {
  getConfig = function(key)
    if key == "hyprland_config" then return hyprlandConfigPath end
    return nil
  end,
  expandPath = function(path) return path end,
  readFile = function(path)
    if path == hyprlandConfigPath then return 'require("config.monitors")\n' end
    return nil
  end,
  writeFile = function(path, content)
    writtenFiles[path] = content
    return true
  end,
  fileExists = function(path) return writtenFiles[path] ~= nil or path == hyprlandConfigPath end,
  commandExists = function(name) return name == "hyprctl" or name == "Hyprland" end,
  runAsync = function(command, callback)
    ranCommands[#ranCommands + 1] = command
    if command:find("^Hyprland %-%-verify%-config") then
      callback({ exitCode = 0, stdout = "" })
    else
      callback({ exitCode = 0, stdout = "" })
    end
    return true
  end,
  state = {
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    get = function(key) return stateValues[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  notifyError = function() end,
}

assert(loadfile("writer_service.luau"))()

noctalia.state.set("hyprland-display-config.apply_request", {
  request_id = "req-1",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = { 1 } },
  },
})

local result = stateValues["hyprland-display-config.apply_result"]
assert(type(result) == "table", "no result published")
assert(result.request_id == "req-1")
assert(result.status == "ok", "expected ok, got " .. tostring(result.status) .. " message=" .. tostring(result.message))

local managed = writtenFiles[managedFilePath]
assert(managed ~= nil, "managed file was not written to " .. managedFilePath)
assert(managed:find('hl.monitor({ output = "eDP-1"', 1, true) ~= nil, "managed file missing monitor line:\n" .. managed)
assert(managed:find('hl.workspace_rule({ workspace = "1", monitor = "eDP-1" })', 1, true) ~= nil)

local hyprlandConfig = writtenFiles[hyprlandConfigPath]
assert(hyprlandConfig ~= nil, "hyprland.lua was not rewritten with the require line")
assert(hyprlandConfig:find('require("hyprland-display-config")', 1, true) ~= nil)

local sawEval = false
local sawVerify = false
local sawReload = false
for _, command in ipairs(ranCommands) do
  if command:find("hyprctl eval", 1, true) then sawEval = true end
  if command:find("Hyprland %-%-verify%-config") then sawVerify = true end
  if command == "hyprctl reload" then sawReload = true end
end
assert(sawEval, "expected at least one hyprctl eval call for live-apply")
assert(sawVerify, "expected a Hyprland --verify-config call")
assert(sawReload, "expected hyprctl reload after a successful commit")

print("writer_apply_test: ok")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd ~/Develop/hyprland-display-config && lua tests/writer_apply_test.lua`
Expected: FAIL — no result ever gets published (request handling not wired)

- [ ] **Step 3: Write the failing validation-failure-path test**

```lua
-- tests/writer_apply_validation_failure_test.lua
local stateValues = {}
local watchers = {}
local writtenFiles = {}
local hyprlandConfigPath = "/tmp/hdc-test-fail/hyprland.lua"

noctalia = {
  getConfig = function(key)
    if key == "hyprland_config" then return hyprlandConfigPath end
    return nil
  end,
  expandPath = function(path) return path end,
  readFile = function(path)
    if path == hyprlandConfigPath then return 'require("config.monitors")\n' end
    return nil
  end,
  writeFile = function(path, content) writtenFiles[path] = content; return true end,
  fileExists = function(path) return writtenFiles[path] ~= nil or path == hyprlandConfigPath end,
  commandExists = function(name) return name == "hyprctl" or name == "Hyprland" end,
  runAsync = function(command, callback)
    if command:find("^Hyprland %-%-verify%-config") then
      callback({ exitCode = 1, stdout = "", stderr = "config error: bad value" })
    else
      callback({ exitCode = 0, stdout = "" })
    end
    return true
  end,
  state = {
    set = function(key, value)
      stateValues[key] = value
      if watchers[key] ~= nil then watchers[key](value) end
    end,
    get = function(key) return stateValues[key] end,
    watch = function(key, callback) watchers[key] = callback end,
  },
  notifyError = function() end,
}

assert(loadfile("writer_service.luau"))()

noctalia.state.set("hyprland-display-config.apply_request", {
  request_id = "req-2",
  monitors = {
    { name = "eDP-1", width = 1920, mode = "preferred", scale = 1, transform = 0,
      disabled = false, workspaces = {} },
  },
})

local result = stateValues["hyprland-display-config.apply_result"]
assert(type(result) == "table", "no result published")
assert(result.status == "error", "expected error status when validation fails")
assert(type(result.message) == "string" and #result.message > 0, "error result should carry a message")
assert(writtenFiles[hyprlandConfigPath] == nil,
  "hyprland.lua must not be rewritten when validation fails")

print("writer_apply_validation_failure_test: ok")
```

- [ ] **Step 4: Run both tests to confirm they fail the same way**

Run: `cd ~/Develop/hyprland-display-config && lua tests/writer_apply_validation_failure_test.lua`
Expected: FAIL — no result published

- [ ] **Step 5: Implement the apply pipeline in `writer_service.luau`**

Append below `ensureRequireLine`:

```lua
local function shellQuote(value)
  return "'" .. value:gsub("'", "'\\''") .. "'"
end

local function managedFilePath(hyprlandConfigPath)
  local directory = hyprlandConfigPath:match("^(.*)/[^/]*$") or "."
  return directory .. "/hyprland-display-config.lua"
end

local function liveApply(monitors)
  for _, monitor in ipairs(monitors) do
    local position = "auto"
    if monitor.x ~= nil and monitor.y ~= nil then
      position = string.format("%dx%d", monitor.x, monitor.y)
    end
    local script = string.format(
      'hl.monitor({ output = %q, mode = %q, position = %q, scale = %s, transform = %d, disabled = %s })',
      monitor.name, monitor.mode, position, formatScale(monitor.scale),
      monitor.transform, tostring(monitor.disabled)
    )
    noctalia.runAsync("hyprctl eval " .. shellQuote(script), function() end)
  end
  for _, monitor in ipairs(monitors) do
    for _, workspaceId in ipairs(monitor.workspaces) do
      local ruleScript = string.format(
        'hl.workspace_rule({ workspace = "%d", monitor = %q })',
        workspaceId, monitor.name
      )
      noctalia.runAsync("hyprctl eval " .. shellQuote(ruleScript), function() end)
      local moveScript = string.format(
        'hl.dispatch(hl.dsp.workspace.move({ workspace = "%d", monitor = %q }))',
        workspaceId, monitor.name
      )
      noctalia.runAsync("hyprctl eval " .. shellQuote(moveScript), function() end)
    end
  end
end

local function publishResult(requestId, status, message)
  noctalia.state.set(RESULT_KEY, {
    request_id = requestId,
    status = status,
    message = message,
  })
end

local function commitManagedFile(hyprlandConfigPath, content, requestId)
  local targetPath = managedFilePath(hyprlandConfigPath)
  local tempPath = targetPath .. ".tmp"
  if not noctalia.writeFile(tempPath, content) then
    publishResult(requestId, "error", "failed to write temp file " .. tempPath)
    return
  end
  if not noctalia.commandExists("Hyprland") then
    publishResult(requestId, "error", "Hyprland binary not found on PATH, cannot validate")
    return
  end
  noctalia.runAsync("Hyprland --verify-config -c " .. shellQuote(tempPath), function(result)
    if result.exitCode ~= 0 then
      publishResult(requestId, "error", "config validation failed: " .. tostring(result.stderr or result.stdout or ""))
      return
    end
    if not noctalia.writeFile(targetPath, content) then
      publishResult(requestId, "error", "failed to write " .. targetPath)
      return
    end
    local requireLine = 'require("hyprland-display-config")'
    local existing = noctalia.readFile(hyprlandConfigPath) or ""
    local updated = ensureRequireLine(existing, requireLine)
    if updated ~= existing then
      if not noctalia.writeFile(hyprlandConfigPath, updated) then
        publishResult(requestId, "error", "failed to update " .. hyprlandConfigPath)
        return
      end
    end
    noctalia.runAsync("hyprctl reload", function(reloadResult)
      if reloadResult.exitCode ~= 0 then
        publishResult(requestId, "error", "hyprctl reload failed")
        return
      end
      publishResult(requestId, "ok", nil)
    end)
  end)
end

local function handleApplyRequest(request)
  if type(request) ~= "table" or type(request.monitors) ~= "table" then return end
  local requestId = tostring(request.request_id or "")

  local orderList = {}
  local monitorsByName = {}
  for _, monitor in ipairs(request.monitors) do
    orderList[#orderList + 1] = monitor.name
    monitorsByName[monitor.name] = monitor
  end
  local positions = computePositions(orderList, monitorsByName)

  local monitorsWithPositions = {}
  for _, monitor in ipairs(request.monitors) do
    local position = positions[monitor.name] or { x = 0, y = 0 }
    monitorsWithPositions[#monitorsWithPositions + 1] = {
      name = monitor.name,
      mode = monitor.mode,
      scale = monitor.scale,
      transform = monitor.transform,
      disabled = monitor.disabled,
      workspaces = monitor.workspaces,
      x = position.x,
      y = position.y,
    }
  end

  liveApply(monitorsWithPositions)

  local hyprlandConfigPath = noctalia.expandPath(noctalia.getConfig("hyprland_config"))
  local content = renderManagedFile(monitorsWithPositions)
  commitManagedFile(hyprlandConfigPath, content, requestId)
end

noctalia.state.watch(REQUEST_KEY, handleApplyRequest)
```

- [ ] **Step 6: Run both tests to verify they pass**

Run: `cd ~/Develop/hyprland-display-config && lua tests/writer_apply_test.lua && lua tests/writer_apply_validation_failure_test.lua`
Expected: `writer_apply_test: ok` then `writer_apply_validation_failure_test: ok`

- [ ] **Step 7: Run the full test suite so far**

Run: `cd ~/Develop/hyprland-display-config && for f in tests/*.lua; do lua "$f" || exit 1; done`
Expected: all eight tests print `... ok` with no failures

- [ ] **Step 8: Commit**

```bash
git add writer_service.luau tests/writer_apply_test.lua tests/writer_apply_validation_failure_test.lua
git commit -m "Wire writer_service.luau apply pipeline: live-apply, validate, commit, reload"
```

---

### Task 10: `panel.luau` — render cards and dispatch apply requests

**Files:**
- Create: `~/Develop/hyprland-display-config/panel.luau`

**Interfaces:**
- Consumes: snapshot shape from Task 5 (`noctalia.state` key
  `"hyprland-display-config.snapshot"`); apply-request/result contract from
  Task 9 (`"hyprland-display-config.apply_request"` /
  `"...apply_result"`).
- Produces: nothing consumed by later tasks — this is the top of the
  dependency graph. Not unit tested (see Global Constraints: it uses `ui.*`
  and Luau-only operators); verified manually in Task 12.

Note: this task cannot be TDD'd the way the previous ones were — there is
no `ui` global outside the running Noctalia shell to stub against. Write it
directly, then verify it visually in Task 12 using `hyprctl output create
headless` for a second monitor.

- [ ] **Step 1: Write `panel.luau`**

```lua
--!nonstrict

local SNAPSHOT_KEY = "hyprland-display-config.snapshot"
local REQUEST_KEY = "hyprland-display-config.apply_request"
local RESULT_KEY = "hyprland-display-config.apply_result"

local snapshot = { status = "loading", monitors = {}, unboundWorkspaces = {} }
local errorMessage = ""
local requestCounter = 0
local render

local function cloneMonitorsForRequest()
  local monitors = {}
  for _, monitor in ipairs(snapshot.monitors) do
    local mode = monitor.mode
    if mode == nil then
      mode = "preferred"
    end
    monitors[#monitors + 1] = {
      name = monitor.name,
      width = monitor.width,
      mode = mode,
      scale = monitor.scale,
      transform = monitor.transform,
      disabled = monitor.disabled,
      workspaces = monitor.workspaces,
    }
  end
  return monitors
end

local function dispatchApply()
  requestCounter = requestCounter + 1
  local requestId = tostring(os.time()) .. "-" .. tostring(requestCounter)
  noctalia.state.set(REQUEST_KEY, {
    request_id = requestId,
    monitors = cloneMonitorsForRequest(),
  })
end

local function findMonitorIndex(name)
  for index, monitor in ipairs(snapshot.monitors) do
    if monitor.name == name then return index end
  end
  return nil
end

function onReorder(draggedName, targetName)
  local fromIndex = findMonitorIndex(draggedName)
  local toIndex = findMonitorIndex(targetName)
  if fromIndex == nil or toIndex == nil or fromIndex == toIndex then return end
  local moved = table.remove(snapshot.monitors, fromIndex)
  table.insert(snapshot.monitors, toIndex, moved)
  dispatchApply()
  render()
end

function onWorkspaceAssigned(workspaceIdText, monitorName)
  local workspaceId = tonumber(workspaceIdText)
  if workspaceId == nil then return end
  local targetIndex = findMonitorIndex(monitorName)
  if targetIndex == nil then return end
  for _, monitor in ipairs(snapshot.monitors) do
    local kept = {}
    for _, id in ipairs(monitor.workspaces) do
      if id ~= workspaceId then kept[#kept + 1] = id end
    end
    monitor.workspaces = kept
  end
  local target = snapshot.monitors[targetIndex]
  target.workspaces[#target.workspaces + 1] = workspaceId
  table.sort(target.workspaces)
  dispatchApply()
  render()
end

function onModeChanged(monitorName, mode)
  local index = findMonitorIndex(monitorName)
  if index == nil then return end
  snapshot.monitors[index].mode = mode
  dispatchApply()
  render()
end

function onScaleChanged(monitorName, scaleText)
  local index = findMonitorIndex(monitorName)
  local scale = tonumber(scaleText)
  if index == nil or scale == nil or scale <= 0 then return end
  snapshot.monitors[index].scale = scale
  dispatchApply()
  render()
end

function onTransformChanged(monitorName, transformText)
  local index = findMonitorIndex(monitorName)
  local transform = tonumber(transformText)
  if index == nil or transform == nil then return end
  snapshot.monitors[index].transform = transform
  dispatchApply()
  render()
end

function onEnabledToggled(monitorName)
  local index = findMonitorIndex(monitorName)
  if index == nil then return end
  local enabledCount = 0
  for _, monitor in ipairs(snapshot.monitors) do
    if monitor.disabled ~= true then enabledCount = enabledCount + 1 end
  end
  local monitor = snapshot.monitors[index]
  local wouldDisable = monitor.disabled ~= true
  if wouldDisable and enabledCount <= 1 then return end
  monitor.disabled = wouldDisable
  dispatchApply()
  render()
end

function onRefreshClicked()
  render()
end

local function unboundChipRow()
  local chips = {}
  for _, workspaceId in ipairs(snapshot.unboundWorkspaces) do
    chips[#chips + 1] = ui.dragSource({
      key = "unbound-chip-" .. tostring(workspaceId),
      dragType = "workspace-chip",
      payload = tostring(workspaceId),
      width = 32,
      height = 32,
      radius = 6,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = tostring(workspaceId), color = "on_surface", fontWeight = "bold" }),
    })
  end
  return ui.row({ gap = 6, align = "center" }, chips)
end

local function monitorCard(monitor)
  local modeOptions = {}
  for _, mode in ipairs(monitor.availableModes or {}) do
    modeOptions[#modeOptions + 1] = mode
  end
  if #modeOptions == 0 then modeOptions = { "preferred" } end

  local chipChildren = {}
  for _, workspaceId in ipairs(monitor.workspaces) do
    chipChildren[#chipChildren + 1] = ui.dragSource({
      key = "bound-chip-" .. monitor.name .. "-" .. tostring(workspaceId),
      dragType = "workspace-chip",
      payload = tostring(workspaceId),
      width = 32,
      height = 32,
      radius = 6,
      fill = "primary",
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = tostring(workspaceId), color = "on_primary", fontWeight = "bold" }),
    })
  end

  return ui.column({
    key = "card-" .. monitor.name,
    gap = 8,
    padding = 12,
    radius = 10,
    fill = "surface_variant",
    width = 320,
  }, {
    ui.dragSource({
      key = "reorder-" .. monitor.name,
      dragType = "monitor-card",
      payload = monitor.name,
      width = 296,
      height = 28,
      radius = 6,
      align = "center",
      justify = "center",
    }, {
      ui.label({ text = monitor.name, color = "on_surface", fontWeight = "bold" }),
    }),
    ui.dropZone({
      key = "reorder-drop-" .. monitor.name,
      accepts = { "monitor-card" },
      value = monitor.name,
      onDrop = "onReorder",
      height = 4,
      radius = 4,
    }, {}),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Mode", color = "on_surface_variant", fontSize = 11 }),
      ui.select({
        key = "mode-" .. monitor.name,
        options = modeOptions,
        value = monitor.mode or "preferred",
        onChange = "onModeChanged",
        changeArgs = { monitor.name },
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Scale", color = "on_surface_variant", fontSize = 11 }),
      ui.input({
        key = "scale-" .. monitor.name,
        value = tostring(monitor.scale),
        onChange = "onScaleChanged",
        changeArgs = { monitor.name },
      }),
    }),
    ui.row({ gap = 8, align = "center" }, {
      ui.label({ text = "Rotation", color = "on_surface_variant", fontSize = 11 }),
      ui.select({
        key = "transform-" .. monitor.name,
        options = { "0", "1", "2", "3" },
        value = tostring(monitor.transform),
        onChange = "onTransformChanged",
        changeArgs = { monitor.name },
      }),
    }),
    ui.button({
      key = "enabled-" .. monitor.name,
      text = monitor.disabled and "Disabled" or "Enabled",
      variant = monitor.disabled and "ghost" or "primary",
      onClick = "onEnabledToggled",
      clickArgs = { monitor.name },
    }),
    ui.separator({}),
    ui.label({ text = "Workspaces", color = "on_surface_variant", fontSize = 11 }),
    ui.dropZone({
      key = "chip-drop-" .. monitor.name,
      accepts = { "workspace-chip" },
      value = monitor.name,
      onDrop = "onWorkspaceAssigned",
      enabled = monitor.disabled ~= true,
      height = 44,
      radius = 6,
    }, {
      ui.row({ gap = 6, align = "center" }, chipChildren),
    }),
  })
end

render = function()
  if snapshot.status ~= "ready" then
    panel.setContent(ui.column({ padding = 16 }, {
      ui.label({ text = "Loading monitors...", color = "on_surface" }),
    }))
    return
  end

  local cards = {}
  for _, monitor in ipairs(snapshot.monitors) do
    cards[#cards + 1] = monitorCard(monitor)
  end

  local errorBanner = {}
  if errorMessage ~= "" then
    errorBanner[1] = ui.row({
      padding = 8, radius = 6, fill = "error",
    }, {
      ui.label({ text = errorMessage, color = "on_error" }),
    })
  end

  panel.setContent(ui.column({ gap = 12, padding = 16 }, (function()
    local children = {}
    for _, node in ipairs(errorBanner) do children[#children + 1] = node end
    children[#children + 1] = ui.row({ gap = 12, align = "start" }, cards)
    children[#children + 1] = ui.separator({})
    children[#children + 1] = ui.label({ text = "Unassigned workspaces", color = "on_surface_variant", fontSize = 11 })
    children[#children + 1] = unboundChipRow()
    children[#children + 1] = ui.button({ text = "Refresh", onClick = "onRefreshClicked" })
    return children
  end)()))
end

noctalia.state.watch(SNAPSHOT_KEY, function(value)
  if type(value) == "table" then
    snapshot = value
    render()
  end
end)

noctalia.state.watch(RESULT_KEY, function(value)
  if type(value) ~= "table" then return end
  if value.status == "error" then
    errorMessage = tostring(value.message or "apply failed")
  else
    errorMessage = ""
  end
  render()
end)

render()
```

- [ ] **Step 2: Commit**

```bash
git add panel.luau
git commit -m "Add panel.luau: monitor cards, reorder and workspace-chip drag-and-drop"
```

---

### Task 11: `widget.luau` — bar widget that opens the panel

**Files:**
- Create: `~/Develop/hyprland-display-config/widget.luau`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing consumed by other tasks — opens panel id `"panel"` via
  IPC, matching the `[[panel]] id = "panel"` entry from Task 1's
  `plugin.toml`.

- [ ] **Step 1: Write `widget.luau`**

```lua
--!nonstrict

local function render()
  barWidget.setGlyph("layout-grid")
  barWidget.setText("Displays")
end

function onClick()
  noctalia.runAsync("noctalia msg panel-toggle maddingo/hyprland-display-config:panel")
end

render()
```

- [ ] **Step 2: Commit**

```bash
git add widget.luau
git commit -m "Add widget.luau bar widget"
```

---

### Task 12: README and manual multi-monitor verification

**Files:**
- Create: `~/Develop/hyprland-display-config/README.md`

**Interfaces:**
- Consumes: nothing.
- Produces: nothing — this is the final verification task.

- [ ] **Step 1: Write `README.md`**

```markdown
# Hyprland Display Config

A Noctalia panel plugin for Hyprland: view connected monitors as ordered
cards, edit each one's mode/scale/rotation/enabled state, reorder them
left-to-right, and drag workspace-ID chips onto a card to bind that
workspace to that monitor.

## Plugin

| Field | Value |
| --- | --- |
| ID | `maddingo/hyprland-display-config` |
| Entries | Bar widget: `widget`; panel: `panel`; services: `service`, `writer_service` |

## Requirements

Hyprland with `hyprctl` and `Hyprland` on `PATH`, running the native Lua
config parser (`hl.monitor`, `hl.workspace_rule`, `hl.dsp.workspace.move`
via `hyprctl eval`). This plugin does not use `hyprctl keyword` or legacy
`hyprctl dispatch` — both are rejected outright by the Lua-config parser.

## Settings

- **Hyprland config file** (`hyprland_config`, default
  `~/.config/hypr/hyprland.lua`) — the plugin ensures this file
  `require()`s a generated `hyprland-display-config.lua` placed in the same
  directory, and rewrites that generated file on every apply.
- **Workspace count** (`workspace_count`, default `10`) — how many
  workspace-ID chips are offered.

## Local development

```sh
noctalia msg plugins source add hyprland-display-config-dev path ~/Develop/hyprland-display-config
noctalia msg plugins enable maddingo/hyprland-display-config
```

Luau file edits hot-reload; `plugin.toml` changes need
`noctalia msg config-reload`.

Run the standalone test suite (pure logic only — `panel.luau` is excluded,
see below) from the plugin root:

```sh
for f in tests/*.lua; do lua "$f" || exit 1; done
```

## Testing multi-monitor behavior without extra hardware

Hyprland can create virtual outputs at runtime:

```sh
hyprctl output create headless
hyprctl output create headless
hyprctl monitors all -j   # confirm HEADLESS-1, HEADLESS-2 alongside real outputs
```

Open the panel (`noctalia msg panel-toggle
maddingo/hyprland-display-config:panel`), reorder cards, drag workspace
chips onto the headless monitors, and confirm:

- `hyprctl monitors all -j` reflects the new mode/scale/position live.
- `hyprctl workspacerules -j` reflects the new bindings.
- `~/.config/hypr/hyprland-display-config.lua` contains matching
  `hl.monitor`/`hl.workspace_rule` calls.
- `~/.config/hypr/hyprland.lua` contains
  `require("hyprland-display-config")` exactly once.

Remove the virtual outputs afterward:

```sh
hyprctl output remove HEADLESS-1
hyprctl output remove HEADLESS-2
```

## IPC

Open the panel directly: `noctalia msg panel-toggle
maddingo/hyprland-display-config:panel`.
```

- [ ] **Step 2: Commit the README**

```bash
git add README.md
git commit -m "Add README"
```

- [ ] **Step 3: Register the plugin as a local dev source**

```bash
noctalia msg plugins source add hyprland-display-config-dev path ~/Develop/hyprland-display-config
noctalia msg plugins enable maddingo/hyprland-display-config
```

Expected: both commands print `ok`, and `maddingo/hyprland-display-config`
now appears when running `noctalia msg plugins list`.

- [ ] **Step 4: Create two virtual outputs for a real multi-monitor test**

```bash
hyprctl output create headless
hyprctl output create headless
hyprctl monitors all -j
```

Expected: JSON array includes `eDP-1` plus two `HEADLESS-*` entries.

- [ ] **Step 5: Open the panel and exercise every interaction**

```bash
noctalia msg panel-toggle maddingo/hyprland-display-config:panel
```

In the panel: drag a monitor card to reorder it, change a monitor's mode
and rotation via the selects, type a new scale, drag a workspace chip onto
a headless card, then drag it onto a different card to confirm re-binding
works, and toggle a monitor's enabled state off and back on.

- [ ] **Step 6: Verify the live and persisted state after each interaction**

```bash
hyprctl monitors all -j
hyprctl workspacerules -j
cat ~/.config/hypr/hyprland-display-config.lua
grep -n 'require("hyprland-display-config")' ~/.config/hypr/hyprland.lua
```

Expected: `hyprctl monitors all -j` positions/modes match what was set in
the panel; `hyprctl workspacerules -j` shows the dragged chip's binding;
the generated file's `hl.monitor`/`hl.workspace_rule` calls match; the
`require` line appears exactly once.

- [ ] **Step 7: Verify the validation-failure path does not corrupt state**

```bash
cp ~/.config/hypr/hyprland-display-config.lua /tmp/hdc-before-corruption.lua
echo 'hl.monitor({ output = "does-not-exist", mode = "bogus mode !!" })' >> ~/.config/hypr/hyprland-display-config.lua
Hyprland --verify-config -c ~/.config/hypr/hyprland-display-config.lua; echo "exit=$?"
```

Expected: non-zero exit, confirming `Hyprland --verify-config` really does
reject a bad managed file — this is the same check `writer_service.luau`
runs before ever committing, so a bad generated value cannot reach
`hyprland.lua`.

```bash
cp /tmp/hdc-before-corruption.lua ~/.config/hypr/hyprland-display-config.lua
hyprctl reload
```

- [ ] **Step 8: Clean up the virtual outputs and dev source**

```bash
hyprctl output remove HEADLESS-1
hyprctl output remove HEADLESS-2
hyprctl monitors all -j   # confirm only the real monitor(s) remain
```

- [ ] **Step 9: Tag the verified state**

```bash
cd ~/Develop/hyprland-display-config
git add -A
git status --short   # confirm nothing unexpected is staged
git commit -m "v0.1.0: verified end-to-end against live and headless Hyprland outputs" --allow-empty
git tag v0.1.0
```

---

## Self-Review Notes

- **Spec coverage**: per-monitor mode/scale/rotation/enabled editing
  (Task 10), reordering→position (Tasks 6, 9, 10), workspace chip
  drag-to-assign (Tasks 9, 10), live apply + persistence with
  validate/commit/reload (Task 9), `workspace_count` setting (Tasks 1, 5),
  `hyprland_config` setting and idempotent `require` insertion (Tasks 1, 8,
  9), standalone repo scaffolding (Task 1), testing via headless outputs
  (Task 12) — all covered.
- **Placeholder scan**: no TBD/TODO; every step has complete, runnable
  code and exact commands with expected output.
- **Type consistency checked**: `computePositions(orderList,
  monitorsByName)` (Task 6) is called with `(orderList, monitorsByName)` in
  Task 9's `handleApplyRequest`, matching — this caught a real bug during
  review: `monitorsByName` entries there come straight from
  `request.monitors`, so the apply-request shape (dispatched by
  `panel.luau`'s `cloneMonitorsForRequest`, Task 10) must include `width`,
  since `computePositions` divides it by scale for every monitor in the
  order list, not just non-last ones. Fixed by adding `width` to the
  request shape (Task 9's interface note and both its test fixtures) and to
  `cloneMonitorsForRequest`'s output (Task 10). `renderManagedFile(monitors)`
  (Task 7) is called with the post-`computePositions` array in Task 9,
  which carries `x`/`y`/`mode`/`scale`/`transform`/`disabled`/`workspaces`
  on every element — the exact fields `renderManagedFile` reads.
  `ensureRequireLine(text, requireLine)` (Task 8) is called with that exact
  signature in Task 9's `commitManagedFile`. The state keys
  `hyprland-display-config.snapshot` / `.apply_request` / `.apply_result`
  are identical string literals across `service.luau`, `writer_service.luau`,
  and `panel.luau`.
