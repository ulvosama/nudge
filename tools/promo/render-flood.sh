#!/bin/sh
# Renders video 3: nudge-flood.mp4 (1920×1080, 60 fps, 21.0 s, H.264 yuv420p, silent)
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
K="$BIN/fkeys"; rm -rf "$K"; mkdir -p "$K"
i=0
for t in 2.2 7.9 9.3 10.5 11.7 14.6 17.4 20.4; do
  i=$((i + 1)); "$BIN/promo" still-flood "$t" "$K/$i.png"
  magick "$K/$i.png" -resize 640x360 -bordercolor '#3A3935' -border 3 "$K/t$i.png"
done
magick \( "$K"/t1.png "$K"/t2.png "$K"/t3.png "$K"/t4.png +append \) \
       \( "$K"/t5.png "$K"/t6.png "$K"/t7.png "$K"/t8.png +append \) -append "$OUT/nudge-flood-contact.png"
[ "${2:-}" = "--sheet-only" ] && { ls -l "$OUT/nudge-flood-contact.png"; exit 0; }

"$BIN/promo" flood | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1920x1080 -r 60 -i - \
  -frames:v 1260 -an -c:v libx264 -preset slow -crf 18 -tune animation \
  -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -movflags +faststart "$OUT/nudge-flood.mp4"
N=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/nudge-flood.mp4")
[ "$N" = 1260 ] || { echo "flood: expected 1260 frames, got $N" >&2; exit 1; }
ls -l "$OUT/nudge-flood.mp4" "$OUT/nudge-flood-contact.png"
