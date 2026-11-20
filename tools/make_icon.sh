#!/bin/bash
# Regenerates Resources/AppIcon.icns from the artwork in Sources/Pineapple/PineappleIcon.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TMP=$(mktemp -d)
swiftc -target "$(uname -m)-apple-macos13.0" -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "$TMP/make_icon" tools/make_icon/main.swift Sources/Pineapple/PineappleIcon.swift
"$TMP/make_icon" "$TMP/AppIcon.iconset"
mkdir -p Resources
iconutil -c icns -o Resources/AppIcon.icns "$TMP/AppIcon.iconset"
cp "$TMP/AppIcon.iconset/icon_512x512@2x.png" Resources/AppIcon-preview.png
rm -rf "$TMP"
echo "Wrote Resources/AppIcon.icns"
