#!/usr/bin/env bash
# Build, sign, and install the LogiLight settings app.
#
# The app is a thin AppKit front end: the launchd agent keeps the HID connection
# (and the Input Monitoring grant), and this window talks to it over a Unix
# socket. Building it needs only the Command Line Tools, not Xcode.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/LogiLight.app"
IDENTITY="LogiLight Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

echo "==> compiling the settings window"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O "$ROOT/gui/LogiLight.swift" \
	-o "$APP/Contents/MacOS/LogiLight" \
	-framework Cocoa

echo "==> rendering the icon"
ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
xcrun swiftc -O "$ROOT/scripts/make-icon.swift" -o "$BUILD/make-icon" -framework Cocoa
"$BUILD/make-icon" "$ICONSET"
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
	"128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
	"512 512x512" "1024 512x512@2x"; do
	set -- $spec
	sips -z "$1" "$1" "$ICONSET/icon_1024.png" --out "$ICONSET/icon_$2.png" >/dev/null
done
rm -f "$ICONSET/icon_1024.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> writing Info.plist"
cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.luhui.logilight.control</string>
  <key>CFBundleName</key><string>LogiLight</string>
  <key>CFBundleDisplayName</key><string>LogiLight</string>
  <key>CFBundleExecutable</key><string>LogiLight</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

echo "==> signing"
codesign --force --sign "$IDENTITY" --keychain "$KEYCHAIN" \
	--identifier com.luhui.logilight.control "$APP"
codesign --verify --strict "$APP"

DEST="/Applications"
if [ ! -w "$DEST" ]; then
	DEST="$HOME/Applications"
	mkdir -p "$DEST"
fi
echo "==> installing to $DEST/LogiLight.app"
rm -rf "$DEST/LogiLight.app"
cp -R "$APP" "$DEST/LogiLight.app"

echo "done. Open it from Launchpad, Spotlight, or: open \"$DEST/LogiLight.app\""
