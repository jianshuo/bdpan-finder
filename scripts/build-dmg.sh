#!/bin/bash
#
# Build a signed, notarized, stapled 百度网盘.dmg for direct distribution.
#
# Produces dist/百度网盘.dmg containing 百度网盘.app with the bdpan CLI bundled
# inside it (users do not install bdpan separately; they log in on first launch).
#
# Requirements:
#   - Xcode + xcodegen
#   - A "Developer ID Application" certificate in the login keychain
#   - An App Store Connect API key (.p8) for notarization
#
# Credentials are read from the environment (never hard-coded):
#   SIGN_IDENTITY   Developer ID Application identity (name or SHA-1).
#                   Default: "Developer ID Application"
#   NOTARY_KEY      Path to the App Store Connect .p8 key file
#   NOTARY_KEY_ID   The key's Key ID
#   NOTARY_ISSUER   The App Store Connect Issuer ID
#
# If the NOTARY_* vars are unset, the script builds + signs + packages but skips
# notarization (the DMG will work locally but Gatekeeper will warn on other Macs).
#
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"
DERIVED="${DERIVED:-/tmp/bdpan-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
APP_NAME="百度网盘"

echo "==> Generating Xcode project"
xcodegen generate >/dev/null

echo "==> Building Release"
xcodebuild -project BdpanFinder.xcodeproj -scheme BdpanFinder \
  -configuration Release -derivedDataPath "$DERIVED" build >/dev/null
APP="$DERIVED/Build/Products/Release/BdpanFinder.app"

EXT_ENT="$ROOT/BdpanFinderExt/BdpanFinderExt.entitlements"
APP_ENT="$ROOT/BdpanFinder/BdpanFinder.entitlements"
APPEX="$APP/Contents/PlugIns/BdpanFinderExt.appex"

echo "==> Signing bundled bdpan binaries (hardened runtime)"
for b in "$APP/Contents/Resources/bdpan" "$APPEX/Contents/Resources/bdpan"; do
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$b"
done

echo "==> Re-signing extension, then app (inside-out)"
codesign --force --options runtime --timestamp \
  --entitlements "$EXT_ENT" --sign "$SIGN_IDENTITY" "$APPEX"
codesign --force --options runtime --timestamp \
  --entitlements "$APP_ENT" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"

notarize() { # $1 = file to notarize
  if [ -z "${NOTARY_KEY:-}" ] || [ -z "${NOTARY_KEY_ID:-}" ] || [ -z "${NOTARY_ISSUER:-}" ]; then
    echo "   (NOTARY_* not set — skipping notarization of $1)"
    return 1
  fi
  xcrun notarytool submit "$1" \
    --key "$NOTARY_KEY" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER" --wait
}

echo "==> Notarizing the app"
APP_ZIP="$DERIVED/百度网盘.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
if notarize "$APP_ZIP"; then
  xcrun stapler staple "$APP"
  echo "   app stapled"
fi

echo "==> Packaging DMG"
mkdir -p "$ROOT/dist"
STAGE="$(mktemp -d)"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
DMG="$ROOT/dist/$APP_NAME.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGE"

echo "==> Notarizing the DMG"
if notarize "$DMG"; then
  xcrun stapler staple "$DMG"
  echo "   DMG stapled"
fi

echo ""
echo "Done: $DMG"
ls -lh "$DMG" | awk '{print "  size:", $5}'
