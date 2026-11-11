#!/bin/sh
# Renders Nudge's static brand PNGs (social preview, DMG background, README hero, small icons).
# Usage: tools/brand/render.sh [out-dir]     (default: ./brand-out)
# Compiles src/Theme.swift + src/Matrix.swift (tokens, MatrixFrames) with tools/brand/*.swift.
set -e
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/brand-out}"
BIN="${TMPDIR:-/tmp}/nudge-brand-build"
mkdir -p "$BIN" "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/src/Theme.swift" "$ROOT/src/Matrix.swift" \
  "$ROOT/tools/brand/Kit.swift" "$ROOT/tools/brand/Brand.swift" -o "$BIN/brand"
NUDGE_FONTS="$ROOT/Resources/Fonts" "$BIN/brand" "$OUT"
# Retina DMG background: one TIFF holding both resolutions (Finder picks the right one).
tiffutil -cathidpicheck "$OUT/dmg-background.png" "$OUT/dmg-background@2x.png" \
  -out "$OUT/dmg-background.tiff" >/dev/null 2>&1 || true
