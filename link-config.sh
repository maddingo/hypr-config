#!/usr/bin/env bash
#
# Symlinks this repo's config directories into ~/.config. Run standalone to
# re-link without touching the Hyprland/Noctalia installs; install.sh calls it
# up front, before it builds anything.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

link_config() {
    local source="$SCRIPT_DIR/$1"
    local target="$HOME/.config/$2"

    if [ -L "$target" ]; then
        echo "Removing existing symlink $target"
        rm "$target"
    elif [ -e "$target" ]; then
        local backup="$target.backup-$(date +%Y%m%d-%H%M%S)"
        echo "Existing $target found, moving to $backup"
        mv "$target" "$backup"
    fi

    mkdir -p "$(dirname "$target")"
    ln -s "$source" "$target"
    echo "Linked $source -> $target"
}

# Detect a session on this machine, not just this shell: this may well be run
# from a TTY while Hyprland is still up on another VT.
hyprland_is_running() {
    [ -n "${HYPRLAND_INSTANCE_SIGNATURE:-}" ] && return 0
    pgrep -x Hyprland >/dev/null 2>&1
}

# Hyprland writes a stock hyprland.lua into ~/.config/hypr on startup, so a
# symlink created while it is running gets clobbered or ignored. Refuse instead
# of leaving the user with a config that silently does nothing.
if hyprland_is_running; then
    cat >&2 <<EOF
Hyprland is currently running — stopping here.

Linking the config files from inside a running session does not work: Hyprland
re-creates a stock ~/.config/hypr/hyprland.lua, which replaces or shadows the
symlink this script would create.

Do this instead:

  1. Log out of Hyprland completely.
  2. Switch to a text console with Ctrl+Alt+F3 and log in there.
  3. Run $SCRIPT_DIR/install.sh again — or $SCRIPT_DIR/link-config.sh on its
     own if Hyprland and Noctalia are already installed.
  4. Switch back with Ctrl+Alt+F1 (or F2) and log in to Hyprland.

Or link them by hand from that console:

  mv ~/.config/hypr ~/.config/hypr.backup          # only if it exists
  mv ~/.config/noctalia ~/.config/noctalia.backup  # only if it exists
  ln -s $SCRIPT_DIR/config-hypr ~/.config/hypr
  ln -s $SCRIPT_DIR/config-noctalia ~/.config/noctalia
EOF
    exit 1
fi

link_config config-hypr hypr
link_config config-noctalia noctalia
link_config config-alacritty alacritty
