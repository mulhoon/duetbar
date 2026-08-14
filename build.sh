#!/bin/bash
# Builds Duetbar.app. No Xcode project, just swiftc and a bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Duetbar.app"
BIN="$APP/Contents/MacOS/Duetbar"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Duetbar</string>
  <key>CFBundleDisplayName</key><string>Duetbar</string>
  <key>CFBundleIdentifier</key><string>com.duetbar.app</string>
  <key>CFBundleExecutable</key><string>Duetbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <!-- Menu bar only, no Dock icon and no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

swiftc -O \
  -target arm64-apple-macos13.0 \
  -framework SwiftUI -framework AppKit \
  -o "$BIN" \
  Sources/GlueClient.swift Sources/Meters.swift Sources/HotKeys.swift Sources/DuetbarApp.swift

codesign --force --deep --sign - "$APP" 2>/dev/null || true

echo "built $APP"
