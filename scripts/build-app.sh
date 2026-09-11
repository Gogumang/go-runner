#!/usr/bin/env bash
# Builds "build/go-runner.app" from the SwiftPM executable and signs it (local identity if present, else ad-hoc).
#   CONFIG=debug ./scripts/build-app.sh   (default: release)
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="build/go-runner.app"

swift build -c "$CONFIG" --product GoRunner
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/GoRunner" "$APP/Contents/MacOS/GoRunner"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Notification sounds per service (personal build: copies of macOS system sounds; replace before public distribution).
for pair in "claude:Glass" "codex:Hero" "slack:Pop"; do
  name="${pair%%:*}"
  src="/System/Library/Sounds/${pair##*:}.aiff"
  [ -f "$src" ] && cp "$src" "$APP/Contents/Resources/gorunner-$name.aiff"
done
# License texts ship inside the app (Contents/Resources), as Apache-2.0 requires LICENSE and NOTICE with copies.
for doc in LICENSE NOTICE THIRD_PARTY_NOTICES.md; do
  cp "$doc" "$APP/Contents/Resources/$doc"
done
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null 2>&1 || true
fi

# Sign with the stable local identity when it exists (keeps Accessibility grants across rebuilds),
# otherwise ad-hoc. Create the identity once with scripts/setup-signing.sh.
SIGN_ID="${GORUNNER_SIGN_IDENTITY:-go-runner Local}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1 \
   && codesign --force --sign "$SIGN_ID" --options runtime --timestamp=none "$APP" >/dev/null 2>&1; then
  echo "signed with: $SIGN_ID" >&2
else
  echo "note: signing identity '$SIGN_ID' unavailable; using an ad-hoc signature (run scripts/setup-signing.sh)" >&2
  codesign --force --sign - --options runtime --timestamp=none "$APP" >/dev/null
fi
echo "$APP"
