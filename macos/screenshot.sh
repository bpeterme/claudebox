#!/bin/bash
# Takes an interactive screenshot (drag to select region or click a window)
# and saves it to the cbox share folder, where it becomes visible inside
# any running container at ~/share/.
#
# See macos/README.md for how to assign a keyboard shortcut to this script.

[[ -f "$HOME/.cbox.env" ]] && . "$HOME/.cbox.env"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-$HOME/.cbox/share}"

mkdir -p "$CBOX_SHARE_DIR"
screencapture -i "$CBOX_SHARE_DIR/screenshot-$(date +%Y%m%d-%H%M%S).png"
