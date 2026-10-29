
-- Picture-in-Picture
hl.window_rule({
    match             = { title = "^([Pp]icture[-\\s]?[Ii]n[-\\s]?[Pp]icture)(.*)$" },
    float             = true,
    keep_aspect_ratio = true,
    move              = "73% 72%",
    size              = "25% 25%",
    pin               = true,
})

-- Gaming
local gamingApps = "^(steam_app.*|gamescope)$"
local gamingWorkspace = "name:gaming"

hl.window_rule({ match = { content = "game" }, workspace = gamingWorkspace })
hl.window_rule({ match = { class = gamingApps }, workspace = gamingWorkspace })
hl.window_rule({ match = { class = "^(steam)$", title = "^(Friends List)$" }, float = true })
hl.window_rule({
    match = {
        class = "^(steam)$",
        title = "^(Launching\\.{3})$"
    },
    float     = true,
    center    = true,
    workspace = gamingWorkspace,
})
hl.window_rule({
    match = {
        class         = gamingApps,
        title         = "^(.+)$",
        initial_title = "negative:^(.*\\\\home\\\\.*)$",
    },
    size             = "monitor_w monitor_h",
    fullscreen_state = 2,
    content          = "game",
})
hl.window_rule({
    match = {
        class         = "^(steam_app.*)$",
        initial_title = "^$",
    },
    float            = true,
    center           = true,
    fullscreen       = false,
    fullscreen_state = 0,
})

-- Apps
local primaryWorkspace = 1

hl.window_rule({ match = { class = "^(.*\\.exe)$", float = true }, primaryWorkspace, center = true, fullscreen_state = 0 })
hl.window_rule({ match = { class = "^(vesktop|discord)$" }, primaryWorkspace })
hl.window_rule({ match = { class = "^(.*[Cc]alculator.*)$" }, float = true, size = "380 616" })
hl.window_rule({ match = { class = "^(org.kde.keditfiletype)$" }, float = true })
hl.window_rule({ match = { class = "^(org.kde.ark)$" }, size = "(monitor_w*0.40) (monitor_h*0.40)" })
--[[
hl.window_rule({
    match = {
        class = "^(org.kde.dolphin)$",
        title = "negative:^(Moving.*|Create New.*|Extract.*|Compress.*|Copying.*|Progress.*|Configure.*|Properties.*|Choose\\sApplication.*)$",
    },
    float = true,
    move = {
        "max(0, min(cursor_x - 650, monitor_w - 1320))",
        "max(0, min(cursor_y - 50, monitor_h - 820))"
    },
    size = "1300 800",
})
--]]
hl.window_rule({ match = { class = "^(org.kde.dolphin)$" }, float = true, center = true, size = "1200 600" })

-- Opacity Overrides
local terminals = "^(kitty|ghostty|[Kk]onsole|Alacritty|gnome-terminal|xfce[0-9]?-terminal)$"

hl.window_rule({ match = { class = "^(firefox|zen)$" }, opacity = "1.0 override" })
hl.window_rule({ match = { class = terminals }, opacity = "1.0 override" }) -- override opacity in favor of terminal settings for opacity
hl.window_rule({ match = { class = "^(mpv|org.kde.haruna|.*plex.*|org\\.kde\\.gwenview|.*vlc.*)$" }, opacity = "1.0 override" })

-- Float Utility Windows
local floatApps = {
    { class = "^(kvantummanager|qt[56]ct|nwg-look)$" },
    { class = "^(org.pulseaudio.pavucontrol|blueman-manager|nm-applet|nm-connection-editor)$" },
    { title = "^(Winetricks.*|Protontricks.*)$" },
}
for _, m in ipairs(floatApps) do hl.window_rule({ match = m, float = true }) end

hl.window_rule({ match = { float = true }, move = "50% 50%" })

-- Float Common Modals
local modalMatches = {
    { title = "^(Open|Authentication Required|Add Folder to Workspace|Choose Files|Save As|Confirm to replace files|File Operation Progress)$" },
    { initial_title = "^(Open File)$" },
    { class = "^([Xx]dg-desktop-portal-gtk)$" },
    { title = "^(File Upload|Choose wallpaper|Library)(.*)$" },
    { class = "^(.*dialog.*)$" },
    { title = "^(.*dialog.*)$" },
    { class = "^(hyprland-share-picker)$"},
}
for _, m in ipairs(modalMatches) do hl.window_rule({ match = m, float = true }) end

-- The generic float centering rule above centers against the full monitor
-- box, not the bar-adjusted usable area, so a tall floating window (e.g. a
-- Save As dialog) can land with its top edge behind the noctalia bar. Nudge
-- it down if so. Excludes jetbrains-toolbox, which has its own handler below.
local function noctalia_bar_bottom()
    local bar_bottom = 0
    for _, layer in ipairs(hl.get_layers({ namespace = "noctalia-bar-default" })) do
        bar_bottom = math.max(bar_bottom, layer.y + layer.h)
    end
    return bar_bottom
end

hl.on("window.open", function(win)
    if win.class == "jetbrains-toolbox" then return end
    if not win.floating then return end

    hl.timer(function()
        local bar_bottom = noctalia_bar_bottom()
        if bar_bottom == 0 then return end

        if win.at.y < bar_bottom then
            hl.dispatch(hl.dsp.window.move({ x = win.at.x, y = bar_bottom + 8, window = "address:" .. win.address }))
        end
    end, { timeout = 50, type = "oneshot" })
end)

-- JetBrains Toolbox anchors its window to where it thinks the tray icon is.
-- Under XWayland it gets that wrong and asks for x = -440, off the left edge of
-- the whole layout, so the window maps invisibly on whatever workspace the
-- leftmost monitor happens to be showing, and looks like it never opened.
hl.window_rule({
    name  = "jetbrains-toolbox",
    match = { class = "^jetbrains-toolbox$" },

    float = true,
})

-- Place that window under the cursor, on the monitor whose tray icon was
-- clicked. A `move` rule can't express this: the Lua bridge takes plain
-- coordinates only, with no cursor or onscreen keyword, so a fixed position
-- would be wrong on whichever monitor you didn't click.
local function place_toolbox_at_cursor(win)
    local mon    = hl.get_monitor_at_cursor() or hl.get_active_monitor()
    local cursor = hl.get_cursor_pos()
    if not mon or not cursor then return nil end

    local function clamp(v, lo, hi)
        if hi < lo then return lo end
        return math.max(lo, math.min(v, hi))
    end

    -- Monitor width/height are physical pixels, window coordinates are logical.
    local margin = 10
    local mon_w  = mon.width / mon.scale
    local mon_h  = mon.height / mon.scale
    local top    = math.max(mon.y, noctalia_bar_bottom()) + margin

    local x = math.floor(clamp(cursor.x - win.size.x / 2, mon.x + margin, mon.x + mon_w - win.size.x - margin))
    local y = math.floor(clamp(cursor.y + margin,         top,            mon.y + mon_h - win.size.y - margin))

    hl.dispatch(hl.dsp.window.move({ window = win, workspace = mon.active_workspace.id }))
    hl.dispatch(hl.dsp.window.move({ window = win, x = x, y = y }))

    return { x = x, y = y }
end

hl.on("window.open", function(win)
    if win.class ~= "jetbrains-toolbox" then return end

    local target = place_toolbox_at_cursor(win)
    if not target then return end

    -- Placing it once is not enough: Toolbox re-asserts its own off-screen
    -- position a moment after the window maps, so hold it in place briefly.
    -- Dragging the window yourself within that second will be undone too.
    local ticks = 0
    local timer
    timer = hl.timer(function()
        ticks = ticks + 1
        local ok = pcall(function()
            if win.mapped and (win.at.x ~= target.x or win.at.y ~= target.y) then
                hl.dispatch(hl.dsp.window.move({ window = win, x = target.x, y = target.y }))
            end
        end)
        if not ok or ticks >= 12 then timer:set_enabled(false) end
    end, { timeout = 100, type = "repeat" })
end)

-- Ignore maximize requests from all apps. You'll probably like this.
local suppressMaximizeRule = hl.window_rule({
    name  = "suppress-maximize-events",
    match = { class = ".*" },

    suppress_event = "maximize",
})
-- suppressMaximizeRule:set_enabled(false)

-- Fix some dragging issues with XWayland
hl.window_rule({
    name  = "fix-xwayland-drags",
    match = {
        class      = "^$",
        title      = "^$",
        xwayland   = true,
        float      = true,
        fullscreen = false,
        pin        = false,
    },

    no_focus = true,
})
