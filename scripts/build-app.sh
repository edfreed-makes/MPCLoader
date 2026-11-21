#!/bin/bash
# Builds "MPC Loader.app" into dist/. Run on a Mac with Xcode or the Command Line Tools:
#
#   scripts/build-app.sh
#
# Set UNIVERSAL=1 to build for both Apple silicon and Intel (needs the full Xcode).
set -euo pipefail
cd "$(dirname "$0")/.."

APP="dist/MPC Loader.app"
ARCH_FLAGS=""
if [ "${UNIVERSAL:-0}" = 1 ]; then ARCH_FLAGS="--arch arm64 --arch x86_64"; fi

# shellcheck disable=SC2086
swift build -c release $ARCH_FLAGS
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c release $ARCH_FLAGS --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MPCLoader" "$APP/Contents/MacOS/MPCLoader"
cp Packaging/Info.plist "$APP/Contents/Info.plist"

# The icon: one 1024 pixel picture turned into every size macOS wants.
WORK="$(mktemp -d)"
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  sips -z "$((size * 2))" "$((size * 2))" Packaging/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$WORK"

# Signed for this Mac only ("ad hoc"). That is enough to run it locally.
codesign --force --sign - "$APP"

echo "Built $APP"
