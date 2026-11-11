#!/bin/sh
# Builds build/Nudge.app (universal: Apple silicon + Intel) and dist/Nudge.dmg.
#
#   ./build.sh                 local build, ad-hoc signed; self-updates from this folder (see update.sh)
#   NUDGE_RELEASE=1 NUDGE_SIGN_ID="Developer ID Application: …" ./build.sh
#                              release build for scripts/release.sh: hardened runtime, Developer ID,
#                              no source-folder path baked in (it updates from GitHub Releases)
set -e
cd "$(dirname "$0")"
B=build; APP="$B/Nudge.app"; MIN=macos14.0
VERSION="$(cat VERSION 2>/dev/null || echo 0.0.0)"
BUILD_NO="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
APP_SRC="src/Shared.swift src/Theme.swift src/Matrix.swift src/Export.swift src/Update.swift src/Welcome.swift src/App.swift"
rm -rf "$B" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

# One binary per architecture, then glue them together.
for arch in arm64 x86_64; do
  swiftc -O -parse-as-library -swift-version 5 -target $arch-apple-$MIN $APP_SRC -o "$B/Nudge-$arch"
  swiftc -O -swift-version 5 -target $arch-apple-$MIN src/Shared.swift src/hook/main.swift -o "$B/nudge-hook-$arch"
done
lipo -create "$B/Nudge-arm64" "$B/Nudge-x86_64" -output "$APP/Contents/MacOS/Nudge"
lipo -create "$B/nudge-hook-arm64" "$B/nudge-hook-x86_64" -output "$APP/Contents/MacOS/nudge-hook"

# Fonts (IBM Plex Mono, SIL OFL 1.1)
mkdir -p "$APP/Contents/Resources/Fonts" && cp Resources/Fonts/* "$APP/Contents/Resources/Fonts/"

# Icon
swiftc -swift-version 5 src/icon.swift -o "$B/icon" && "$B/icon" "$B/icon.png" "$B/icon-small.png"
mkdir -p "$B/AppIcon.iconset"
for s in 16 32 128 256 512; do
  src="$B/icon.png"; [ $s -le 32 ] && src="$B/icon-small.png"
  sips -z $s $s "$src" --out "$B/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2)); src2="$B/icon.png"; [ $d -le 32 ] && src2="$B/icon-small.png"
  sips -z $d $d "$src2" --out "$B/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$B/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"

# Where this build came from. A local build updates itself from this folder (update.sh); a
# release build has no source folder and updates from GitHub Releases instead (src/Update.swift).
COMMIT="$(git rev-parse --short HEAD 2>/dev/null || echo none)"
[ -n "$(git status --porcelain 2>/dev/null)" ] && COMMIT="$COMMIT-dirty"
SOURCE_KEY=""
[ -z "${NUDGE_RELEASE:-}" ] && SOURCE_KEY="<key>NudgeSourceDir</key><string>$(pwd)</string>"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Nudge</string>
  <key>CFBundleDisplayName</key><string>Nudge</string>
  <key>CFBundleIdentifier</key><string>com.omar.nudge</string>
  <key>CFBundleExecutable</key><string>Nudge</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NO</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>com.omar.nudge</string>
    <key>CFBundleURLSchemes</key><array><string>nudge</string></array>
  </dict></array>
  $SOURCE_KEY
  <key>NudgeCommit</key><string>$COMMIT</string>
  <key>NudgeRepo</key><string>ulvosama/nudge</string>
  <key>ATSApplicationFontsPath</key><string>Fonts</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST

# Sign the helper first, then the app (no --deep: each piece gets its own signature).
sign() {
  if [ -n "${NUDGE_RELEASE:-}" ]; then
    codesign --force --sign "${NUDGE_SIGN_ID:?set NUDGE_SIGN_ID to your Developer ID Application identity}" \
      --options runtime --timestamp "$1"
  else
    codesign --force --sign - "$1"
  fi
}
sign "$APP/Contents/MacOS/nudge-hook"
sign "$APP"

# DMG with an Applications shortcut (scripts/release.sh makes the styled one).
S="$B/dmg"; mkdir -p "$S"; cp -R "$APP" "$S/"; ln -s /Applications "$S/Applications"
rm -f dist/Nudge.dmg
hdiutil create -volname Nudge -srcfolder "$S" -ov -format UDZO dist/Nudge.dmg >/dev/null
echo "Built $APP ($VERSION, $COMMIT) and dist/Nudge.dmg"
