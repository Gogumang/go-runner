#!/usr/bin/env bash
# Builds go-runner into a private scratch path, launches it, and captures the menu bar and the status menu.
# Output: "build/lead/go-runner.app", build/lead/menubar.png, build/lead/menu.png
#   SCRATCH=.build-lead ./scripts/run-and-capture.sh
set -uo pipefail
cd "$(dirname "$0")/.."

SCRATCH="${SCRATCH:-.build-lead}"
OUT=build/lead
APP="$OUT/go-runner.app"
mkdir -p "$OUT"

echo "== build =="
if ! swift build -c release --product GoRunner --scratch-path "$SCRATCH" > "$OUT/build.log" 2>&1; then
  echo "BUILD FAILED"
  grep -m10 "error:" "$OUT/build.log"
  exit 1
fi
BIN="$(swift build -c release --scratch-path "$SCRATCH" --show-bin-path)/GoRunner"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/GoRunner"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null 2>&1
echo "bundle: $APP"

echo "== launch =="
pkill -x GoRunner 2>/dev/null
sleep 1
open "$APP"
sleep 4
if ! pgrep -x GoRunner >/dev/null; then
  echo "NOT RUNNING — recent log:"
  log show --last 1m --predicate 'process == "GoRunner"' --style compact 2>/dev/null | tail -15
  exit 1
fi
echo "running: pid $(pgrep -x GoRunner)"
log show --last 1m --predicate 'subsystem == "dev.gorunner.GoRunner"' --style compact 2>/dev/null | grep -iE "error|fault" | tail -5

echo "== menu bar =="
items=$(osascript -e 'tell application "System Events" to tell process "GoRunner" to get {position, size} of menu bar item 1 of menu bar 1' 2>&1)
echo "status item: $items"
IFS=', ' read -r IX IY IW IH <<< "$items"
if [ "${IW:-0}" -gt 0 ] 2>/dev/null; then
  screencapture -x -R "$((IX-80)),0,$((IW+160)),34" "$OUT/menubar.png" && echo "captured $OUT/menubar.png"
else
  echo "status item not found (hidden by notch/menu bar overflow?)"
fi

echo "== status menu =="
osascript -e 'tell application "System Events" to tell process "GoRunner" to click menu bar item 1 of menu bar 1' >/dev/null 2>&1
sleep 1.5
geo=$(osascript -e 'tell application "System Events" to tell process "GoRunner" to get {position, size} of menu 1 of menu bar item 1 of menu bar 1' 2>&1)
echo "menu: $geo"
IFS=', ' read -r X Y W H <<< "$geo"
if [ "${W:-0}" -gt 0 ] 2>/dev/null; then
  screencapture -x -R "$((X-4)),$((Y-4)),$((W+8)),$((H+8))" "$OUT/menu.png" && echo "captured $OUT/menu.png"
else
  echo "menu not found"
fi
osascript -e 'tell application "System Events" to key code 53' >/dev/null 2>&1
exit 0
