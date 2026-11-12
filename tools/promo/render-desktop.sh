#!/bin/sh
# Renders the desktop story: nudge-desktop.mp4 (1920×1080, 60 fps, 17.0 s, H.264 yuv420p, silent)
# and a 4×2 keyframe contact sheet.
# Usage: tools/promo/render-desktop.sh [out-dir] [--sheet-only]     (default: ./brand-out)
# Needs ffmpeg and ImageMagick (magick) on PATH or in /opt/homebrew/bin.
set -e
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/brand-out}"
BIN="${TMPDIR:-/tmp}/nudge-promo-build"
mkdir -p "$BIN" "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/src/Theme.swift" "$ROOT/src/Matrix.swift" \
  "$ROOT/tools/brand/Kit.swift" "$ROOT/tools/promo/Promo.swift" "$ROOT/tools/promo/Desktop.swift" "$ROOT/tools/promo/Flood.swift" -o "$BIN/promo"
export NUDGE_FONTS="$ROOT/Resources/Fonts"

# Contact sheet: one keyframe per beat.
K="$BIN/dkeys"; rm -rf "$K"; mkdir -p "$K"
i=0
for t in 2.6 3.9 5.8 6.9 8.3 11.6 13.2 16.4; do
  i=$((i + 1)); "$BIN/promo" still-desktop "$t" "$K/$i.png"
  magick "$K/$i.png" -resize 640x360 -bordercolor '#3A3935' -border 3 "$K/t$i.png"
done
magick \( "$K"/t1.png "$K"/t2.png "$K"/t3.png "$K"/t4.png +append \) \
       \( "$K"/t5.png "$K"/t6.png "$K"/t7.png "$K"/t8.png +append \) -append "$OUT/nudge-desktop-contact.png"
[ "${2:-}" = "--sheet-only" ] && { ls -l "$OUT/nudge-desktop-contact.png"; exit 0; }

"$BIN/promo" desktop | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 60 -i - \
  -frames:v 1020 -an -c:v libx264 -preset slow -crf 18 -tune animation \
  -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -movflags +faststart "$OUT/nudge-desktop.mp4"
N=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/nudge-desktop.mp4")
[ "$N" = 1020 ] || { echo "desktop: expected 1020 frames, got $N" >&2; exit 1; }
ls -l "$OUT/nudge-desktop.mp4" "$OUT/nudge-desktop-contact.png"
