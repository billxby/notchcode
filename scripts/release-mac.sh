#!/bin/bash
# Build, sign, notarize, and publish Notchcode as a DMG on GitHub Releases.
#
# One-time prerequisites:
#   1. Developer ID Application certificate in your keychain
#      (Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Application)
#   2. Notarization credentials stored:
#      xcrun notarytool store-credentials notary \
#        --apple-id <apple-id> --team-id WYV3VT9WSC --password <app-specific-password>
#   3. gh auth login
#
# Usage: ./scripts/release-mac.sh <version>   e.g. ./scripts/release-mac.sh 1.0.0
set -euo pipefail

VERSION="${1:?usage: $0 <version>  e.g. $0 1.0.0}"
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$REPO_ROOT/mac/Notchcode/Notchcode.xcodeproj"
SCHEME="Notchcode"
APP_NAME="Notchcode"
BUILD_DIR="$REPO_ROOT/build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
NOTARY_PROFILE="notary"

rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

echo "==> Archiving (Release)"
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  | tail -5

echo "==> Exporting with Developer ID signing"
xcodebuild -exportArchive \
  -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$REPO_ROOT/mac/Notchcode/ExportOptions.plist" \
  | tail -5

APP="$EXPORT_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$APP"
echo "==> Signature OK: $(codesign -dv "$APP" 2>&1 | grep '^Authority' | head -1)"

echo "==> Creating DMG"
create-dmg \
  --volname "$APP_NAME" \
  --window-size 540 380 \
  --icon-size 128 \
  --icon "$APP_NAME.app" 140 180 \
  --app-drop-link 400 180 \
  --hide-extension "$APP_NAME.app" \
  "$DMG" \
  "$APP"

echo "==> Signing DMG"
codesign --sign "Developer ID Application: 15636345 Canada Inc. (WYV3VT9WSC)" "$DMG"

echo "==> Notarizing (this can take a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling notarization ticket"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

echo "==> Publishing GitHub release v$VERSION"
if gh release view "v$VERSION" --repo billxby/notchcode >/dev/null 2>&1; then
  gh release upload "v$VERSION" "$DMG" --clobber --repo billxby/notchcode
else
  gh release create "v$VERSION" "$DMG" \
    --repo billxby/notchcode \
    --title "Notchcode v$VERSION" \
    --generate-notes
fi

echo ""
echo "Done! Release: https://github.com/billxby/notchcode/releases/tag/v$VERSION"
