#!/bin/bash
# Builds "build/SampleBlaster Lite.app" and a DMG for macOS 10.13 High Sierra
# and later: Intel (10.13+) and Apple silicon (11+) in one app.
#
# Objective-C on purpose: it needs nothing beyond what High Sierra ships with
# (no Swift runtime to bundle), and the compiler refuses any API newer than
# 10.13 that isn't checked first.
#
#   ./make-app.sh                       ad-hoc signed (right-click ▸ Open the first time)
#   SIGN_IDENTITY="Developer ID Application: …" ./make-app.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SampleBlaster Lite"
EXEC="SampleBlasterLite"
APP="build/${APP_NAME}.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Packaging/Info.plist)"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
SOURCES=(Sources/main.m Sources/AppDelegate.m Sources/SBDisk.m Sources/SBTransfer.m)
FLAGS=(-fobjc-arc -O2 -Wall -Wextra -Wno-unused-parameter
       -Werror=unguarded-availability -Werror=unguarded-availability-new -Werror=objc-method-access
       -framework Cocoa -framework AVFoundation)

echo "▸ Building ${APP_NAME} ${VERSION}…"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" build/arch
xcrun clang -target x86_64-apple-macos10.13 "${FLAGS[@]}" "${SOURCES[@]}" -o build/arch/x86_64
xcrun clang -target arm64-apple-macos11.0 "${FLAGS[@]}" "${SOURCES[@]}" -o build/arch/arm64
lipo -create build/arch/x86_64 build/arch/arm64 -output "$APP/Contents/MacOS/$EXEC"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# Artwork: Artwork/AppIcon.png (1024×1024) and an optional Artwork/Header.png.
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
[[ -f Artwork/Header.png ]] && cp Artwork/Header.png "$APP/Contents/Resources/Header.png"

xattr -cr "$APP" 2>/dev/null || true
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --sign - "$APP"
else
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$APP"
fi
codesign --verify --strict "$APP"

echo "▸ Checking it's built for High Sierra…"
./Packaging/check-compat.sh "$APP/Contents/MacOS/$EXEC"

# HFS+ (not APFS) and zlib compression, so the DMG opens on old Macs too.
DMG="build/${APP_NAME} ${VERSION}.dmg"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGING"
echo "▸ Done: $APP and $DMG"
