#!/bin/bash
# Starts the built app in each demo scene and photographs its window.
#
#   scripts/take-screenshots.sh <output folder>
#
# Demo scenes show sample content and never touch the network, so this is safe to run anywhere.
# It also serves as a start-up check: it fails if the app exits in any scene.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-shots}"
BIN="dist/MPC Loader.app/Contents/MacOS/MPCLoader"
mkdir -p "$OUT"

# Keep the display awake: a sleeping display photographs as a black rectangle.
caffeinate -d -u -t 900 &
awake=$!
trap 'kill "$awake" 2>/dev/null || true' EXIT

shoot() {
  name="$1"; shift
  "$BIN" "$@" &
  pid=$!
  sleep 7
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "The app exited during start-up ($name)." >&2
    exit 1
  fi
  # A demo scene places its window 40 points in and 60 points down, at 940 by 600.
  screencapture -x -R 40,60,940,600 "$OUT/$name.png" || echo "No screenshot for $name."
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}

shoot view-icons --demo --view-icons --light
shoot view-columns --demo --view-columns --light
shoot view-gallery --demo --view-gallery --light
shoot browser-light --demo --light
shoot browser-dark --demo --dark
shoot preview --demo-preview --light
shoot report --demo-report --light
shoot conflict --demo-conflict --light
shoot connect --demo-connect --light
shoot developer-mode-off --demo-refused --light
# The app's icon, as Finder and the Dock show it.
swiftc -O scripts/render-icon.swift -o /tmp/render-icon && /tmp/render-icon "dist/MPC Loader.app" "$OUT/app-icon.png"
ls -l "$OUT"
