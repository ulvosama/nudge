# tools/

Renderers for Nudge's brand assets. Nothing here is part of the app build.

| Script | Output |
| --- | --- |
| `tools/brand/render.sh [out]` | `social-preview.png` 1280×640, `dmg-background.png` 660×400 + `@2x` + `.tiff` (both), `readme-hero.png` 1600×900, `icon-16.png`, `icon-32.png`, `icon-16@2x.png` |
| `tools/promo/render.sh [out]` | `nudge-promo.mp4` 1080×1080, 60 fps, 10.0 s, H.264 yuv420p, silent; `nudge-promo-contact.png` (6 keyframes, 3×2); `nudge-pill.gif` 600×200, 2 s loop |

`out` defaults to `./brand-out`. The promo needs `ffmpeg` and `magick` (ImageMagick).

## How it works

- `brand/Kit.swift` is compiled with `src/Theme.swift` and `src/Matrix.swift`, so the palette,
  fonts (IBM Plex Mono from `Resources/Fonts`) and the `MatrixFrames` grids come straight from the app.
- Frames are drawn with Core Graphics as a pure function of time: `MatrixFrames.rows(at:)` steps
  frames with the same arithmetic as `MatrixView`'s `TimelineView`, so renders are deterministic.
- The pill (`Pill`) and permission card (`Card`) are rebuilt from the layout constants in
  `src/App.swift` (`Chip`, `AnswerCard`, `OptionRow`, `StampView`) scaled by `k`; the real views
  need a live `Store`, so they are not rendered directly. Keep them in sync if those views change.
- Promo-only grids (eye blink frames, fingerprint, check stroke order) live in `promo/Promo.swift`.
- `promo still <t> <png>` renders one frame for checking a moment of the video.
