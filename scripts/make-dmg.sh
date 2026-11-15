#!/bin/sh
# Wrap an app in the styled installer DMG (dark background, app -> Applications), optionally signed.
#
#   scripts/make-dmg.sh build/Nudge.app dist/Nudge.dmg ["Developer ID Application: …"]
#
# The Finder layout needs automation permission for Finder the first time; without it the DMG
# still works, just unstyled. Notarizing is release.sh's job.
set -eu
cd "$(dirname "$0")/.."
APP="${1:?usage: scripts/make-dmg.sh <app> <out.dmg> [sign-id]}"; OUTDMG="${2:?out.dmg}"; SIGN="${3:-}"
BG=docs/dmg-background.tiff

STAGE="$(mktemp -d)"; RW="$(mktemp -d)/rw.dmg"
trap 'rm -rf "$STAGE" "$(dirname "$RW")"' EXIT
ditto "$APP" "$STAGE/Nudge.app"; ln -s /Applications "$STAGE/Applications"
if [ -f "$BG" ]; then mkdir "$STAGE/.background"; cp "$BG" "$STAGE/.background/bg.tiff"; fi
hdiutil create -volname Nudge -fs HFS+ -srcfolder "$STAGE" -ov -format UDRW "$RW" >/dev/null
MNT=$(hdiutil attach -readwrite -noverify -noautoopen "$RW" | awk -F'\t' '/\/Volumes\// {print $NF}' | tail -1)
[ -d "$MNT" ] || { echo "make-dmg: could not mount $RW"; exit 1; }
VOL=$(basename "$MNT")
if [ -f "$BG" ]; then
  # 660×400 of content. Finder keeps its tab bar on recent macOS whatever we ask, and shows the path
  # bar when the user has it on: 68 pt above the content and 26 below, hence 494 pt. The background
  # runs on past the layout in the same dark surface, so any extra space stays dark.
  osascript <<OSA || echo "(Finder layout skipped)"
tell application "Finder"
  tell disk "$VOL"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set the bounds of container window to {200, 120, 860, 614}
    set opts to the icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 112
    set text size of opts to 12
    set label position of opts to bottom
    set shows item info of opts to false
    set background color of opts to {8224, 8224, 7710}
    set background picture of opts to file ".background:bg.tiff"
    set position of item "Nudge.app" of container window to {165, 200}
    set position of item "Applications" of container window to {495, 200}
    update without registering applications
    delay 2
    close
  end tell
end tell
OSA
  sleep 1
fi
chmod -Rf go-w "$MNT" 2>/dev/null || true
sync; hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet
mkdir -p "$(dirname "$OUTDMG")"; rm -f "$OUTDMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$OUTDMG" >/dev/null
[ -n "$SIGN" ] && codesign --force --sign "$SIGN" --timestamp "$OUTDMG"
echo "Built $OUTDMG"
