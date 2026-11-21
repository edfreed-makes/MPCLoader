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

# The icon. See icon/README.md.
#
# Every Mac reads the classic AppIcon.icns. macOS 26 and later can also show the layered
# AppIcon.icon, with its dark, clear and tinted looks, but only once Xcode 26 or later has
# compiled it. So the .icns always goes in, and the layered icon is added when this Mac's
# Xcode can compile it.
cp icon/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

compile_icon() {  # compile_icon [developer folder]: true when Assets.car was made
  rm -rf "$WORK/out"; mkdir -p "$WORK/out"
  local tool=(xcrun actool)
  [ -z "${1:-}" ] || tool=(env DEVELOPER_DIR="$1" xcrun actool)
  "${tool[@]}" --compile "$WORK/out" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon AppIcon --output-partial-info-plist "$WORK/out/partial.plist" \
    icon/AppIcon.icon > "$WORK/actool.log" 2>&1 && [ -f "$WORK/out/Assets.car" ]
}

# The selected Xcode first, then any other installed Xcode, newest first.
compiled=""
if compile_icon; then
  compiled="$(xcode-select -p 2>/dev/null || echo "the selected Xcode")"
else
  for xcode in $(ls -d /Applications/Xcode*.app 2>/dev/null | sort -rV); do
    if compile_icon "$xcode/Contents/Developer"; then compiled="$xcode"; break; fi
  done
fi
if [ -n "$compiled" ]; then
  cp "$WORK/out/Assets.car" "$APP/Contents/Resources/Assets.car"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconName string AppIcon" "$APP/Contents/Info.plist"
  echo "Icon: layered AppIcon.icon compiled with $compiled, plus AppIcon.icns for macOS 14 and 15."
else
  echo "Icon: AppIcon.icns only. No Xcode here can compile the layered AppIcon.icon (it needs Xcode 26 or later)."
  sed 's/^/  actool: /' "$WORK/actool.log" | head -n 8
fi

# Signed for this Mac only ("ad hoc"). That is enough to run it locally.
codesign --force --sign - "$APP"

echo "Built $APP"
