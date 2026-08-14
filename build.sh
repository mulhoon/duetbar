#!/bin/bash
# Builds Duetbar.app. No Xcode project, just swiftc and a bundle.
#
#   ./build.sh                        universal, ad-hoc signed, for local use
#   VERSION=0.2.0 ./build.sh          set the version in the bundle
#   SIGN_IDENTITY="Developer ID Application: ..." ./build.sh
#
# scripts/release.sh drives this with a real identity, then notarises.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-0.1.0}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"   # "-" is ad-hoc

APP="Duetbar.app"
BIN="$APP/Contents/MacOS/Duetbar"
SOURCES=(Sources/GlueClient.swift Sources/Meters.swift Sources/HotKeys.swift Sources/DuetbarApp.swift)

rm -rf "$APP" build/arch
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arch

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Duetbar</string>
  <key>CFBundleDisplayName</key><string>Duetbar</string>
  <key>CFBundleIdentifier</key><string>com.duetbar.app</string>
  <key>CFBundleExecutable</key><string>Duetbar</string>
  <key>CFBundleIconFile</key><string>Duetbar</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSMinimumSystemVersion</key><string>13.0</string>
  <key>NSHumanReadableCopyright</key><string>MIT licence. Not affiliated with Apogee Electronics.</string>
  <!-- Menu bar only, no Dock icon and no main window. -->
  <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST

cp Resources/Duetbar.icns "$APP/Contents/Resources/Duetbar.icns"

# Universal, so the release runs on Intel Macs too.
for arch in arm64 x86_64; do
  echo "compiling $arch"
  swiftc -O \
    -target "$arch-apple-macos13.0" \
    -framework SwiftUI -framework AppKit \
    -o "build/arch/Duetbar-$arch" \
    "${SOURCES[@]}"
done
lipo -create build/arch/Duetbar-arm64 build/arch/Duetbar-x86_64 -output "$BIN"
rm -rf build/arch

# Hardened runtime always, so a local build fails the same way a release would.
# The secure timestamp needs a real identity and a network round trip, so it is
# only added when signing for real.
SIGN_FLAGS=(--force --options runtime --sign "$SIGN_IDENTITY")
[ "$SIGN_IDENTITY" = "-" ] || SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "built $APP ($VERSION, $(lipo -archs "$BIN"))"
