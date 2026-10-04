#!/bin/bash
# Builds "build/SampleBlaster Lite.app" and a DMG for macOS 10.13 High Sierra
# and later: Intel (10.13+) and Apple silicon (11+) in one app.
#
# Objective-C on purpose: it needs nothing beyond what High Sierra ships with
# (no Swift runtime to bundle), and the compiler refuses any API newer than
# 10.13 that isn't checked first.
#
#   ./make-app.sh                       ad-hoc signed (for testing on this Mac)
#   SIGN_IDENTITY="Developer ID Application: …" ./make-app.sh
#                                       signed with your Developer ID
# To notarise as well (so it opens normally on every Mac), add one of:
#   NOTARY_PROFILE=<name>               a profile saved with `xcrun notarytool store-credentials`
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER   an App Store Connect API key
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SampleBlaster Lite"
EXEC="SampleBlasterLite"
APP="build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
# The build number counts commits, so every build from a new commit is distinct.
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SOURCES=(Sources/main.m Sources/AppDelegate.m Sources/SBDisk.m Sources/SBTransfer.m)
FLAGS=(-fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
       -Werror=unguarded-availability -Werror=unguarded-availability-new -Werror=objc-method-access
       -framework Cocoa)

echo "▸ Building ${APP_NAME} ${VERSION} beta (build ${BUILD})…"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arch
xcrun clang -target x86_64-apple-macos10.13 "${FLAGS[@]}" "${SOURCES[@]}" -o build/arch/x86_64
xcrun clang -target arm64-apple-macos11.0 "${FLAGS[@]}" "${SOURCES[@]}" -o build/arch/arm64
lipo -create build/arch/x86_64 build/arch/arm64 -output "$APP/Contents/MacOS/$EXEC"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${BUILD}" "$APP/Contents/Info.plist"

# Artwork: Artwork/AppIcon.png (square), Artwork/Splash.png (shown at launch,
# with the copyright, version and build drawn over it), and an optional
# Artwork/Header.png across the top of the window.
if [[ -f Artwork/AppIcon.png ]]; then
  ICONSET="$(mktemp -d)/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z $size $size Artwork/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size*2)) $((size*2)) Artwork/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
else
  echo "  (no Artwork/AppIcon.png yet: using the generic app icon)"
fi
if [[ -f Artwork/Splash.png ]]; then
  # Shown 640 points wide: keep a 2× copy, not the full-size original.
  sips -Z 1344 Artwork/Splash.png --out "$APP/Contents/Resources/Splash.png" >/dev/null
fi
if [[ -f Artwork/Header.png ]]; then cp Artwork/Header.png "$APP/Contents/Resources/Header.png"; fi

xattr -cr "$APP" 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  echo "▸ Signing ad hoc (not for distribution)…"
  codesign --force --sign - "$APP"
else
  echo "▸ Signing with ${SIGN_IDENTITY}…"
  # Hardened runtime and a secure timestamp: both needed for notarisation.
  # High Sierra ignores the runtime flag and checks the Developer ID signature.
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

echo "▸ Checking it's built for High Sierra…"
./Packaging/check-compat.sh "$APP/Contents/MacOS/$EXEC"

# HFS+ (not APFS) and zlib compression, so the DMG opens on old Macs too.
DMG="build/${APP_NAME} ${VERSION} beta (build ${BUILD}).dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"

if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  NOTARY_ARGS=()
  if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
  elif [[ -n "${NOTARY_KEY_PATH:-}" ]]; then
    NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "${NOTARY_KEY_ID:?Set NOTARY_KEY_ID}" --issuer "${NOTARY_ISSUER:?Set NOTARY_ISSUER}")
  fi
  if [[ ${#NOTARY_ARGS[@]} -gt 0 ]]; then
    echo "▸ Notarising (usually a few minutes)…"
    OUT="$(xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
    echo "$OUT"
    if ! grep -q "status: Accepted" <<<"$OUT"; then
      ID="$(awk '/^  id:/{print $2; exit}' <<<"$OUT")"
      [[ -n "$ID" ]] && xcrun notarytool log "$ID" "${NOTARY_ARGS[@]}" || true
      echo "✗ Notarisation failed."; exit 1
    fi
    xcrun stapler staple "$APP"
    # Rebuild the DMG around the stapled app, then sign, notarise and staple it too.
    STAGING="$(mktemp -d)"
    cp -R "$APP" "$STAGING/"
    ln -s /Applications "$STAGING/Applications"
    hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
    rm -rf "$STAGING"
    codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
    OUT="$(xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait 2>&1)" || true
    echo "$OUT"
    grep -q "status: Accepted" <<<"$OUT" || { echo "✗ Notarising the DMG failed."; exit 1; }
    xcrun stapler staple "$DMG"
    spctl --assess --type execute -vv "$APP"
    spctl --assess --type open --context context:primary-signature -vv "$DMG"
    echo "✓ Signed, notarised and stapled."
  else
    echo "  (signed but not notarised: set NOTARY_PROFILE or the NOTARY_KEY_* variables to notarise)"
  fi
fi
echo "▸ Done: $APP and $DMG"
