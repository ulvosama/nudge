#!/bin/sh
# Build, sign, notarize and publish a release.
#
#   NUDGE_SIGN_ID="Developer ID Application: Your Name (TEAMID)" scripts/release.sh 1.0.0
#
# One-time setup: a Developer ID Application certificate in your keychain, and notary credentials:
#   xcrun notarytool store-credentials nudge-notary --apple-id <you> --team-id <TEAMID>
# Set NUDGE_NO_PUBLISH=1 to stop before creating the GitHub release.
set -eu
cd "$(dirname "$0")/.."
V="${1:?usage: scripts/release.sh <version>}"
PROFILE="${NUDGE_NOTARY_PROFILE:-nudge-notary}"
: "${NUDGE_SIGN_ID:?set NUDGE_SIGN_ID to your Developer ID Application identity}"
[ -z "$(git status --porcelain)" ] || { echo "Commit your changes first."; exit 1; }

echo "$V" > VERSION
git diff --quiet VERSION || { git commit -qm "Version $V" VERSION; }

./tests/run.sh
NUDGE_RELEASE=1 ./build.sh
APP=build/Nudge.app
codesign --verify --strict --deep "$APP"
lipo -info "$APP/Contents/MacOS/Nudge"

# Notarize the app (zip), staple, then build the styled DMG and notarize that too.
OUT=dist/release; rm -rf "$OUT"; mkdir -p "$OUT"
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
xcrun notarytool submit "$OUT/notarize.zip" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$APP"
rm "$OUT/notarize.zip"
ditto -c -k --keepParent "$APP" "$OUT/Nudge-$V.zip"

STAGE="$(mktemp -d)"; cp -R "$APP" "$STAGE/"; ln -s /Applications "$STAGE/Applications"
if [ -f docs/dmg-background.tiff ]; then mkdir "$STAGE/.background"; cp docs/dmg-background.tiff "$STAGE/.background/bg.tiff"; fi
RW="$OUT/rw.dmg"
hdiutil create -volname Nudge -fs HFS+ -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
DEV=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk '/Apple_HFS/ {print $1}')
if [ -f docs/dmg-background.tiff ]; then
  # Window layout: needs Finder automation permission the first time.
  osascript <<OSA || echo "(Finder layout skipped)"
tell application "Finder"
  tell disk "Nudge"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 520}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Nudge.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    close
  end tell
end tell
OSA
fi
sync; hdiutil detach "$DEV" >/dev/null
hdiutil convert "$RW" -format UDZO -o "$OUT/Nudge-$V.dmg" >/dev/null; rm -f "$RW"; rm -rf "$STAGE"
codesign --force --sign "$NUDGE_SIGN_ID" --timestamp "$OUT/Nudge-$V.dmg"
xcrun notarytool submit "$OUT/Nudge-$V.dmg" --keychain-profile "$PROFILE" --wait
xcrun stapler staple "$OUT/Nudge-$V.dmg"
spctl -a -t open --context context:primary-signature -vv "$OUT/Nudge-$V.dmg"
spctl -a -t exec -vv "$APP"

(cd "$OUT" && shasum -a 256 "Nudge-$V.dmg" "Nudge-$V.zip" > SHA256SUMS && cat SHA256SUMS)

[ -n "${NUDGE_NO_PUBLISH:-}" ] && { echo "Built $OUT (not published)."; exit 0; }
git tag -a "v$V" -m "Nudge $V" && git push origin main "v$V"
NOTES="$(awk -v v="## $V" '$0==v{f=1;next} /^## /{f=0} f' CHANGELOG.md)"
gh release create "v$V" "$OUT/Nudge-$V.dmg" "$OUT/Nudge-$V.zip" "$OUT/SHA256SUMS" \
  --title "Nudge $V" --notes "${NOTES:-Nudge $V}"
echo "Released v$V"
