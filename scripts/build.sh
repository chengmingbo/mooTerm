#!/bin/bash
# Build mooterm and assemble Packaging/mooTerm.app.
#
# Usage: bash scripts/build.sh [--install]
#   --install   also replace /Applications/mooTerm.app
#
# Always re-registers the bundle with LaunchServices: if an .app was ever
# registered without an icon, Finder/Dock keep showing the generic icon
# until the bundle's mtime changes and it is re-registered.
set -euo pipefail
cd "$(dirname "$0")/.."

install=false
[[ "${1:-}" == "--install" ]] && install=true

[[ -f Packaging/AppIcon.icns ]] || bash Packaging/make-icns.sh

echo "==> Building release"
swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="$PWD/Packaging/mooTerm.app"
rm -rf "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/_CodeSignature"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/mooterm" "$app/Contents/MacOS/mooterm"
cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# SwiftPM resource bundles belong in Contents/Resources — codesign rejects
# non-Mach-O files under Contents/MacOS.
for bundle in "$bin_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
done

codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

lsregister=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
refresh() { touch "$1"; "$lsregister" -f "$1"; }
refresh "$app"
echo "Built: $app"

if $install; then
    dest=/Applications/mooTerm.app
    rm -rf "$dest"
    # The app used to be called mTerm; don't leave the old copy behind.
    legacy=/Applications/mterm.app
    if [[ -d "$legacy" ]]; then
        "$lsregister" -u "$legacy" 2>/dev/null || true
        rm -rf "$legacy"
        echo "Removed old $legacy"
    fi
    ditto "$app" "$dest"
    refresh "$dest"
    killall Dock 2>/dev/null || true
    echo "Installed: $dest"
fi
