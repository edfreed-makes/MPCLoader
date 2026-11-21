#!/bin/bash
# Checks the interface for real: clicks items, presses keys and drags items to the Desktop, in
# each of the four views, then confirms the app did what it should.
#
#   scripts/ui-check.sh
#
# It uses the demo scene, where every file is a generated tone, so no MPC or network is involved.
# It needs permission to control the computer (Privacy & Security > Accessibility), and it puts a
# few demo files on the Desktop. Written for the build machine's 1024 by 768 screen.
set -uo pipefail
cd "$(dirname "$0")/.."

BIN="dist/MPC Loader.app/Contents/MacOS/MPCLoader"
POKE=/tmp/ui-poke
LOG=/tmp/mpcloader-ui.log
failures=0

swiftc -O scripts/ui-poke.swift -o "$POKE" || exit 1
caffeinate -d -u -t 600 &
awake=$!
trap 'kill "$awake" 2>/dev/null || true' EXIT

# Key codes: space 49, left 123, right 124, down 125.
run_scene() {  # run_scene <view flag> <ui-poke steps...>
  local flag="$1"; shift
  : > "$LOG"
  "$BIN" --demo "$flag" --light > "$LOG" 2>&1 &
  local pid=$!
  sleep 6
  "$POKE" "$@"
  sleep 4
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "--- $flag: what the app reported"
  cat "$LOG"
}

expect_log() {  # expect_log <description> <text>
  if grep -qF -- "$2" "$LOG"; then echo "PASS  $1"; else echo "FAIL  $1 (wanted: $2)"; failures=$((failures + 1)); fi
}

expect_file() {  # expect_file <name on the Desktop>
  if [ -e "$HOME/Desktop/$1" ]; then echo "PASS  dragged out as \"$1\""; else echo "FAIL  nothing called \"$1\" on the Desktop"; failures=$((failures + 1)); fi
}

echo "=== List view"
run_scene --view-list \
  click 340 278 sleep 0.6 key 49 sleep 2 key 125 sleep 2 key 49 sleep 1 \
  drag 340 254 1004 130 sleep 3 \
  drag 340 278 1004 260 sleep 3 \
  drag 340 181 1004 390 sleep 3 \
  drag 340 232 1004 520 sleep 3 \
  drag 340 156 120 684
expect_log "space bar plays the selected file" "preview: playing Hat Closed 03.aif"
expect_log "arrow key moves the preview to the next file" "preview: playing Kick Deep 01.wav"
expect_log "space bar stops the preview" "preview: closed"
expect_file "Dusty Loop 92bpm.wav"
expect_file "Hat Closed 03.aif"
expect_file "Beat Tape 3.xpj"
expect_file "Boom Bap Kit.xpm"
expect_file "808 Essentials/Kick.wav"

echo "=== Icon view"
run_scene --view-icons \
  click 341 292 sleep 0.6 key 49 sleep 2 key 124 sleep 2 key 49 sleep 1 \
  drag 695 292 300 684
expect_log "clicking an icon and pressing space plays it" "preview: playing Hat Closed 03.aif"
expect_log "right arrow moves to the next icon" "preview: playing Kick Deep 01.wav"
expect_file "Snare Crack.wav"

echo "=== Column view"
run_scene --view-columns \
  click 580 244 sleep 0.6 key 49 sleep 2 key 125 sleep 2 key 49 sleep 1 \
  drag 580 388 480 684
expect_log "clicking a row and pressing space plays it" "preview: playing Hat Closed 03.aif"
expect_log "down arrow moves to the next row" "preview: playing Kick Deep 01.wav"
expect_file "Vocal Chop.mp3"

echo "=== Gallery view"
run_scene --view-gallery \
  click 783 545 sleep 0.6 key 49 sleep 2 key 123 sleep 2 key 49 sleep 1 \
  drag 901 545 660 684
expect_log "clicking a thumbnail and pressing space plays it" "preview: playing Hat Closed 03.aif"
expect_log "left arrow moves to the previous item" "preview: playing Dusty Loop 92bpm.wav"
expect_file "Rhodes Chords.flac"

echo "=== Desktop"
ls -la "$HOME/Desktop"
if [ "$failures" -eq 0 ]; then echo "All interface checks passed."; else echo "$failures interface check(s) failed."; exit 1; fi
