#!/bin/bash
# Build a universal (arm64 + x86_64) mooTerm.app and package it for a
# GitHub release. Works with just the Command Line Tools: SwiftPM builds
# each slice with --arch and lipo merges them.
#
# Usage: bash scripts/release.sh 0.2.0
#
# Output (dist/ is git-ignored):
#   dist/mooTerm.app                 universal app bundle, ad-hoc signed
#   dist/mooTerm-<version>.zip       zip of the app
#   dist/mooTerm-<version>.dmg       drag-to-Applications disk image
#   dist/SHA256SUMS.txt              checksums of the zip and dmg
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:?usage: release.sh <version, e.g. 0.2.0>}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 1; }

[[ -f Packaging/AppIcon.icns ]] || bash Packaging/make-icns.sh

echo "==> Building arm64 and x86_64"
swift build -c release --arch arm64
swift build -c release --arch x86_64
arm_dir=".build/arm64-apple-macosx/release"
x86_dir=".build/x86_64-apple-macosx/release"

rm -rf dist
mkdir -p dist
app="$PWD/dist/mooTerm.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"

lipo -create -output "$app/Contents/MacOS/mooterm" "$arm_dir/mooterm" "$x86_dir/mooterm"
lipo -info "$app/Contents/MacOS/mooterm"

# Info.plist with this release's version; build number = commit count.
cp Packaging/mooTerm.app/Contents/Info.plist "$app/Contents/Info.plist"
build_number="$(git rev-list --count HEAD)"
plutil -replace CFBundleShortVersionString -string "$version" "$app/Contents/Info.plist"
plutil -replace CFBundleVersion -string "$build_number" "$app/Contents/Info.plist"

cp Packaging/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
# Resource bundles are architecture-independent; take them from arm64.
for bundle in "$arm_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    cp -R "$bundle" "$app/Contents/Resources/"
done
[[ -f .build/checkouts/SwiftTerm/LICENSE ]] && cp .build/checkouts/SwiftTerm/LICENSE "$app/Contents/Resources/SwiftTerm-LICENSE.txt"

# Ad-hoc signature: runs locally; not Developer ID signed or notarized.
codesign --force --deep --sign - "$app"
codesign --verify --deep --strict "$app"

zip="dist/mooTerm-$version.zip"
dmg="dist/mooTerm-$version.dmg"
ditto -c -k --keepParent "$app" "$zip"

staging="$(mktemp -d)"
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
hdiutil create -volname "mooTerm $version" -srcfolder "$staging" -ov -format UDZO "$dmg" >/dev/null
rm -rf "$staging"

(cd dist && shasum -a 256 "mooTerm-$version.zip" "mooTerm-$version.dmg" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt
echo "Built: $app ($version, build $build_number)"
