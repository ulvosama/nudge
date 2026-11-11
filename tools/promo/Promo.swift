import AppKit
import SwiftUI

// Nudge promo: 1080×1080, 60 fps, 10.0 s. Every frame is a pure function of its index, drawn
// with tools/brand/Kit.swift (tokens from src/Theme.swift, grids from src/Matrix.swift).
//
//   promo video            raw RGBA frames on stdout (600 frames) for ffmpeg
//   promo still <t> <png>  one frame at time t (seconds)
//   promo gif              raw RGBA 600×200 frames on stdout, 25 fps × 2 s, for the README GIF
//
// Motion rules: cells and characters switch on/off on frame steps. Nothing fades, blurs,
// rotates or eases continuously.

let S: CGFloat = 1080
let FPS = 60
let K: CGFloat = 4.5            // pill scale (≈ 4.5 × the app's points)
let PY: CGFloat = 500           // pill centre y
let CARD_K: CGFloat = 2.05      // permission card scale

// MARK: - Grids designed for the promo (same 7-col family as MatrixFrames.eye / .check / .bolt)

enum Eye {
    static let open = MatrixFrames.eye.still
    static let half = [".......", ".#####.", "#..#..#", ".#####.", "......."]
    static let closed = [".......", ".......", "#######", ".......", "......."]
}

/// Check cells in stroke order (row, col): short arm down, long arm up.
let checkStroke = [(2, 0), (2, 1), (3, 1), (3, 2), (4, 2), (3, 3), (2, 3), (2, 4), (1, 4), (1, 5), (0, 5), (0, 6)]

/// Pixel fingerprint (13×15): arched ridges over a whorl, lit '#'; the rest of the oval is off
/// cells 'o' so the grid reads as a sensor.
let fingerprint: [String] = {
    let ridges = [
        "....#####....",
        "..##.....##..",
        ".#..#####..#.",
        "#..#.....#..#",
        "#.#..###..#.#",
        "#.#.#...#.#.#",
        "#.#.#.#.#.#.#",
        "#.#.#.#.#.#.#",
        "#.#.#.#.#...#",
        "#...#.#.#.#.#",
        "..#.#.#..#..#",
        ".#..#..#.#.#.",
        "...#..#..#...",
        "..#..#..#....",
        "....#..#.....",
    ]
    return ridges.enumerated().map { r, row in
        String(row.enumerated().map { c, ch -> Character in
            if ch == "#" { return "#" }
            let dx = (Double(c) - 6) / 6.6, dy = (Double(r) - 7) / 7.6
            return dx * dx + dy * dy <= 1 ? "o" : "."
        })
    }
}()

// MARK: - Timeline helpers

func steps(_ t: Double, from a: Double, _ dur: Double, _ n: Int) -> Int {
    guard t >= a else { return 0 }
    return min(n, Int(floor((t - a) / dur * Double(n))) + 1)
}

func pick<T>(_ t: Double, _ table: [(Double, T)]) -> T {
    var v = table[0].1
    for (at, x) in table where t >= at { v = x }
    return v
}

// MARK: - Tooltip

/// One line above the pill that grows a word per mode and keeps the earlier ones:
/// WATCH → WATCH · AWAKE → … → WATCH · AWAKE · ANSWER · AUTO · QUICK.
/// The newest word is in full ink and typed in; earlier words drop to muted.
struct ModeLine {
    static let words: [(String, Double)] = [("WATCH", 0.24), ("AWAKE", 1.30), ("ANSWER", 2.72), ("AUTO", 5.06), ("QUICK", 7.12)]
    static let tOut = 8.24
    static let size: CGFloat = 34
    static let sep = " · "

    func draw(_ b: Board, _ t: Double, pillTop: CGFloat) {
        let start = ModeLine.words[0].1
        guard t >= start, t < ModeLine.tOut + 0.14 else { return }
        let on = ModeLine.words.filter { $0.1 <= t }
        let line = on.map(\.0).joined(separator: ModeLine.sep)
        let size = ModeLine.size
        let padX: CGFloat = 30, padY: CGFloat = 22
        let lh = Board.lineH(size, medium: true)
        let bs = CGSize(width: Board.width(line, size, medium: true) + CGFloat(line.count) * 2 + 2 * padX, height: lh + 2 * padY)
        let bottom = pillTop - 64
        let r = CGRect(x: (S - bs.width) / 2, y: bottom - bs.height, width: bs.width, height: bs.height)

        var leaderSteps = steps(t - start, from: 0, 0.10, 6)
        var boxOn = t - start >= 0.10
        var textOn = true
        if t >= ModeLine.tOut {                      // switch off: text, then box, then leader
            let v = t - ModeLine.tOut
            textOn = false
            boxOn = v < 0.07
            leaderSteps = v < 0.07 ? 6 : max(0, 6 - Int((v - 0.07) / 0.07 * 6))
        }
        let len = pillTop - bottom
        let h = len * CGFloat(leaderSteps) / 6
        b.fill(CGRect(x: S / 2 - 1, y: pillTop - h, width: 2, height: h), Ink.muted)
        if leaderSteps > 0 { b.fill(CGRect(x: S / 2 - 4, y: pillTop - h - 4, width: 8, height: 8), Ink.muted) }
        guard boxOn else { return }
        b.fillRound(r, 12, Ink.surface)
        b.strokeRound(r, 12, 2, Ink.border)

        // Earlier words muted, the newest typed in at 40 chars/s with a block cursor.
        let newest = on.last!
        let typed = min(newest.0.count, max(0, Int((t - newest.1 - 0.06) * 40)))
        let head = on.dropLast().map(\.0).map { $0 + ModeLine.sep }.joined()
        var x = r.minX + padX
        let y = r.minY + padY
        guard textOn else { return }
        x += b.text(head, x, y, size, medium: true, Ink.muted, kern: 2)
        x += b.text(String(newest.0.prefix(typed)), x, y, size, medium: true, Ink.text, kern: 2)
        if t < ModeLine.tOut && typed < newest.0.count {
            let cw = Board.width("M", size) * 0.62
            b.fill(CGRect(x: x + 2, y: y + lh * 0.18, width: cw, height: lh * 0.64), Ink.text)
        }
    }
}

let modeLine = ModeLine()

// MARK: - Scene

/// Reveal (or hide) a rect cell by cell: blocks of `cell` px come on at staggered times.
func cellClip(_ b: Board, _ r: CGRect, cell: CGFloat, progress: (Int, Int, Int, Int) -> Bool) {
    let nx = Int(ceil(r.width / cell)), ny = Int(ceil(r.height / cell))
    var rects: [CGRect] = []
    for j in 0..<ny { for i in 0..<nx where progress(i, j, nx, ny) {
        rects.append(CGRect(x: r.minX + CGFloat(i) * cell, y: r.minY + CGFloat(j) * cell, width: cell, height: cell))
    } }
    if rects.isEmpty { rects = [.zero] }
    b.ctx.clip(to: rects)
}

func pillAt(_ t: Double) -> Pill? {
    // icons: eye (from 1.36), check (6.16–7.10), bolt (7.10–)
    var icons: [Glyph] = []
    if t >= 1.36 {
        var eye = Glyph(rows: Eye.open)
        if t < 1.60 {
            eye.show = { r, c in t >= 1.36 + hash01(r, c, 7) * 0.22 }
        }
        for b0 in [1.82, 2.16] {
            if t >= b0 && t < b0 + 0.05 { eye.rows = Eye.half }
            if t >= b0 + 0.05 && t < b0 + 0.14 { eye.rows = Eye.closed }
        }
        icons.append(eye)
    }
    if t >= 6.16 && t < 7.10 {
        let n = Int((t - 6.16) / 0.026) + 1
        let lit = Set(checkStroke.prefix(n).map { $0.0 * 10 + $0.1 })
        var g = Glyph(rows: MatrixFrames.check.still)
        g.show = { r, c in lit.contains(r * 10 + c) }
        if t >= 6.62 && t < 6.74 { g.lift = -1 }
        icons.append(g)
    }
    if t >= 7.10 {
        var g = Glyph(rows: MatrixFrames.bolt.still)
        let rowsOn = Int((t - 7.10) / 0.04) + 1
        g.show = { r, _ in r < rowsOn }
        icons.append(g)
    }
    if t >= 7.34 { return .approving(t - 7.34, icons: icons) }
    if t >= 2.60 && t < 4.66 { return .asks(t - 2.60, icons: icons) }
    return .working(t, icons: icons)
}

func drawCard(_ b: Board, _ t: Double, pillBottom: CGFloat) {
    guard t >= 2.82 && t < 4.66 else { return }
    var card = Card()
    if t >= 3.66 && t < 3.86 { card.hover = 0 }
    if t >= 3.86 {
        card.stampFrame = min(3, Int((t - 3.86) / 0.1))
        card.stampChars = max(0, Int((t - 3.90) * 50))
    }
    let w = card.width * CARD_K, h = card.height(CARD_K)
    let x = (S - w) / 2, y = pillBottom + 22
    // unfold / fold in 8 row steps
    var frac = CGFloat(steps(t, from: 2.82, 0.20, 8)) / 8
    if t >= 4.44 { frac = CGFloat(8 - steps(t, from: 4.44, 0.20, 8)) / 8 }
    guard frac > 0 else { return }
    b.ctx.saveGState()
    b.ctx.clip(to: CGRect(x: x - 4, y: y - 4, width: w + 8, height: h * frac + 4))
    let hint = card.draw(b, x: x, y: y, k: CARD_K, lw: 2)
    // fold edge: a hairline that rides the cut
    b.ctx.restoreGState()
    if frac < 1 { b.fill(CGRect(x: x, y: y + h * frac - 2, width: w, height: 2), Ink.muted) }

    // ⌘↩ keycap over the card's hint: appears by cells, presses, leaves by cells
    guard t >= 3.26 && t < 4.12, frac == 1 else { return }
    let kw: CGFloat = 132, kh: CGFloat = 112, depth: CGFloat = 10
    let kx = hint.midX - kw / 2 + 18, ky = hint.midY - kh / 2 + 6
    let pressed = t >= 3.66 && t < 3.80
    b.ctx.saveGState()
    cellClip(b, CGRect(x: kx, y: ky, width: kw, height: kh + depth), cell: 12) { i, j, nx, ny in
        let h = hash01(i, j, 3)
        if t >= 3.98 { return t < 3.98 + h * 0.12 }
        return t >= 3.26 + h * 0.12
    }
    let base = CGRect(x: kx, y: ky + depth, width: kw, height: kh)
    b.fillRound(base, 14, Ink.border)                        // key side
    let top = CGRect(x: kx, y: ky + (pressed ? depth : 0), width: kw, height: kh)
    b.fillRound(top, 14, Ink.surface)
    b.strokeRound(top, 14, 2, pressed ? Ink.text : Ink.muted)
    let label = "⌘↩"
    let lw = Board.width(label, 40, medium: true)
    b.text(label, top.midX - lw / 2, top.midY - Board.lineH(40, medium: true) / 2, 40, medium: true, Ink.text)
    b.ctx.restoreGState()
}

func drawFingerprint(_ b: Board, _ t: Double, pillBottom: CGFloat) {
    guard t >= 5.12 && t < 6.16 else { return }
    let pitch: CGFloat = 17, cell: CGFloat = 12
    let gs = gridSize(fingerprint, pitch: pitch, cell: cell)
    let x = (S - gs.width) / 2, y = pillBottom + 64
    let cx = 6.0, cy = 7.0
    func dist(_ r: Int, _ c: Int) -> Double {
        let dx = Double(c) - cx, dy = (Double(r) - cy) * 0.82
        return (dx * dx + dy * dy).squareRoot()
    }
    // grid of off cells comes on, then ridges fill centre-out, then everything switches off
    let fillAt = { (r: Int, c: Int) -> Double in 5.26 + dist(r, c) / 7.0 * 0.62 }
    let rows = fingerprint.enumerated().map { (r, row) -> String in
        String(row.enumerated().map { (c, ch) -> Character in
            ch == "#" && t < fillAt(r, c) ? "o" : ch
        })
    }
    drawGrid(b, rows, x: x, y: y, pitch: pitch, cell: cell, ink: Ink.text) { r, c in
        if t >= 6.0 { return t < 6.0 + hash01(r, c, 11) * 0.14 }
        return t >= 5.12 + hash01(r, c, 5) * 0.12
    }
    // label under the print
    if t >= 5.92 && t < 6.0 {
        let s = "TOUCH ID ✓"
        let w = Board.width(s, 22, medium: true)
        b.text(s, (S - w) / 2, y + gs.height + 22, 22, medium: true, Ink.text, kern: 1)
    } else if t >= 5.30 && t < 5.92 {
        let s = "TOUCH ID"
        let w = Board.width(s, 22, medium: true)
        b.text(String(s.prefix(Int((t - 5.30) * 40))), (S - w) / 2, y + gs.height + 22, 22, medium: true, Ink.muted, kern: 1)
    }
}

func drawEndCard(_ b: Board, _ t: Double) {
    guard t >= 8.60 else { return }
    let pitch: CGFloat = 22, cell: CGFloat = 16
    let rows = MatrixFrames.orbit.rows(at: max(0, t - 8.80))
    let gs = gridSize(rows, pitch: pitch, cell: cell)
    let ox = (S - gs.width) / 2, oy: CGFloat = 250
    drawGrid(b, rows, x: ox, y: oy, pitch: pitch, cell: cell, ink: Ink.orange) { r, c in
        t >= 8.60 + hash01(r, c, 13) * 0.18
    }
    func typed(_ s: String, from a: Double, rate: Double) -> String { String(s.prefix(t < a ? 0 : Int((t - a) * rate) + 1)) }
    let name = "Nudge"
    let nw = Board.width(name, 132, medium: true)
    b.text(typed(name, from: 8.82, rate: 36), (S - nw) / 2, oy + gs.height + 40, 132, medium: true, Ink.text)
    let sub = "for Claude Code · macOS · free & open source"
    let sw = Board.width(sub, 30)
    let sy = oy + gs.height + 40 + Board.lineH(132, medium: true) + 18
    b.text(typed(sub, from: 9.00, rate: 140), (S - sw) / 2, sy, 30, Ink.muted)
    if t >= 9.30 {
        let ry = sy + Board.lineH(30) + 34
        let rw: CGFloat = 120
        let n = steps(t, from: 9.30, 0.08, 6)
        b.fill(CGRect(x: (S - rw) / 2, y: ry, width: rw * CGFloat(n) / 6, height: 2), Ink.border)
    }
    let url = "github.com/ulvosama/nudge"
    let uw = Board.width(url, 32, medium: true)
    b.text(typed(url, from: 9.36, rate: 120), (S - uw) / 2, sy + Board.lineH(30) + 70, 32, medium: true, Ink.text)
}

func render(_ b: Board, _ t: Double) {
    b.clear(Ink.surface)
    guard let pill = pillAt(t) else { return }
    let ps = pill.size(K)
    let px = ((S - ps.width) / 2).rounded(), py = (PY - ps.height / 2).rounded()
    if t < 8.62 {
        b.ctx.saveGState()
        let rect = CGRect(x: px - 2, y: py - 2, width: ps.width + 4, height: ps.height + 4)
        if t < 0.5 {
            // build-in: 18 px cells switch on, sweeping left to right with a little scatter
            cellClip(b, rect, cell: 18) { i, j, nx, _ in
                t >= 0.04 + Double(i) / Double(nx) * 0.28 + hash01(i, j, 2) * 0.12
            }
        } else if t >= 8.40 {
            cellClip(b, rect, cell: 18) { i, j, nx, _ in
                t < 8.40 + (1 - Double(i) / Double(nx)) * 0.12 + hash01(i, j, 9) * 0.08
            }
        }
        pill.draw(b, x: px, y: py, k: K, lw: 3)
        b.ctx.restoreGState()
    }
    modeLine.draw(b, t, pillTop: py)
    drawCard(b, t, pillBottom: py + ps.height)
    drawFingerprint(b, t, pillBottom: py + ps.height)
    drawEndCard(b, t)
}

// MARK: - GIF scene: WORKING → ASKS → APPROVING, 2 s loop

func renderGif(_ b: Board, _ t: Double) {
    b.clear(Ink.surface)
    let k: CGFloat = 3.4
    let pill: Pill = t < 0.68 ? .working(t) : t < 1.34 ? .asks(t - 0.68) : .approving(t - 1.34)
    let ps = pill.size(k)
    pill.draw(b, x: ((b.width - ps.width) / 2).rounded(), y: ((b.height - ps.height) / 2).rounded(), k: k, lw: 2)
}

// MARK: - main

@main
struct PromoMain {
    static func main() {
        loadFonts()
        let args = CommandLine.arguments
        let mode = args.count > 1 ? args[1] : "video"
        let out = FileHandle.standardOutput
        switch mode {
        case "still":
            let b = Board(width: S, height: S)
            render(b, Double(args[2])!)
            b.png(args[3])
        case "gif":
            let b = Board(width: 600, height: 200)
            for f in 0..<50 {
                renderGif(b, Double(f) / 25)
                out.write(Data(b.bytes))
            }
        case "fingerprint":
            print(fingerprint.joined(separator: "\n"))
        default:
            let b = Board(width: S, height: S)
            for f in 0..<(FPS * 10) {
                render(b, Double(f) / Double(FPS))
                out.write(Data(b.bytes))
            }
        }
    }
}
