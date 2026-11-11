import AppKit
import SwiftUI

// Deterministic drawing kit for Nudge brand stills and the promo video.
// Compiled together with src/Theme.swift and src/Matrix.swift (tokens and MatrixFrames are
// reused from there, never copied). Everything is drawn with Core Graphics into a bitmap in
// points with a top-left origin, so a frame is a pure function of its inputs: no TimelineView,
// no wall clock.
//
// The pill and the permission card are rebuilt from the layout constants in src/App.swift
// (Chip, AnswerCard, OptionRow), multiplied by a scale factor `k`.

enum Ink {
    static let p = Palette(highContrast: false)
    static func cg(_ c: Color) -> CGColor { NSColor(c).usingColorSpace(.sRGB)!.cgColor }
    static let surface = cg(p.surface)
    static let border = cg(p.border)
    static let text = cg(p.text)
    static let muted = cg(p.muted)
    static let off = cg(p.offCell)
    static let orange = cg(p.orange)
}

extension CGColor {
    func a(_ alpha: CGFloat) -> CGColor { copy(alpha: alpha) ?? self }
}

/// Registers IBM Plex Mono from Resources/Fonts (path from $NUDGE_FONTS or ../../Resources/Fonts).
func loadFonts() {
    let env = ProcessInfo.processInfo.environment["NUDGE_FONTS"]
    let dir = URL(fileURLWithPath: env ?? "Resources/Fonts")
    Theme.registerFonts(extraDirectory: dir)
    if NSFont(name: "IBMPlexMono-Regular", size: 12) == nil {
        FileHandle.standardError.write("IBM Plex Mono not found in \(dir.path)\n".data(using: .utf8)!)
        exit(1)
    }
}

// MARK: - Board: a bitmap in points, top-left origin

final class Board {
    let ctx: CGContext
    let gctx: NSGraphicsContext
    let pxW: Int, pxH: Int
    let scale: CGFloat
    var width: CGFloat { CGFloat(pxW) / scale }
    var height: CGFloat { CGFloat(pxH) / scale }

    init(width: CGFloat, height: CGFloat, scale: CGFloat = 1) {
        self.scale = scale
        pxW = Int((width * scale).rounded()); pxH = Int((height * scale).rounded())
        ctx = CGContext(data: nil, width: pxW, height: pxH, bitsPerComponent: 8, bytesPerRow: pxW * 4,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 0, y: CGFloat(pxH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.setShouldAntialias(true)
        gctx = NSGraphicsContext(cgContext: ctx, flipped: true)
    }

    func clear(_ c: CGColor?) {
        ctx.saveGState()
        ctx.setBlendMode(.copy)
        ctx.setFillColor(c ?? CGColor(gray: 0, alpha: 0))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.restoreGState()
    }

    func fill(_ r: CGRect, _ c: CGColor) { ctx.setFillColor(c); ctx.fill(r) }

    func fillRound(_ r: CGRect, _ radius: CGFloat, _ c: CGColor) {
        ctx.setFillColor(c)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
    }

    /// SwiftUI strokeBorder: the stroke sits inside the rect.
    func strokeRound(_ r: CGRect, _ radius: CGFloat, _ lw: CGFloat, _ c: CGColor) {
        let i = r.insetBy(dx: lw / 2, dy: lw / 2)
        let rr = max(0, radius - lw / 2)
        ctx.setStrokeColor(c); ctx.setLineWidth(lw)
        ctx.addPath(CGPath(roundedRect: i, cornerWidth: rr, cornerHeight: rr, transform: nil))
        ctx.strokePath()
    }

    @discardableResult
    func text(_ s: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, medium: Bool = false,
              _ color: CGColor, kern: CGFloat = 0) -> CGFloat {
        let str = Board.attr(s, size, medium, color, kern)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        str.draw(at: CGPoint(x: x, y: y))
        NSGraphicsContext.restoreGraphicsState()
        return str.size().width
    }

    static func attr(_ s: String, _ size: CGFloat, _ medium: Bool, _ color: CGColor, _ kern: CGFloat = 0) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: Theme.nsMono(size, medium: medium),
            .foregroundColor: NSColor(cgColor: color)!,
            .kern: kern,
        ])
    }

    static func width(_ s: String, _ size: CGFloat, medium: Bool = false) -> CGFloat {
        attr(s, size, medium, Ink.text).size().width
    }

    /// Line box height of a SwiftUI Text in this font.
    static func lineH(_ size: CGFloat, medium: Bool = false) -> CGFloat {
        let f = Theme.nsMono(size, medium: medium)
        return f.ascender - f.descender + f.leading
    }

    static func ascent(_ size: CGFloat, medium: Bool = false) -> CGFloat { Theme.nsMono(size, medium: medium).ascender }

    func image() -> CGImage { ctx.makeImage()! }

    func png(_ path: String) {
        let rep = NSBitmapImageRep(cgImage: image())
        rep.size = NSSize(width: width, height: height)   // keeps @2x DPI metadata (144)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    }

    /// Raw RGBA bytes, rows top to bottom (opaque frames only).
    var bytes: UnsafeRawBufferPointer { UnsafeRawBufferPointer(start: ctx.data!, count: pxW * pxH * 4) }
}

// MARK: - Matrix grids (frame-indexed MatrixView)

func gridSize(_ rows: [String], pitch: CGFloat, cell: CGFloat) -> CGSize {
    let cols = rows.map(\.count).max() ?? 0
    return CGSize(width: CGFloat(cols) * pitch - (pitch - cell), height: CGFloat(rows.count) * pitch - (pitch - cell))
}

/// Same legend as MatrixView: '#' ink, '+' muted 70%, '-' ink 35%, 'o' off cell, '.' nothing.
/// `show` filters cells (reveals); `force` overrides a cell's character.
func drawGrid(_ b: Board, _ rows: [String], x: CGFloat, y: CGFloat, pitch: CGFloat, cell: CGFloat, ink: CGColor,
              show: ((Int, Int) -> Bool)? = nil) {
    for (r, row) in rows.enumerated() {
        for (c, ch) in row.enumerated() {
            if let show, !show(r, c) { continue }
            let color: CGColor
            switch ch {
            case "#": color = ink
            case "+": color = Ink.muted.a(0.7)
            case "-": color = ink.a(0.35)
            case "o": color = Ink.off
            default: continue
            }
            b.fill(CGRect(x: x + CGFloat(c) * pitch, y: y + CGFloat(r) * pitch, width: cell, height: cell), color)
        }
    }
}

extension MatrixFrames {
    /// Frame at time t (seconds), the same arithmetic as MatrixView's TimelineView.
    func rows(at t: Double) -> [String] {
        guard !frames.isEmpty else { return still }
        let step = period / Double(frames.count)
        return frames[Int(floor(t / step)) % frames.count]
    }
}

/// Stable pseudo-random in 0..<1 for reveal orders.
func hash01(_ a: Int, _ b: Int, _ seed: Int = 0) -> Double {
    var h = UInt64(bitPattern: Int64(a &* 73_856_093 ^ b &* 19_349_663 ^ seed &* 83_492_791))
    h ^= h >> 33; h &*= 0xff51afd7ed558ccd; h ^= h >> 33; h &*= 0xc4ceb9fe1a85ec53; h ^= h >> 33
    return Double(h % 10_000) / 10_000
}

// MARK: - Pill (src/App.swift Chip)

enum Indicator {
    case none
    case breathe(Double)       // time
    case orbit(Double?)        // time, nil = still
    case chase(Double)
    case stamp(Int)            // StampView frame 0...4
}

struct Glyph {
    var rows: [String]
    var lift: CGFloat = 0                    // in cells, negative = up
    var show: ((Int, Int) -> Bool)? = nil
}

struct Pill {
    var indicator: Indicator
    var word: String?
    var wordOrange = false
    var reserveApproving = false             // WORKING / APPROVING share a width
    var icons: [Glyph] = []
    var borderColor = Ink.border

    static func working(_ t: Double, icons: [Glyph] = []) -> Pill {
        Pill(indicator: .breathe(t), word: "WORKING", reserveApproving: true, icons: icons)
    }
    static func asks(_ t: Double?, count: Int = 1, icons: [Glyph] = []) -> Pill {
        // ChipState: the count suffix appears only for 2+ asks.
        Pill(indicator: .orbit(t), word: "ASKS" + (count > 1 ? " · \(count)" : ""), icons: icons)
    }
    static func approving(_ t: Double, icons: [Glyph] = []) -> Pill {
        Pill(indicator: .chase(t), word: "APPROVING", wordOrange: true, reserveApproving: true, icons: icons)
    }

    func wordWidth(_ k: CGFloat) -> CGFloat {
        guard let word else { return 0 }
        let w = Board.width(word, 11 * k, medium: true)
        return reserveApproving ? max(w, Board.width("APPROVING", 11 * k, medium: true)) : w
    }

    func size(_ k: CGFloat) -> CGSize {
        var w: CGFloat = 5 + 24          // leading pad + indicator frame
        if word != nil { w += 8 + wordWidth(1 * k) / k }
        if !icons.isEmpty {
            w += word == nil ? 8 : 7
            w += icons.map { gridSize($0.rows, pitch: 2, cell: 1.5).width }.reduce(0, +) + CGFloat(icons.count - 1) * 5
        }
        w += word == nil && icons.isEmpty ? 5 : 10
        let h = 4 + max(24, Board.lineH(11, medium: true)) + 4
        return CGSize(width: w * k, height: h * k)
    }

    /// Draws the pill with its top-left at (x, y). Border width scales with k (`lw` overrides).
    func draw(_ b: Board, x: CGFloat, y: CGFloat, k: CGFloat, lw: CGFloat? = nil) {
        let s = size(k)
        let r = CGRect(x: x, y: y, width: s.width, height: s.height)
        b.fillRound(r, Theme.radius * k, Ink.surface)
        b.strokeRound(r, Theme.radius * k, lw ?? k, borderColor)
        let midY = y + s.height / 2
        var cx = x + 5 * k
        // indicator, centred in its 24 pt frame
        let box = CGRect(x: cx, y: midY - 12 * k, width: 24 * k, height: 24 * k)
        drawIndicator(b, box, k)
        cx += 24 * k
        if let word {
            cx += 8 * k
            let lh = Board.lineH(11 * k, medium: true)
            b.text(word, cx, midY - lh / 2, 11 * k, medium: true, wordOrange ? Ink.orange : Ink.text)
            cx += wordWidth(k)
        }
        if !icons.isEmpty {
            cx += (word == nil ? 8 : 7) * k
            for g in icons {
                let gs = gridSize(g.rows, pitch: 2 * k, cell: 1.5 * k)
                drawGrid(b, g.rows, x: cx, y: midY - gs.height / 2 + g.lift * 2 * k, pitch: 2 * k, cell: 1.5 * k,
                         ink: Ink.text, show: g.show)
                cx += gs.width + 5 * k
            }
        }
    }

    private func drawIndicator(_ b: Board, _ box: CGRect, _ k: CGFloat) {
        func grid(_ rows: [String], _ pitch: CGFloat, _ cell: CGFloat, _ ink: CGColor) {
            let gs = gridSize(rows, pitch: pitch * k, cell: cell * k)
            drawGrid(b, rows, x: box.midX - gs.width / 2, y: box.midY - gs.height / 2, pitch: pitch * k, cell: cell * k, ink: ink)
        }
        switch indicator {
        case .none: break
        case .breathe(let t): grid(MatrixFrames.breathe.rows(at: t), 4, 3, Ink.text)
        case .orbit(let t): grid(t.map { MatrixFrames.orbit.rows(at: $0) } ?? MatrixFrames.orbit.still, 3, 2, Ink.orange)
        case .chase(let t): grid(MatrixFrames.chase.rows(at: t), 4, 3, Ink.orange)
        case .stamp(let f): drawStamp(b, center: CGPoint(x: box.midX, y: box.midY), side: 12 * k, frame: f, ink: Ink.text, lw: k)
        }
    }
}

/// StampView: faint outline → ink outline → centre → solid.
func drawStamp(_ b: Board, center: CGPoint, side: CGFloat, frame: Int, ink: CGColor, lw: CGFloat) {
    let r = CGRect(x: center.x - side / 2, y: center.y - side / 2, width: side, height: side)
    switch frame {
    case ..<0: break
    case 0: b.strokeRound(r, 0, lw, Ink.muted.a(0.6))
    case 1: b.strokeRound(r, 0, lw, ink)
    case 2:
        b.strokeRound(r, 0, lw, ink)
        b.fill(r.insetBy(dx: side / 4, dy: side / 4), ink)
    default: b.fill(r, ink)
    }
}

// MARK: - Permission card (src/App.swift AnswerCard, .permission, held)

struct Card {
    var session = "api-server"
    var time = "14:32"
    var tool = "Bash"
    var command = "npm run build && npm test"
    var options = ["Yes", "No, tell Claude…"]
    var hover: Int? = nil                 // option row showing its hover plate
    var stampFrame: Int? = nil            // footer shows Stamp + ALLOWED instead of hints
    var stampWord = "ALLOWED"
    var stampChars = Int.max
    var width: CGFloat = Theme.cardWidth + 60

    func height(_ k: CGFloat) -> CGFloat {
        let l11 = Board.lineH(11), l11m = Board.lineH(11, medium: true)
        let row = max(28, Board.lineH(12) + 10)
        var h: CGFloat = 10
        h += l11m + 2 + l11 + 8                     // header
        h += l11m + 8                               // tool
        h += l11 + 16 + 8                           // code block
        h += CGFloat(options.count) * row + CGFloat(options.count - 1) * 2 + 8
        h += 1 + 8                                  // rule
        h += l11 + 10                               // footer
        return h * k
    }

    /// Returns the frame of the primary option's ⌘↩ hint (for the keycap overlay).
    @discardableResult
    func draw(_ b: Board, x: CGFloat, y: CGFloat, k: CGFloat, lw: CGFloat? = nil) -> CGRect {
        let W = width * k, H = height(k)
        let lw = lw ?? k
        let card = CGRect(x: x, y: y, width: W, height: H)
        b.fillRound(card, Theme.radius * k, Ink.surface)
        b.strokeRound(card, Theme.radius * k, lw, Ink.muted)      // held: muted border
        let px = x + Theme.padX * k
        let inner = W - 2 * Theme.padX * k
        var cy = y + 10 * k
        let l11 = Board.lineH(11 * k), l11m = Board.lineH(11 * k, medium: true), l12 = Board.lineH(12 * k)

        // header: orange square + SESSION, then time
        b.fill(CGRect(x: px, y: cy + l11m / 2 - 3 * k, width: 6 * k, height: 6 * k), Ink.orange)
        b.text(session.uppercased(), px + 12 * k, cy, 11 * k, medium: true, Ink.muted)
        cy += l11m + 2 * k
        b.text(time, px, cy, 11 * k, Ink.muted)
        cy += l11 + 8 * k
        // tool
        b.text(tool.uppercased(), px, cy, 11 * k, medium: true, Ink.muted)
        cy += l11m + 8 * k
        // code block
        let code = CGRect(x: px, y: cy, width: inner, height: l11 + 16 * k)
        b.fillRound(code, 4 * k, Ink.border.a(0.45))
        b.text(command, px + 8 * k, cy + 8 * k, 11 * k, Ink.text)
        cy += code.height + 8 * k
        // options
        let rowH = max(28 * k, l12 + 10 * k)
        var hint = CGRect.zero
        for (i, label) in options.enumerated() {
            let row = CGRect(x: px - 6 * k, y: cy, width: inner + 12 * k, height: rowH)
            if hover == i { b.fillRound(row, 4 * k, Ink.border) }
            let ty = cy + (rowH - l12) / 2
            let base = ty + Board.ascent(12 * k)
            let t11 = base - Board.ascent(11 * k, medium: true)
            b.text("⌘\(i + 1)", px, t11, 11 * k, medium: true, Ink.muted)
            b.text(label, px + 32 * k, ty, 12 * k, medium: i == 0, Ink.text)
            if i == 0 {
                let w = Board.width("⌘↩", 11 * k)
                let hx = px + inner - w
                b.text("⌘↩", hx, base - Board.ascent(11 * k), 11 * k, Ink.muted)
                hint = CGRect(x: hx, y: ty, width: w, height: l11)
            }
            cy += rowH + 2 * k
        }
        cy += 6 * k
        b.fill(CGRect(x: px, y: cy, width: inner, height: k), Ink.border)
        cy += k + 8 * k
        if let f = stampFrame {
            let side = 10 * k
            drawStamp(b, center: CGPoint(x: px + side / 2, y: cy + l11 / 2), side: side, frame: f, ink: Ink.text, lw: k)
            b.text(String(stampWord.prefix(stampChars)), px + side + 8 * k, cy, 11 * k, medium: true, Ink.text)
        } else {
            b.text("⌘↩ yes  esc terminal  ⌘O open", px, cy, 11 * k, Ink.muted)
        }
        return hint
    }
}

// MARK: - Small helpers

/// A dotted leader (Theme.Leader): dots every `gap`, `dot` square.
func dottedLine(_ b: Board, from x0: CGFloat, to x1: CGFloat, y: CGFloat, dot: CGFloat, gap: CGFloat, _ c: CGColor) {
    var x = x0
    while x + dot <= x1 + 0.01 {
        b.fill(CGRect(x: x, y: y - dot / 2, width: dot, height: dot), c)
        x += gap
    }
}
