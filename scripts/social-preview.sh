#!/bin/bash
# Draws docs/brand/social-preview.png, 1280 x 640 pixels: the picture GitHub shows when a link to the repository is shared.
#
#   scripts/social-preview.sh
#
# GitHub has no API for that picture. After a change, upload the file by hand: repository Settings, General, Social preview,
# Edit, Upload an image.
#
# It draws the mark with the outlines in HalfLidCore (run scripts/build.sh first) and the panel from docs/screenshots (made by
# scripts/screenshots.sh). It starts no part of Half Lid and writes only the one file.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f build/lib/libHalfLidCore.a ] || { echo "social-preview: run scripts/build.sh first" >&2; exit 1; }
PANEL="docs/screenshots/panel-active-dark.png"
OUT="docs/brand/social-preview.png"
[ -f "$PANEL" ] || { echo "social-preview: $PANEL is missing (scripts/screenshots.sh makes it)" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
swiftc -swift-version 5 -O -target "$(uname -m)-apple-macos14.0" -I build/lib -L build/lib -lHalfLidCore \
  -framework AppKit -framework IOKit -lsqlite3 scripts/social-preview.swift -o "$WORK/social-preview"
"$WORK/social-preview" "$PANEL" "$OUT"

# GitHub asks for at least 640 x 320, recommends 1280 x 640, and refuses files of 1 MB or more.
WIDTH="$(sips -g pixelWidth "$OUT" | awk '/pixelWidth/ {print $2}')"
HEIGHT="$(sips -g pixelHeight "$OUT" | awk '/pixelHeight/ {print $2}')"
BYTES="$(stat -f %z "$OUT")"
[ "$WIDTH" = 1280 ] && [ "$HEIGHT" = 640 ] || { echo "social-preview: $OUT is ${WIDTH}x${HEIGHT}, expected 1280x640" >&2; exit 1; }
[ "$BYTES" -lt 1000000 ] || { echo "social-preview: $OUT is $BYTES bytes, GitHub accepts less than 1 MB" >&2; exit 1; }
echo "$OUT: ${WIDTH}x${HEIGHT}, $BYTES bytes"
