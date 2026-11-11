#!/bin/sh
# Renders the Nudge promo: nudge-promo.mp4 (1080×1080, 60 fps, 10.0 s, H.264 yuv420p, silent),
# a 3×2 keyframe contact sheet and a 2 s looping README GIF.
# Usage: tools/promo/render.sh [out-dir]     (default: ./brand-out)
# Needs ffmpeg and ImageMagick (magick) on PATH or in /opt/homebrew/bin.
set -e
export PATH="/opt/homebrew/bin:$PATH"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/brand-out}"
BIN="${TMPDIR:-/tmp}/nudge-promo-build"
mkdir -p "$BIN" "$OUT"
swiftc -O -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$ROOT/src/Theme.swift" "$ROOT/src/Matrix.swift" \
  "$ROOT/tools/brand/Kit.swift" "$ROOT/tools/promo/Promo.swift" -o "$BIN/promo"
export NUDGE_FONTS="$ROOT/Resources/Fonts"

# Video: raw sRGB frames → H.264, BT.709 limited range, tagged.
"$BIN/promo" video | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 1080x1080 -r 60 -i - \
  -frames:v 600 -an -c:v libx264 -preset slow -crf 16 -tune animation \
  -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" \
  -colorspace bt709 -color_primaries bt709 -color_trc bt709 -color_range tv \
  -movflags +faststart "$OUT/nudge-promo.mp4"
N=$(ffprobe -v error -select_streams v:0 -count_frames -show_entries stream=nb_read_frames -of csv=p=0 "$OUT/nudge-promo.mp4")
[ "$N" = 600 ] || { echo "promo: expected 600 frames, got $N" >&2; exit 1; }

# Contact sheet: one keyframe per beat.
K="$BIN/keys"; rm -rf "$K"; mkdir -p "$K"
i=0
for t in 1.05 2.42 3.72 5.95 8.10 9.80; do
  i=$((i + 1)); "$BIN/promo" still "$t" "$K/$i.png"
done
for f in 1 2 3 4 5 6; do
  magick "$K/$f.png" -resize 540x540 -bordercolor '#3A3935' -border 3 "$K/t$f.png"
done
magick \( "$K"/t1.png "$K"/t2.png "$K"/t3.png +append \) \( "$K"/t4.png "$K"/t5.png "$K"/t6.png +append \) \
  -append "$OUT/nudge-promo-contact.png"

# README GIF: 600×200, 25 fps, 2 s loop.
"$BIN/promo" gif | ffmpeg -y -loglevel error -f rawvideo -pix_fmt rgba -s 600x200 -r 25 -i - \
  -vf "split[a][b];[a]palettegen=max_colors=32:stats_mode=full[p];[b][p]paletteuse=dither=none" \
  -loop 0 "$OUT/nudge-pill.gif"

ls -l "$OUT/nudge-promo.mp4" "$OUT/nudge-promo-contact.png" "$OUT/nudge-pill.gif"
