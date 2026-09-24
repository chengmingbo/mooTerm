#!/bin/bash
# Regenerate the app icon from a square source PNG (defaults to the logo).
#
# Usage: bash Packaging/make-icns.sh [source.png]
#
# Output:
#   Packaging/AppIcon.icns                 copied into the .app by scripts/build.sh
#   Sources/mooterm/Resources/AppIcon.icns   SwiftPM resource, so `swift run`
#                                          shows the icon in the Dock too
set -euo pipefail
cd "$(dirname "$0")/.."
src="${1:-Resources/mooterm_logo.png}"
[[ -f "$src" ]] || { echo "missing: $src" >&2; exit 1; }

iconset="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size -s format png "$src" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) -s format png "$src" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$iconset" -o Packaging/AppIcon.icns
cp Packaging/AppIcon.icns Sources/mooterm/Resources/AppIcon.icns
rm -rf "$(dirname "$iconset")"
echo "Wrote Packaging/AppIcon.icns and Sources/mooterm/Resources/AppIcon.icns"
