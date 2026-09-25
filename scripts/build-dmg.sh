#!/usr/bin/env bash
# Packages build/go-runner.app into a distributable disk image: build/go-runner-<version>.dmg
#   ./scripts/build-dmg.sh
#
# Gatekeeper: a locally built app is ad-hoc signed, so on someone else's Mac macOS refuses to open it
# ("go-runner이(가) 손상되었습니다"). That is expected and is not a fault in the image. To hand the DMG to
# other people it has to be signed with a Developer ID Application certificate and notarized:
#
#   xcrun notarytool store-credentials go-runner --apple-id <id> --team-id <team> --password <app-specific>
#   GORUNNER_SIGN_IDENTITY="Developer ID Application: ..." GORUNNER_NOTARY_PROFILE=go-runner ./scripts/build-dmg.sh
#
# Without GORUNNER_NOTARY_PROFILE the image is still produced, just not notarized — fine for your own machines,
# where a right-click → Open (once) is enough.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/go-runner.app"
VOLUME_NAME="go-runner"

CONFIG="${CONFIG:-release}" ./scripts/build-app.sh >/dev/null

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")"
DMG="build/go-runner-$VERSION.dmg"

# Staged in a temp directory so the image contains exactly the app plus the drag-to-install shortcut.
STAGE="$(mktemp -d)"
trap '/bin/rm -r -f "$STAGE"' EXIT

cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cp LICENSE "$STAGE/LICENSE.txt"

[ -f "$DMG" ] && /bin/rm -f "$DMG"
hdiutil create \
  -volname "$VOLUME_NAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -quiet \
  "$DMG"

# Signing the image itself is what lets notarization staple a ticket to it.
SIGN_ID="${GORUNNER_SIGN_IDENTITY:-go-runner Local}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" "$DMG" >/dev/null
  echo "dmg signed with: $SIGN_ID" >&2
else
  echo "note: '$SIGN_ID' unavailable; the image is unsigned and other Macs will refuse to open the app" >&2
fi

if [ -n "${GORUNNER_NOTARY_PROFILE:-}" ]; then
  echo "submitting to notarization (this takes a few minutes)..." >&2
  xcrun notarytool submit "$DMG" --keychain-profile "$GORUNNER_NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "notarized and stapled" >&2
fi

echo "$DMG"
