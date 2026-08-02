#!/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="$HOME/.config/hypr"

if [ -L "$TARGET" ]; then
    echo "Removing existing symlink $TARGET"
    rm "$TARGET"
elif [ -e "$TARGET" ]; then
    BACKUP="$TARGET.backup-$(date +%Y%m%d-%H%M%S)"
    echo "Existing $TARGET found, moving to $BACKUP"
    mv "$TARGET" "$BACKUP"
fi

mkdir -p "$(dirname "$TARGET")"
ln -s "$SCRIPT_DIR/config-hypr" "$TARGET"
echo "Linked $SCRIPT_DIR/config-hypr -> $TARGET"
