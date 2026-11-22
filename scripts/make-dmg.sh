#!/bin/bash
# Makes a disk image of the app, with a shortcut to Applications to drag it onto.
#
#   scripts/make-dmg.sh "dist/MPC Loader.app" dist/MPC-Loader.dmg
set -euo pipefail

APP="$1"
DMG="$2"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

ditto "$APP" "$STAGE/$(basename "$APP")"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
# hdiutil now and then finds the disk busy on a build machine. A second go usually works.
for attempt in 1 2 3; do
  if hdiutil create -volname "MPC Loader" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null; then
    echo "Made $DMG"
    exit 0
  fi
  echo "hdiutil failed (attempt $attempt), trying again." >&2
  sleep 5
done
exit 1
