#!/bin/bash
# Builds Naqla.app and installs it to the Desktop.
set -e

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Desktop/Naqla.app"

cd "$SRC_DIR"
swiftc -O main.swift -o Naqla

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp Info.plist "$APP/Contents/Info.plist"
cp Naqla "$APP/Contents/MacOS/Naqla"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp CoreIcon.png "$APP/Contents/Resources/CoreIcon.png"

# Signed with a stable local identity (not ad-hoc) so Accessibility and
# Login Item grants survive rebuilds instead of resetting every time.
codesign --force --sign "Omar Local Code Signing" --timestamp=none "$APP"

echo "built $APP"
