#!/bin/bash
# Takes an interactive screenshot (drag to select region or click a window)
# and saves it to the cbox share folder, where it becomes visible inside
# any running container at ~/share/.
#
# See macos/README.md for how to assign a keyboard shortcut to this script.

[[ -f "${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env" ]] && \
  . "${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claudebox/share}"

mkdir -p "$CBOX_SHARE_DIR"
screencapture -i "$CBOX_SHARE_DIR/screenshot-$(date +%Y%m%d-%H%M%S).png"
