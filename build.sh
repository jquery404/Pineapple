#!/bin/bash
# Builds Pineapple.app into ./build and signs it with a local certificate.
# Uses swiftc directly: SwiftPM needs full Xcode, the Command Line Tools are enough for this.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Pineapple.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O \
    -target "$(uname -m)-apple-macos13.0" \
    -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
    -o "$APP/Contents/MacOS/Pineapple" \
    Sources/Pineapple/*.swift

cp Info.plist "$APP/Contents/Info.plist"
# Local settings from .env (not committed), copied into the app's Info.plist.
if [ -f .env ]; then
    profile=$(grep -E '^AWS_PROFILE=' .env | tail -n 1 | cut -d= -f2- | tr -d "\"' \r")
    if [ -n "$profile" ]; then
        plutil -insert PineappleAWSProfile -string "$profile" "$APP/Contents/Info.plist"
    fi
fi
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"  # regenerate with tools/make_icon.sh
# Sign with a fixed local certificate so macOS keeps Screen Recording / Microphone
# permission across rebuilds (ad-hoc signatures change every build and reset it).
# Falls back to ad hoc if the certificate isn't in the keychain.
if security find-certificate -c "Pineapple Local Signing" >/dev/null 2>&1; then
    codesign --force --sign "Pineapple Local Signing" --identifier local.pineapple "$APP"
else
    echo "warning: 'Pineapple Local Signing' certificate not found, signing ad hoc (permissions reset each build)"
    codesign --force --sign - "$APP"
fi

echo "Built $(pwd)/$APP"
