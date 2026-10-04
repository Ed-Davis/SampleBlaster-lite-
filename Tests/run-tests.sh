#!/bin/bash
# Builds and runs the tests (needs a Mac: they mount a real disk image).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun clang -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
  -Werror=unguarded-availability -Werror=unguarded-availability-new \
  -target "$(uname -m)-apple-macos11.0" \
  Tests/run-tests.m Sources/SBDisk.m Sources/SBTransfer.m \
  -framework Foundation -framework AVFoundation -o build/run-tests
./build/run-tests
