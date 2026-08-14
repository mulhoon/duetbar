#!/bin/bash
# Builds a Developer ID signed, notarised, stapled Duetbar.app and zips it for
# a GitHub release.
#
#   scripts/release.sh 0.1.0
#
# Needs a "Developer ID Application" certificate in the keychain, and notarytool
# credentials stored as a keychain profile. To create that profile once:
#
#   xcrun notarytool store-credentials "notarytool-password" \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Override the identity or profile with SIGN_IDENTITY / NOTARY_PROFILE.
set -euo pipefail

VERSION="${1:?Usage: scripts/release.sh <version>   e.g. scripts/release.sh 0.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NOTARY_PROFILE="${NOTARY_PROFILE:-notarytool-password}"
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"

if [ -z "$SIGN_IDENTITY" ]; then
  echo "No Developer ID Application certificate found in the keychain." >&2
  exit 1
fi
echo "==> Signing as: $SIGN_IDENTITY"

DIST="$ROOT/dist"
APP="$ROOT/Duetbar.app"
ZIP="$DIST/Duetbar-$VERSION.zip"

rm -rf "$DIST"
mkdir -p "$DIST"

echo "==> Building $VERSION"
VERSION="$VERSION" SIGN_IDENTITY="$SIGN_IDENTITY" ./build.sh

# Notarisation takes a zip (or dmg/pkg); ditto is the only zip tool that
# preserves the bundle's symlinks and extended attributes intact.
echo "==> Submitting to Apple (usually a couple of minutes)"
ditto -c -k --keepParent "$APP" "$DIST/submit.zip"
xcrun notarytool submit "$DIST/submit.zip" --keychain-profile "$NOTARY_PROFILE" --wait
rm "$DIST/submit.zip"

# Staple the ticket into the app itself, so first launch works with no network,
# then zip the stapled copy. That is the file people download.
echo "==> Stapling"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Verifying"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

echo
echo "Ready: $ZIP"
ls -lh "$ZIP" | awk '{print "  size: "$5}'
echo "  arch: $(lipo -archs "$APP/Contents/MacOS/Duetbar")"
echo
echo "Publish with:"
echo "  gh release create v$VERSION \"$ZIP\" --title v$VERSION --generate-notes"
