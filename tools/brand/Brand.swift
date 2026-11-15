import AppKit
import SwiftUI

// Renders Nudge's static brand PNGs into the directory given as the first argument.
//   social-preview.png        1280×640   GitHub social card
//   dmg-background.png        1400×1000  (1x) and dmg-background@2x.png 2800×2000 (layout in the top-left 660×400)
//   readme-hero.png           1600×900   pill + open permission card
//   icon-16.png, icon-32.png  small app icon variants (+ icon-16@2x.png = the 32 px drawing)

@main
struct BrandMain {
    static func main() {
        loadFonts()
        let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        socialPreview().png(out + "/social-preview.png")
        dmgBackground(scale: 1).png(out + "/dmg-background.png")
        dmgBackground(scale: 2).png(out + "/dmg-background@2x.png")
        readmeHero().png(out + "/readme-hero.png")
        smallIcon(16).png(out + "/icon-16.png")
        smallIcon(32).png(out + "/icon-32.png")
        smallIcon(32).png(out + "/icon-16@2x.png")
        print("brand: wrote PNGs to \(out)")
    }

    static let eye = Glyph(rows: MatrixFrames.eye.still)

    /// Orbit still + wordmark on one line, left-aligned at x. Returns the bottom.
    static func wordmark(_ b: Board, x: CGFloat, y: CGFloat, size: CGFloat) -> CGFloat {
        let pitch = (size * 0.62 / 8).rounded(.up), cell = max(2, (pitch * 0.7).rounded())
        let gs = gridSize(MatrixFrames.orbit.still, pitch: pitch, cell: cell)
        let lh = Board.lineH(size, medium: true)
        let capTop = y + Board.ascent(size, medium: true) - Theme.nsMono(size, medium: true).capHeight
        let capH = Theme.nsMono(size, medium: true).capHeight
        drawGrid(b, MatrixFrames.orbit.still, x: x, y: capTop + capH / 2 - gs.height / 2, pitch: pitch, cell: cell, ink: Ink.orange)
        b.text("Nudge", x + gs.width + size * 0.32, y, size, medium: true, Ink.text)
        return y + lh
    }

    static func socialPreview() -> Board {
        let b = Board(width: 1280, height: 640)
        b.clear(Ink.surface)
        let x: CGFloat = 112
        // top label + hairline
        b.text("FOR CLAUDE CODE · MACOS", x, 84, 20, medium: true, Ink.muted, kern: 1)
        b.fill(CGRect(x: x, y: 124, width: 1280 - 2 * x, height: 2), Ink.border)
        let bottom = wordmark(b, x: x, y: 168, size: 104)
        b.text("Answer Claude Code from a floating pill", x, bottom + 14, 34, Ink.text)
        // pill, lower left, with a dotted leader running out to the right edge like a receipt line
        let k: CGFloat = 3.4
        let pill = Pill.asks(nil, icons: [eye])
        let ps = pill.size(k)
        let py: CGFloat = 640 - 92 - ps.height
        pill.draw(b, x: x, y: py, k: k, lw: 2)
        dottedLine(b, from: x + ps.width + 24, to: 1280 - x - Board.width("⌘↩ ALLOW", 20, medium: true) - 20,
                   y: py + ps.height / 2, dot: 3, gap: 10, Ink.off)
        b.text("⌘↩ ALLOW", 1280 - x - Board.width("⌘↩ ALLOW", 20, medium: true), py + ps.height / 2 - Board.lineH(20, medium: true) / 2,
               20, medium: true, Ink.muted)
        return b
    }

    /// Finder places the app icon at (165, 200) and the Applications link at (495, 200), 112 pt icons.
    /// The layout is 660×400 from the top-left, but the canvas runs on in the same dark surface:
    /// Finder may open the window larger (toolbar, path bar, its own minimum size) and fills
    /// anything past the picture with white.
    static func dmgBackground(scale: CGFloat) -> Board {
        let b = Board(width: 1400, height: 1000, scale: scale)
        b.clear(Ink.surface)
        // Finder draws icon names in dark text over any background picture, whatever the
        // appearance, so each name sits on a light tag (112 pt icons: name centred ~74 pt below).
        for cx in [CGFloat(165), 495] {
            b.fillRound(CGRect(x: cx - 56, y: 200 + 63, width: 112, height: 21), 3, Ink.text)
        }
        // receipt header
        b.text("NUDGE", 24, 22, 11, medium: true, Ink.muted, kern: 0.5)
        let ver = "INSTALL"
        b.text(ver, 660 - 24 - Board.width(ver, 11, medium: true) - 0.5 * CGFloat(ver.count), 22, 11, medium: true, Ink.muted, kern: 0.5)
        b.fill(CGRect(x: 24, y: 44, width: 612, height: 1), Ink.border)
        // dotted leader arrow between the two icon slots
        let y: CGFloat = 200, x0: CGFloat = 165 + 84, x1: CGFloat = 495 - 84
        dottedLine(b, from: x0, to: x1 - 10, y: y, dot: 2, gap: 6, Ink.muted)
        // arrowhead built from cells
        for i in 0..<4 {
            let d = CGFloat(i) * 3
            b.fill(CGRect(x: x1 - 2 - d, y: y - 1 - d, width: 2, height: 2), Ink.text)
            b.fill(CGRect(x: x1 - 2 - d, y: y - 1 + d, width: 2, height: 2), Ink.text)
        }
        // instruction
        let s = "Drag Nudge to Applications"
        let w = Board.width(s, 14, medium: true)
        b.text(s, 330 - w / 2, 300, 14, medium: true, Ink.text)
        let sub = "THEN OPEN IT FROM APPLICATIONS"
        let ws = Board.width(sub, 10, medium: true) + 0.5 * CGFloat(sub.count)
        b.text(sub, 330 - ws / 2, 324, 10, medium: true, Ink.muted, kern: 0.5)
        b.fill(CGRect(x: 24, y: 400 - 44, width: 612, height: 1), Ink.border)
        return b
    }

    static func readmeHero() -> Board {
        let b = Board(width: 1600, height: 900)
        b.clear(Ink.surface)
        let k: CGFloat = 2.5
        let card = Card()
        let pill = Pill.asks(nil, icons: [eye])
        let ps = pill.size(k)
        let cw = card.width * k, ch = card.height(k)
        let total = ps.height + 6 * k + ch
        let x = (1600 - cw) / 2 + 150
        let y = (900 - total) / 2
        // RootView: VStack(alignment: .leading, spacing: 6) { Chip; AnswerCard }
        pill.draw(b, x: x, y: y, k: k)
        card.draw(b, x: x, y: y + ps.height + 6 * k, k: k)
        // left column: wordmark, receipt-style caption
        let lx: CGFloat = 96
        let bottom = wordmark(b, x: lx, y: y - 4, size: 60)
        b.text("Answer Claude Code", lx, bottom + 24, 26, Ink.text)
        b.text("from a floating pill", lx, bottom + 60, 26, Ink.text)
        var ly = bottom + 136
        for (l, r) in [("ALLOW", "⌘↩"), ("DENY", "⌘2"), ("TERMINAL", "ESC")] {
            b.text(l, lx, ly, 18, medium: true, Ink.muted)
            let rw = Board.width(r, 18, medium: true)
            b.text(r, lx + 340 - rw, ly, 18, medium: true, Ink.text)
            dottedLine(b, from: lx + Board.width(l, 18, medium: true) + 12, to: lx + 340 - rw - 14,
                       y: ly + Board.lineH(16, medium: true) / 2 + 1, dot: 2, gap: 6, Ink.off)
            ly += 40
        }
        return b
    }

    /// Small app icon: the Orbit still reduced to a 4×4 (16 px) or 5×5 (32 px) ring of big cells,
    /// pixel-aligned. Off quarter top-left, like the 1024 px icon.
    static func smallIcon(_ px: Int) -> Board {
        let b = Board(width: CGFloat(px), height: CGFloat(px))
        b.clear(nil)
        b.ctx.setShouldAntialias(true)
        let rows: [String]
        let cell: CGFloat, pitch: CGFloat, inset: CGFloat, radius: CGFloat
        if px <= 16 {
            rows = [".o#.", "o..#", "#..#", ".##."]
            cell = 2; pitch = 4; inset = 0; radius = 3.5
        } else {
            rows = [".o##.", "o...#", "#...#", "#...#", ".###."]
            cell = 4; pitch = 5; inset = 2; radius = 6
        }
        let bg = CGRect(x: inset, y: inset, width: CGFloat(px) - 2 * inset, height: CGFloat(px) - 2 * inset)
        b.fillRound(bg, radius, Ink.surface)
        if px > 16 { b.strokeRound(bg, radius, 1, Ink.border) }
        b.ctx.setShouldAntialias(false)
        let gs = gridSize(rows, pitch: pitch, cell: cell)
        let o = ((CGFloat(px) - gs.width) / 2).rounded(.down)
        drawGrid(b, rows, x: o, y: o, pitch: pitch, cell: cell, ink: Ink.orange)
        return b
    }
}
