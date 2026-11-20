#!/bin/bash
set -euo pipefail
project="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$project"
product="dist/截一屏.app"
mkdir -p .build/modules dist
bundle="$(mktemp -d "$project/.build/app.XXXXXXXX")"
trap 'rm -rf -- "$bundle"' EXIT
chmod 755 "$bundle"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp Resources/Info.plist "$bundle/Contents/Info.plist"
cp Resources/StatusItemTemplate*.png "$bundle/Contents/Resources/"
cp Resources/AppIcon.icns "$bundle/Contents/Resources/"
arch="${GRABONE_ARCH:-$(uname -m)}"
xcrun swiftc -parse-as-library -O -target "$arch-apple-macos15.0" \
    -module-cache-path .build/modules -module-name GrabOne \
    -o "$bundle/Contents/MacOS/GrabOne" Sources/*.swift
codesign --force --sign - "$bundle"
rm -rf -- "$product"
mv -- "$bundle" "$product"
printf '%s\n' "$project/$product"
