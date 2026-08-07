#!/usr/bin/env bash
# ==================================================
#  KoolDots (2026)
#  Project URL: https://github.com/LinuxBeginnings
#  License: GNU GPLv3
#  SPDX-License-Identifier: GPL-3.0-or-later
# ==================================================

# Ensure weather cache is up-to-date before locking (Waybar/lockscreen readers)
bash "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/UserScripts/WeatherWrap.sh" >/dev/null 2>&1 &

# Single entry point: logind broadcasts the Lock signal and hypridle's
# lock_cmd starts hyprlock. Starting hyprlock here as well would race
# with that and leave stale instances behind.
loginctl lock-session

