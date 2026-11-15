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

scripts/make-dmg.sh "$APP" "$OUT/Nudge-$V.dmg" "$NUDGE_SIGN_ID"
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
