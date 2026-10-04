#!/bin/bash
# Checks a built binary will load on macOS 10.13 High Sierra:
#  - the Intel slice says it needs macOS 10.13 (not anything newer)
#  - it links only to libraries every High Sierra Mac has (no bundled Swift
#    runtime, no @rpath libraries)
set -euo pipefail
BIN="$1"

ARCHS="$(lipo -archs "$BIN")"
echo "  Architectures: $ARCHS"
[[ "$ARCHS" == *x86_64* ]] || { echo "✗ No Intel slice: High Sierra Macs are Intel."; exit 1; }

LOADS="$(otool -arch x86_64 -l "$BIN")"
MINOS="$(awk '/LC_VERSION_MIN_MACOSX/{f=1} f&&/version/{print $2; exit}' <<<"$LOADS")"
if [[ -z "$MINOS" ]]; then
  MINOS="$(awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}' <<<"$LOADS")"
fi
echo "  Intel minimum macOS: ${MINOS:-unknown}"
[[ "$MINOS" == "10.13" ]] || { echo "✗ Expected the Intel slice to need macOS 10.13, got '${MINOS}'."; exit 1; }

BAD=0
while read -r lib; do
  case "$lib" in
    /System/Library/Frameworks/*|/usr/lib/libobjc.A.dylib|/usr/lib/libSystem.B.dylib) echo "  links $lib" ;;
    *) echo "✗ Links something High Sierra may not have: $lib"; BAD=1 ;;
  esac
done < <(otool -arch x86_64 -L "$BIN" | tail -n +2 | awk '{print $1}')
[[ "$BAD" == 0 ]] || exit 1

echo "✓ Built for macOS 10.13 High Sierra and later."
