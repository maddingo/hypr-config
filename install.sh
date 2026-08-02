#!/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOCTALIA_REPO="https://github.com/noctalia-dev/noctalia"
NOCTALIA_SRC="${NOCTALIA_SRC:-$HOME/Develop/noctalia}"

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

# install-noctalia.sh builds in place, so it has to run from a Noctalia checkout.
install_noctalia() {
    if [ ! -d "$NOCTALIA_SRC/.git" ]; then
        echo "Cloning Noctalia into $NOCTALIA_SRC"
        git clone "$NOCTALIA_REPO" "$NOCTALIA_SRC"
    fi

    cp "$SCRIPT_DIR/install-noctalia.sh" "$NOCTALIA_SRC/"
    "$NOCTALIA_SRC/install-noctalia.sh" --install
}

if ! command -v noctalia >/dev/null; then
    echo "noctalia not found, building it (this takes a while, and apt needs sudo)"
    install_noctalia
fi

link_config config-hypr hypr
link_config config-noctalia noctalia
