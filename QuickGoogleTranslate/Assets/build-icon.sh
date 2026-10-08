#!/bin/zsh
# Convert the original generated PNG into standard macOS icon representations.
set -eu
cd "${0:A:h}"
ICONSET=$(mktemp -d -t qgt-app-icon).iconset
mkdir -p "$ICONSET"
trap 'rm -r -- "$ICONSET"; rmdir "${ICONSET%.iconset}"' EXIT
for SIZE in 16 32 128 256 512; do
    sips -s format png -z "$SIZE" "$SIZE" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    RETINA=$((SIZE * 2))
    sips -s format png -z "$RETINA" "$RETINA" AppIcon.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o AppIcon.icns
