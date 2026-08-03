#!/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOCTALIA_REPO="https://github.com/noctalia-dev/noctalia"
NOCTALIA_SRC="${NOCTALIA_SRC:-$HOME/Develop/noctalia}"

HYPRLAND_REPO="https://github.com/LinuxBeginnings/Ubuntu-Hyprland"
HYPRLAND_SRC="${HYPRLAND_SRC:-$HOME/Develop/Ubuntu-Hyprland}"

# Hyprland resolves its config path once at startup — lua if
# ~/.config/hypr/hyprland.lua exists, otherwise the legacy hyprland.conf — and
# does not revisit that choice on reload. Replacing ~/.config/hypr under a live
# session makes it re-read whichever path it already latched onto; if the
# incoming tree has no file there, Hyprland writes a stub config to it and runs
# off that. The stub lands inside this repo, through the very symlink being
# created. Observed 2026-08-02: the session dropped to 6 keybinds and unset gaps.
assert_no_live_hyprland() {
    [ -n "${HYPR_ALLOW_LIVE_RELINK:-}" ] && return 0
    pgrep -x Hyprland >/dev/null 2>&1 || return 0

    cat >&2 <<EOF
Refusing to relink ~/.config/hypr: Hyprland is running (pid $(pgrep -x Hyprland | tr '\n' ' ')).

Swapping the config directory under a live compositor makes it autogenerate a
stub config into this repo and run off that. Pick one:

  * switch to a TTY (Ctrl+Alt+F3), log out of Hyprland, and rerun there
  * run this before starting a Hyprland session
  * HYPR_ALLOW_LIVE_RELINK=1 $0
    (accepts the stub; you have to log out and back in either way)

Nothing has been changed.
EOF
    exit 1
}

link_config() {
    local source="$SCRIPT_DIR/$1"
    local target="$HOME/.config/$2"

    # Enforced here as well as up front, so the function stays safe if reused.
    [ "$2" = "hypr" ] && assert_no_live_hyprland

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

# Stock Ubuntu 24.04 says ID=ubuntu; derivatives (TUXEDO OS) say otherwise but
# still set UBUNTU_CODENAME, so key on that.
is_ubuntu_2404() {
    [ -r /etc/os-release ] || return 1
    local UBUNTU_CODENAME=""
    . /etc/os-release
    [ "$UBUNTU_CODENAME" = "noble" ]
}

# Upstream's installer has no flag for skipping its dotfiles, only a whiptail
# prompt, so drive it with hyprland-preset.sh (dots="N"). It still asks a few
# things and needs sudo, so this is not unattended.
install_hyprland() {
    if [ ! -d "$HYPRLAND_SRC/.git" ]; then
        echo "Cloning Ubuntu-Hyprland into $HYPRLAND_SRC"
        git clone --depth=1 -b 24.04 "$HYPRLAND_REPO" "$HYPRLAND_SRC"
    fi

    cd "$HYPRLAND_SRC"
    chmod +x install.sh
    ./install.sh --preset "$SCRIPT_DIR/hyprland-preset.sh"
    cd "$SCRIPT_DIR"
}

# install-noctalia.sh builds in place, so it has to run from a Noctalia checkout.
install_noctalia() {
    if [ ! -d "$NOCTALIA_SRC/.git" ]; then
        echo "Cloning Noctalia into $NOCTALIA_SRC"
        git clone "$NOCTALIA_REPO" "$NOCTALIA_SRC"
    fi

    cp "$SCRIPT_DIR/install-noctalia.sh" "$NOCTALIA_SRC/"
    "$NOCTALIA_SRC/install-noctalia.sh" --install
}

# Checked before anything else: link_config enforces it too, but only at the very
# end, and the Noctalia build in between can take half an hour.
assert_no_live_hyprland

if command -v Hyprland >/dev/null; then
    echo "Hyprland already installed, skipping"
elif ! is_ubuntu_2404; then
    echo "Hyprland not found, and this is not Ubuntu 24.04 — install it yourself" >&2
    exit 1
else
    echo "Hyprland not found, installing it without the KooL dotfiles (needs sudo)"
    install_hyprland
    # Upstream's installer reports its own failures but does not always exit
    # non-zero, so check the result rather than trusting the exit status.
    command -v Hyprland >/dev/null \
        || { echo "Hyprland still not on PATH after $HYPRLAND_SRC/install.sh — see its logs" >&2; exit 1; }
fi

if ! command -v noctalia >/dev/null; then
    echo "noctalia not found, building it (this takes a while, and apt needs sudo)"
    install_noctalia
fi

link_config config-hypr hypr
link_config config-noctalia noctalia
