#!/bin/bash
# Checks the interface for real: clicks items, presses keys and drags items to the Desktop, in
# each of the four views, moves items between folders, then confirms the app did what it should.
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
SHOTS=/tmp/ui-shots
failures=0
mkdir -p "$SHOTS"

swiftc -O scripts/ui-poke.swift -o "$POKE" || exit 1
caffeinate -d -u -t 600 &
awake=$!
trap 'kill "$awake" 2>/dev/null || true' EXIT

# Key codes: return 36, space 49, left 123, right 124, down 125, Z 6.
scene=0
run_scene() {  # run_scene <view flag, or a --demo-... scene> <ui-poke steps...>
  local flag="$1"; shift
  : > "$LOG"
  if [[ "$flag" == --demo-* ]]; then
    "$BIN" "$flag" --light > "$LOG" 2>&1 &
  else
    "$BIN" --demo "$flag" --light > "$LOG" 2>&1 &
  fi
  local pid=$!
  sleep 6
  "$POKE" "$@"
  sleep 4
  # A picture of the screen at the end of each scene, to see what happened when a check fails.
  scene=$((scene + 1))
  screencapture -x "$SHOTS/scene-$scene${flag}.png" 2>/dev/null || true
  kill "$pid" 2>/dev/null
  wait "$pid" 2>/dev/null
  echo "--- $flag: what the app reported"
  cat "$LOG"
}

expect_log() {  # expect_log <description> <text>
  if grep -qF -- "$2" "$LOG"; then echo "PASS  $1"; else echo "FAIL  $1 (wanted: $2)"; failures=$((failures + 1)); fi
}

expect_no_log() {  # expect_no_log <description> <text>
  if grep -qF -- "$2" "$LOG"; then echo "FAIL  $1 (did not want: $2)"; failures=$((failures + 1)); else echo "PASS  $1"; fi
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

# Moving: the demo window's list rows sit at y 157 (808 Essentials), 181 (Beat Tape), 205 (Boom Bap
# Kit), 253 (Dusty Loop), 277 (Hat Closed), 301 (Kick), 349 (Snare) and 397 (Vinyl Breaks). The path
# bar's "Samples" is at (430, 616) and the sidebar's "SAMPLES SSD" drive at (138, 219).
echo "=== Moving in list view, undo and redo, the path bar, and a drop from Finder"
run_scene --view-list \
  drag 340 277 340 157 sleep 2 \
  cmdkey 6 sleep 2 \
  shiftcmdkey 6 sleep 2 \
  drag 340 253 430 616 sleep 2 \
  drag 1004 130 600 520 sleep 2
expect_log "dropping a file on a folder moves it there" "move: Hat Closed 03.aif -> 808 Essentials"
expect_log "Edit > Undo puts it back" "move: Hat Closed 03.aif -> Drum Kits (undo)"
expect_log "Edit > Redo moves it again" "move: Hat Closed 03.aif -> 808 Essentials (redo)"
expect_log "dropping on a folder in the path bar moves it there" "move: Dusty Loop 92bpm.wav -> Samples"
expect_log "a file dropped in from Finder is still copied to the MPC" "upload: "
expect_no_log "moving copies nothing to the Mac" "drag-out:"

echo "=== Moving a selection, and between drives"
run_scene --dark \
  drag 340 301 340 397 sleep 2 \
  drag 340 181 138 219 sleep 2
expect_log "dragging one of two selected files moves both" "move: Kick Deep 01.wav, Snare Crack.wav -> Vinyl Breaks"
expect_log "a move to another drive is explained, not attempted" "notice: Items can only be moved within one drive"
expect_no_log "moving copies nothing to the Mac" "drag-out:"

echo "=== Moving in icon view, and a name that is already taken"
run_scene --view-icons \
  drag 695 292 340 165 sleep 2 \
  drag 341 292 576 165 sleep 2 \
  key 36 sleep 1
expect_log "dropping an icon on a folder icon moves it" "move: Snare Crack.wav -> 808 Essentials"
expect_log "a name already in the folder is asked about" "move question: Hat Closed 03.aif in Boom Bap Kit"
expect_log "Return chooses Skip" "move answer: skip"
expect_no_log "Skip leaves the file where it is" "move: Hat Closed"

echo "=== The name-clash question on its own"
run_scene --demo-move-conflict \
  key 36 sleep 1 \
  click 510 300 sleep 0.5 \
  key 36 sleep 1
expect_log "Return chooses Skip when the question is the first thing on screen" "move answer: skip"

echo "=== Desktop"
ls -la "$HOME/Desktop"
if [ "$failures" -eq 0 ]; then echo "All interface checks passed."; else echo "$failures interface check(s) failed."; exit 1; fi
