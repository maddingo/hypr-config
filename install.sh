#!/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOCTALIA_REPO="https://github.com/noctalia-dev/noctalia"
NOCTALIA_SRC="${NOCTALIA_SRC:-$HOME/Develop/noctalia}"

HYPRLAND_REPO="https://github.com/LinuxBeginnings/Ubuntu-Hyprland"
HYPRLAND_SRC="${HYPRLAND_SRC:-$HOME/Ubuntu-Hyprland}"

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
