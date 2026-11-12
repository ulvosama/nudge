import AppKit
import SwiftUI

// Desktop promo: 1920×1080, 60 fps, 17.0 s. Problem → situation → solution, told on a stylized Mac.
// Compiled with Promo.swift (shares steps, cellClip, Eye, checkStroke, fingerprint) and
// tools/brand/Kit.swift (Board, Pill, Card). Every frame is a pure function of t.
//
//   promo desktop                  raw RGBA frames on stdout (900 frames) for ffmpeg
//   promo still-desktop <t> <png>  one frame at time t (seconds)
//
//   0.0–4.2   problem    four Claude sessions; questions pile up (1 → 12), windows jump, cursor hunts
//   4.2–6.0   situation  clock runs on, everything waits, the display sleeps
//   6.0–12.2  solution   focus: the desktop dims and the pill takes the centre. Eye wakes the
//                        screen, asks fly to the pill, ⌘↩ ×3, Touch ID → auto, bolt → APPROVING
//                        drains the rest. A window lights up only at the moment it's answered.
//   12.2–14.0 calm       the dim lifts, the pill moves to the top, every session works
//   14.0–17.0 end card   over the still-working desktop

let DW: CGFloat = 1920, DH: CGFloat = 1080
let DFRAMES = 1020
let DK: CGFloat = 2.8             // pill scale
let DCARD_K: CGFloat = 1.75       // card scale
let DPILL_TOP: CGFloat = 50       // the pill's home, under the menu bar
let DPILL_FOCUS: CGFloat = 280    // the pill's top while it has the stage

/// Pill top: centre stage, then a stepped move to its home once everything is answered.
func pillTop(_ t: Double) -> CGFloat {
    let n = steps(t, from: 12.35, 0.3, 10)
    return (DPILL_FOCUS + (DPILL_TOP - DPILL_FOCUS) * CGFloat(n) / 10).rounded()
}

/// Darkness of one screen cell (h = its random 0..<1): display sleep, then the focus dim while
/// Nudge works, cleared once everything is answered, then the end-card dim.
func cellDark(_ h: Double, _ t: Double) -> CGFloat {
    let h2 = hash01(Int(h * 9973), 1, 43)
    if t >= 14.0 + h * 0.4 { return 0.8 }
    if t >= 12.2 + h2 * 0.3 { return 0 }
    if t >= 6.45 + h2 * 0.25 { return 0.6 }
    if t >= 5.0 + h * 0.8 { return 0.86 }
    return 0
}

/// Windows that "take effect" (an answer lands) come out of the dim for a moment.
func spotlit(_ wi: Int, _ t: Double) -> Bool {
    guard t >= 6.0 && t < 12.2 else { return false }
    return asks.contains { $0.win == wi && t >= $0.resolve && t < $0.resolve + ($0.resolve < 10 ? 0.6 : 0.35) }
}

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}
func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }
func smooth(_ x: Double) -> Double { let c = clamp01(x); return c * c * (3 - 2 * c) }

// MARK: - Story data

struct Ask { let time: Double; let win: Int; let tool: String; let command: String; let resolve: Double }

let manualResolve: [Double] = [8.25, 8.85, 9.30]
let cardStamp: [Double] = [8.12, 8.70, 9.15]
let cardStart: [Double] = [7.55, 8.55, 9.00]
let autoStart = 11.25, autoStep = 0.085

let asks: [Ask] = [
    (1.00, 0, "Bash", "npm test"),
    (1.42, 1, "Bash", "git push origin main"),
    (1.78, 3, "Bash", "terraform plan"),
    (2.08, 2, "Edit", "docs/setup.md"),
    (2.32, 0, "Bash", "npm run migrate"),
    (2.54, 1, "Bash", "npx playwright test"),
    (2.74, 3, "Bash", "kubectl get pods"),
    (2.92, 2, "Bash", "rm -rf build/"),
    (3.08, 0, "Edit", "src/auth.ts"),
    (3.24, 3, "Bash", "aws s3 ls"),
    (3.38, 1, "Bash", "npm run build"),
    (3.52, 2, "Fetch", "docs.python.org"),
].enumerated().map { i, s in
    Ask(time: s.0, win: s.1, tool: s.2, command: s.3,
        resolve: i < 3 ? manualResolve[i] : autoStart + Double(i - 3) * autoStep)
}

func pendingCount(_ t: Double) -> Int { asks.filter { $0.time <= t && $0.resolve > t }.count }
func pending(_ t: Double, win: Int) -> [Ask] { asks.filter { $0.win == win && $0.time <= t && $0.resolve > t } }

struct Win {
    let name: String
    let title: String
    let frame: CGRect
    let editor: Bool
    let base: Double          // initial stacking order
    let script: [String]
}

let wins: [Win] = [
    Win(name: "api", title: "api — claude", frame: CGRect(x: 150, y: 118, width: 820, height: 480), editor: false, base: 0.2,
        script: ["> add rate limiting to the login route", "⏺ Read(src/routes/auth.ts)", "  ⎿  Read 214 lines",
                 "⏺ Search(\"rateLimit\")", "  ⎿  Found 3 files", "✻ Thinking…", "⏺ Write(src/middleware/limit.ts)",
                 "  ⎿  Wrote 42 lines", "⏺ Update(src/routes/auth.ts)", "  ⎿  Updated with 18 additions",
                 "⏺ Bash(npm test)", "  ⎿  128 passed, 0 failed", "⏺ Bash(npm run migrate)", "  ⎿  2 migrations applied",
                 "⏺ Update(src/auth.ts)", "  ⎿  Updated with 7 additions", "⏺ Bash(npm test)", "  ⎿  131 passed, 0 failed",
                 "⏺ Login is now rate limited: 5 tries per minute.", "✻ Thinking…"]),
    Win(name: "web", title: "web — claude", frame: CGRect(x: 905, y: 78, width: 860, height: 470), editor: false, base: 0.3,
        script: ["> fix the flaky checkout test", "⏺ Read(tests/checkout.spec.ts)", "  ⎿  Read 96 lines",
                 "⏺ Bash(npx playwright test checkout)", "  ⎿  1 failed: timeout on #pay", "✻ Thinking…",
                 "⏺ Update(tests/checkout.spec.ts)", "  ⎿  Updated with 3 additions", "⏺ Bash(npx playwright test)",
                 "  ⎿  24 passed", "⏺ Bash(git commit -m \"Wait for #pay\")", "  ⎿  [main 4f2a91c]", "⏺ Bash(git push origin main)",
                 "  ⎿  main -> main", "⏺ Bash(npm run build)", "  ⎿  built in 8.2s", "⏺ The checkout test is stable now.",
                 "✻ Thinking…"]),
    Win(name: "docs", title: "docs — Editor", frame: CGRect(x: 262, y: 470, width: 900, height: 470), editor: true, base: 0.0,
        script: ["> update the setup guide", "⏺ Read(docs/setup.md)", "  ⎿  Read 58 lines", "✻ Thinking…",
                 "⏺ Update(docs/setup.md)", "  ⎿  Updated with 12 additions", "⏺ Bash(rm -rf build/)", "  ⎿  done",
                 "⏺ Fetch(docs.python.org)", "  ⎿  Received 41 KB", "⏺ The guide covers Python 3.13 now.", "✻ Thinking…"]),
    Win(name: "infra", title: "infra — claude", frame: CGRect(x: 1045, y: 420, width: 760, height: 470), editor: false, base: 0.1,
        script: ["> add a staging bucket", "⏺ Read(main.tf)", "  ⎿  Read 140 lines", "⏺ Update(main.tf)",
                 "  ⎿  Updated with 22 additions", "✻ Thinking…", "⏺ Bash(terraform plan)", "  ⎿  Plan: 2 to add",
                 "⏺ Bash(kubectl get pods)", "  ⎿  6 running", "⏺ Bash(aws s3 ls)", "  ⎿  4 buckets",
                 "⏺ Staging bucket is planned.", "✻ Thinking…"]),
]

/// Seconds each window has spent streaming (not waiting on a question) at frame f.
let activeTable: [[Double]] = wins.indices.map { wi in
    var acc = 0.0
    return (0...DFRAMES).map { f in
        let t = Double(f) / 60
        if f > 0 && pending(t, win: wi).isEmpty { acc += 1.0 / 60 }
        return acc
    }
}
func activeTime(_ wi: Int, _ t: Double) -> Double { activeTable[wi][min(DFRAMES, max(0, Int(t * 60)))] }

// MARK: - Cursor (problem act only)

let cursorPath: [(Double, CGFloat, CGFloat, Int?)] = [
    (0.0, 980, 760, nil), (0.9, 980, 760, nil), (1.35, 540, 520, 0), (1.85, 1320, 420, 1), (2.35, 1420, 760, 3),
    (2.85, 720, 820, 2), (3.25, 560, 520, 0), (3.65, 1330, 420, 1), (4.05, 1400, 790, 3),
]

func cursorPos(_ t: Double) -> CGPoint {
    for i in 1..<cursorPath.count {
        let a = cursorPath[i - 1], b = cursorPath[i]
        if t < b.0 {
            let p = CGFloat(smooth((t - a.0) / (b.0 - a.0)))
            return CGPoint(x: a.1 + (b.1 - a.1) * p, y: a.2 + (b.2 - a.2) * p)
        }
    }
    let l = cursorPath.last!
    return CGPoint(x: l.1, y: l.2)
}

func drawCursor(_ b: Board, _ t: Double) {
    guard t < 4.2 else { return }
    let p = cursorPos(t)
    // click ring right after arriving on a window
    for c in cursorPath where c.3 != nil && t >= c.0 && t < c.0 + 0.18 {
        let n = steps(t, from: c.0, 0.18, 3)
        let r = CGFloat(10 + n * 8)
        b.ctx.setStrokeColor(Ink.text.a(0.8)); b.ctx.setLineWidth(2)
        b.ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    let s: CGFloat = 1.6
    let pts: [CGPoint] = [(0, 0), (0, 17), (4, 13), (7, 20), (9.5, 19), (6.5, 12), (12, 12)].map {
        CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s)
    }
    let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
    b.ctx.addPath(path); b.ctx.setFillColor(rgb(0xFFFFFF)); b.ctx.fillPath()
    b.ctx.addPath(path); b.ctx.setStrokeColor(rgb(0x000000)); b.ctx.setLineWidth(1.4); b.ctx.strokePath()
}

/// Latest moment a window was brought to the front.
func zKey(_ wi: Int, _ t: Double) -> Double {
    var k = wins[wi].base
    for a in asks where a.win == wi && a.time <= t && t < 4.2 { k = max(k, a.time) }
    for c in cursorPath where c.3 == wi && c.0 <= t { k = max(k, c.0) }
    return k
}

// MARK: - Desktop chrome

func drawWallpaper(_ b: Board) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [rgb(0x3A332C), rgb(0x24211D), rgb(0x161514)] as CFArray, locations: [0, 0.55, 1])!
    b.ctx.drawLinearGradient(g, start: CGPoint(x: DW * 0.3, y: 0), end: CGPoint(x: DW * 0.7, y: DH), options: [])
    var y: CGFloat = 46
    while y < DH { var x: CGFloat = 12; while x < DW { b.fill(CGRect(x: x, y: y, width: 2, height: 2), rgb(0xFFFFFF, 0.035)); x += 24 }; y += 24 }
}

func clockText(_ t: Double) -> String {
    var m = 9 * 60 + 41
    if t >= 4.2 { m += min(56, Int((t - 4.2) / 0.7 * 56)) }
    if t >= 12.4 { m += 1 }
    return String(format: "Tue %d:%02d", m / 60, m % 60)
}

func drawMenuBar(_ b: Board, _ t: Double, count: Int? = nil, clock clockOverride: String? = nil) {
    b.fill(CGRect(x: 0, y: 0, width: DW, height: 30), rgb(0x0E0D0C, 0.6))
    drawGrid(b, ["###", "#.#", "###"], x: 20, y: 9, pitch: 4, cell: 3, ink: Ink.text)
    var x: CGFloat = 52
    x += b.text("Terminal", x, 6, 14, medium: true, Ink.text) + 24
    for m in ["Shell", "Edit", "View", "Window", "Help"] { x += b.text(m, x, 6, 14, Ink.text.a(0.85)) + 22 }
    let clock = clockOverride ?? clockText(t)
    let cw = Board.width(clock, 14)
    var rx = DW - 20 - cw
    b.text(clock, rx, 6, 14, Ink.text)
    rx -= 50
    b.strokeRound(CGRect(x: rx, y: 9, width: 26, height: 13), 3, 1.2, Ink.text.a(0.85))
    b.fill(CGRect(x: rx + 3, y: 12, width: 15, height: 7), Ink.text.a(0.85))
    let n = count ?? (t < 12.0 ? pendingCount(t) : 0)
    if n > 0 {
        let s = "\(n)"
        let sw = Board.width(s, 14, medium: true)
        rx -= 24 + sw
        b.fill(CGRect(x: rx, y: 11, width: 9, height: 9), Ink.orange)
        b.text(s, rx + 15, 6, 14, medium: true, Ink.orange)
    }
}

func drawDock(_ b: Board, _ t: Double, bouncing: Bool? = nil) {
    let icons: [(UInt32, String, CGColor)] = [
        (0x3D7CC9, "▤", rgb(0xFFFFFF)), (0x1C1B1A, ">_", Ink.text), (0x2D63A8, "{ }", rgb(0xFFFFFF)),
        (0xE9E3D9, "◎", rgb(0x3D7CC9)), (0xE7C35E, "≡", rgb(0x5A4A1E)), (0x6F6A64, "⌫", rgb(0xFFFFFF)),
    ]
    let s: CGFloat = 62, gap: CGFloat = 14, pad: CGFloat = 12
    let w = CGFloat(icons.count) * s + CGFloat(icons.count - 1) * gap + 2 * pad
    let plate = CGRect(x: (DW - w) / 2, y: DH - s - 2 * pad - 8, width: w, height: s + 2 * pad)
    b.fillRound(plate, 22, rgb(0x2A2825, 0.8))
    b.strokeRound(plate, 22, 1, Ink.border)
    for (i, ic) in icons.enumerated() {
        var y = plate.minY + pad
        if i == 1 && (bouncing ?? (t >= 1.0 && t < 4.2)) {
            let ph = (t - 1.0).truncatingRemainder(dividingBy: 0.5) / 0.5
            y -= CGFloat((sin(Double.pi * ph) * 5).rounded()) * 6
        }
        let r = CGRect(x: plate.minX + pad + CGFloat(i) * (s + gap), y: y, width: s, height: s)
        b.fillRound(r, 14, rgb(ic.0))
        b.strokeRound(r, 14, 1, rgb(0x000000, 0.25))
        let gw = Board.width(ic.1, 22, medium: true)
        b.text(ic.1, r.midX - gw / 2, r.midY - Board.lineH(22, medium: true) / 2, 22, medium: true, ic.2)
        if i == 1 || i == 2 { b.fill(CGRect(x: r.midX - 2, y: plate.maxY - 7, width: 4, height: 4), Ink.text.a(0.8)) }
    }
}

// MARK: - Windows

let TS: CGFloat = 16          // terminal font size
let TLH: CGFloat = 25         // terminal line height

func lineColor(_ s: String) -> CGColor {
    if s.hasPrefix("⏺") { return Ink.text }
    return Ink.muted
}

/// What a window shows. The desktop video derives it from its ask table; other scenes pass their own.
struct WinState {
    var waiting: [Ask]
    var active: Double          // seconds spent streaming (drives how many lines are out)
    var handed = false          // its question now lives in Nudge: block goes quiet
    var alert = false           // orange edge
    var fresh = false           // a question just arrived: thick edge
    var blockLines = 5          // lines of the question block typed so far
    var cursor = false          // block cursor after the last typed line
    var blockChars = Int.max    // characters of the block typed so far (typing effect)
}

func desktopState(_ wi: Int, _ t: Double) -> WinState {
    let waiting = pending(t, win: wi)
    return WinState(waiting: waiting, active: activeTime(wi, t), handed: t >= 7.0,
                    alert: !waiting.isEmpty && t < 7.0, fresh: waiting.contains { t - $0.time < 0.12 })
}

func drawTerm(_ b: Board, _ wi: Int, _ r: CGRect, _ t: Double, _ st: WinState) {
    let w = wins[wi]
    let waiting = st.waiting
    b.ctx.saveGState()
    b.ctx.clip(to: r)
    let blockH: CGFloat = 5 * TLH + 22
    let linesH = r.height - (waiting.isEmpty ? 0 : blockH + 10)
    let fit = max(1, Int(linesH / TLH))
    let n = 3 + Int(st.active * 4.5)
    let first = max(0, n - fit)
    for i in first..<n {
        let s = w.script[i % w.script.count]
        b.text(s, r.minX, r.minY + CGFloat(i - first) * TLH, TS, medium: s.hasPrefix("⏺"), lineColor(s))
    }
    if let a = waiting.first {
        let handed = st.handed
        let br = CGRect(x: r.minX, y: r.minY + linesH + 10, width: r.width, height: blockH)
        b.strokeRound(br, 8, 2, handed ? Ink.border : Ink.orange)
        let x = br.minX + 16
        var y = br.minY + 11
        let head = a.tool == "Bash" ? "Bash command" : a.tool == "Edit" ? "Edit file" : "Fetch"
        let lines: [(String, Bool, CGColor)] = [
            (head, true, handed ? Ink.muted : Ink.text), ("  " + a.command, false, handed ? Ink.muted : Ink.text),
            ("Do you want to proceed?", false, Ink.muted), ("❯ 1. Yes", true, handed ? Ink.muted : Ink.text),
            ("  2. No", false, Ink.muted),
        ]
        var lastX = x, lastY = y, budget = st.blockChars
        for (s, med, c) in lines.prefix(st.blockLines) where budget > 0 {
            let shown = String(s.prefix(budget))
            budget -= s.count
            lastX = x + b.text(shown, x, y, TS, medium: med, c); lastY = y; y += TLH
        }
        if st.cursor { b.fill(CGRect(x: lastX + 4, y: lastY + 4, width: 10, height: TLH - 8), Ink.text) }
    }
    b.ctx.restoreGState()
}

func drawWindow(_ b: Board, _ wi: Int, _ t: Double, _ state: WinState? = nil) {
    let w = wins[wi], r = w.frame
    let st = state ?? desktopState(wi, t)
    let waiting = st.waiting
    b.fillRound(r.offsetBy(dx: 0, dy: 16), 12, rgb(0x000000, 0.32))
    b.fillRound(r, 12, rgb(0x1B1A18))
    b.ctx.saveGState()
    b.ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); b.ctx.clip()
    b.fill(CGRect(x: r.minX, y: r.minY, width: r.width, height: 38), rgb(0x2A2825))
    b.fill(CGRect(x: r.minX, y: r.minY + 38, width: r.width, height: 1), Ink.border)
    b.ctx.restoreGState()
    for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        b.fillRound(CGRect(x: r.minX + 16 + CGFloat(i) * 22, y: r.minY + 13, width: 12, height: 12), 6, rgb(c))
    }
    let tw = Board.width(w.title, 15)
    b.text(w.title, r.midX - tw / 2, r.minY + 9, 15, Ink.muted)
    // one cell per waiting question
    for i in 0..<waiting.count {
        b.fill(CGRect(x: r.maxX - 26 - CGFloat(i) * 14, y: r.minY + 15, width: 9, height: 9), st.handed ? Ink.muted : Ink.orange)
    }

    var term = CGRect(x: r.minX + 22, y: r.minY + 54, width: r.width - 44, height: r.height - 70)
    if w.editor {
        let side = CGRect(x: r.minX, y: r.minY + 39, width: 180, height: r.height - 39)
        b.ctx.saveGState()
        b.ctx.addPath(CGPath(roundedRect: r, cornerWidth: 12, cornerHeight: 12, transform: nil)); b.ctx.clip()
        b.fill(side, rgb(0x151413))
        b.ctx.restoreGState()
        b.fill(CGRect(x: side.maxX, y: side.minY, width: 1, height: side.height), Ink.border)
        for (i, f) in ["DOCS", "  setup.md", "  api.md", "SRC", "  index.ts", "  auth.ts", "README.md"].enumerated() {
            b.text(f, side.minX + 18, side.minY + 16 + CGFloat(i) * 26, 14, medium: f == "  setup.md", f == "  setup.md" ? Ink.text : Ink.muted)
        }
        let codeX = side.maxX + 22
        let code = ["# Setup", "", "1. Install dependencies:  npm install", "2. Copy .env.example to .env"]
        for (i, l) in code.enumerated() {
            b.text(l, codeX, r.minY + 56 + CGFloat(i) * 24, 15, medium: i == 0, i == 0 ? Ink.text : Ink.muted)
        }
        let panelY = r.minY + 56 + 4 * 24 + 10
        b.fill(CGRect(x: side.maxX, y: panelY, width: r.maxX - side.maxX, height: 1), Ink.border)
        b.text("TERMINAL", codeX, panelY + 8, 12, medium: true, Ink.muted, kern: 1)
        term = CGRect(x: codeX, y: panelY + 34, width: r.maxX - codeX - 22, height: r.maxY - panelY - 46)
    }
    drawTerm(b, wi, term, t, st)
    b.strokeRound(r, 12, st.alert ? (st.fresh ? 6 : 3) : 1, st.alert ? Ink.orange : Ink.border)
}

// MARK: - Overlays

func cellOverlay(_ b: Board, cell: CGFloat, _ c: CGColor, seed: Int, on: (Double) -> Bool) {
    let nx = Int(ceil(DW / cell)), ny = Int(ceil(DH / cell))
    for j in 0..<ny { for i in 0..<nx where on(hash01(i, j, seed)) {
        b.fill(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell), c)
    } }
}

/// Orange cells leave every waiting window's edge and fly into the pill.
func drawHandoff(_ b: Board, _ t: Double, target: CGPoint) {
    guard t >= 7.0 && t < 7.5 else { return }
    for (wi, w) in wins.enumerated() where !pending(7.0, win: wi).isEmpty {
        let r = w.frame
        var pts: [CGPoint] = []
        var x = r.minX; while x < r.maxX { pts.append(CGPoint(x: x, y: r.minY)); pts.append(CGPoint(x: x, y: r.maxY)); x += 80 }
        var y = r.minY + 80; while y < r.maxY { pts.append(CGPoint(x: r.minX, y: y)); pts.append(CGPoint(x: r.maxX, y: y)); y += 80 }
        for (i, s) in pts.enumerated() {
            let p = clamp01((t - 7.0 - hash01(wi, i, 21) * 0.12) / 0.3)
            guard p < 1 else { continue }
            let q = CGFloat((p * 10).rounded(.down) / 10)
            let e = q * q
            b.fill(CGRect(x: s.x + (target.x - s.x) * e - 5, y: s.y + (target.y - s.y) * e - 5, width: 10, height: 10), Ink.orange)
        }
    }
}

func desktopPill(_ t: Double) -> Pill? {
    guard t >= 6.0 else { return nil }
    var icons: [Glyph] = []
    if t >= 6.45 {
        var eye = Glyph(rows: Eye.open)
        if t < 6.67 { eye.show = { r, c in t >= 6.45 + hash01(r, c, 7) * 0.22 } }
        for b0 in [6.82, 7.12] {
            if t >= b0 && t < b0 + 0.05 { eye.rows = Eye.half }
            if t >= b0 + 0.05 && t < b0 + 0.14 { eye.rows = Eye.closed }
        }
        icons.append(eye)
    }
    if t >= 10.62 && t < 11.0 {
        let n = Int((t - 10.62) / 0.026) + 1
        let lit = Set(checkStroke.prefix(n).map { $0.0 * 10 + $0.1 })
        var g = Glyph(rows: MatrixFrames.check.still)
        g.show = { r, c in lit.contains(r * 10 + c) }
        if t >= 10.90 && t < 10.98 { g.lift = -1 }
        icons.append(g)
    }
    if t >= 11.0 {
        var g = Glyph(rows: MatrixFrames.bolt.still)
        let rowsOn = Int((t - 11.0) / 0.04) + 1
        g.show = { r, _ in r < rowsOn }
        icons.append(g)
    }
    if t >= 12.2 { return .working(t, icons: icons) }
    if t >= 11.15 { return .approving(t - 11.15, icons: icons) }
    if t >= 7.42 { return .asks(t - 7.42, count: pendingCount(t), icons: icons) }
    return .working(t, icons: icons)
}

func drawDesktopCard(_ b: Board, _ t: Double, pillBottom: CGFloat) {
    guard t >= cardStart[0] && t < 9.72 else { return }
    let i = t < cardStart[1] ? 0 : t < cardStart[2] ? 1 : 2
    let a = asks[i]
    var card = Card(session: wins[a.win].name, time: "10:37", tool: a.tool, command: a.command)
    let st = cardStamp[i]
    if t >= st {
        card.stampFrame = min(3, Int((t - st) / 0.08))
        card.stampChars = max(0, Int((t - st - 0.04) * 50))
    } else if t >= st - 0.12 { card.hover = 0 }
    let k = DCARD_K
    let w = card.width * k, h = card.height(k)
    let x = ((DW - w) / 2).rounded(), y = pillBottom + 22
    var frac = CGFloat(steps(t, from: cardStart[0], 0.18, 8)) / 8
    if t >= 9.52 { frac = CGFloat(8 - steps(t, from: 9.52, 0.18, 8)) / 8 }
    guard frac > 0 else { return }
    b.fillRound(CGRect(x: x, y: y + 14, width: w, height: h * frac), Theme.radius * k, rgb(0x000000, 0.3))
    b.ctx.saveGState()
    b.ctx.clip(to: CGRect(x: x - 4, y: y - 4, width: w + 8, height: h * frac + 4))
    let hint = card.draw(b, x: x, y: y, k: k, lw: 2)
    b.ctx.restoreGState()
    if frac < 1 { b.fill(CGRect(x: x, y: y + h * frac - 2, width: w, height: 2), Ink.muted) }

    // ⌘↩ keycap: appears, presses at the stamp, leaves
    let appear = st - (i == 0 ? 0.32 : 0.2)
    guard t >= appear && t < st + 0.16, frac == 1 else { return }
    let ks = k / 2.05
    let kw = 132 * ks, kh = 112 * ks, depth = 10 * ks
    let kx = hint.midX - kw / 2 + 18 * ks, ky = hint.midY - kh / 2 + 6 * ks
    let pressed = t >= st - 0.12 && t < st + 0.02
    b.ctx.saveGState()
    cellClip(b, CGRect(x: kx, y: ky, width: kw, height: kh + depth), cell: 10) { ci, cj, _, _ in
        let hh = hash01(ci, cj, 3 + i)
        if t >= st + 0.06 { return t < st + 0.06 + hh * 0.1 }
        return t >= appear + hh * 0.1
    }
    b.fillRound(CGRect(x: kx, y: ky + depth, width: kw, height: kh), 12, Ink.border)
    let top = CGRect(x: kx, y: ky + (pressed ? depth : 0), width: kw, height: kh)
    b.fillRound(top, 12, Ink.surface)
    b.strokeRound(top, 12, 2, pressed ? Ink.text : Ink.muted)
    let label = "⌘↩", fs = 40 * ks
    let lw = Board.width(label, fs, medium: true)
    b.text(label, top.midX - lw / 2, top.midY - Board.lineH(fs, medium: true) / 2, fs, medium: true, Ink.text)
    b.ctx.restoreGState()
}

func drawDesktopFingerprint(_ b: Board, _ t: Double, pillBottom: CGFloat) {
    guard t >= 9.72 && t < 10.66 else { return }
    let pitch: CGFloat = 14, cell: CGFloat = 10
    let gs = gridSize(fingerprint, pitch: pitch, cell: cell)
    let lh = Board.lineH(20, medium: true)
    let plate = CGRect(x: (DW - gs.width) / 2 - 44, y: pillBottom + 30, width: gs.width + 88, height: gs.height + 56 + lh + 18)
    let x = plate.minX + 44, y = plate.minY + 32
    b.ctx.saveGState()
    cellClip(b, plate.insetBy(dx: -2, dy: -2), cell: 16) { i, j, _, _ in
        let h = hash01(i, j, 17)
        if t >= 10.52 { return t < 10.52 + h * 0.12 }
        return t >= 9.72 + h * 0.1
    }
    b.fillRound(plate, Theme.radius * DCARD_K, Ink.surface)
    b.strokeRound(plate, Theme.radius * DCARD_K, 2, Ink.muted)
    func dist(_ r: Int, _ c: Int) -> Double {
        let dx = Double(c) - 6, dy = (Double(r) - 7) * 0.82
        return (dx * dx + dy * dy).squareRoot()
    }
    let rows = fingerprint.enumerated().map { (r, row) -> String in
        String(row.enumerated().map { (c, ch) -> Character in ch == "#" && t < 9.86 + dist(r, c) / 7 * 0.5 ? "o" : ch })
    }
    drawGrid(b, rows, x: x, y: y, pitch: pitch, cell: cell, ink: Ink.text)
    let label = t >= 10.38 ? "TOUCH ID ✓" : String("TOUCH ID".prefix(max(0, Int((t - 9.86) * 40))))
    let lw = Board.width("TOUCH ID ✓", 20, medium: true)
    b.text(label, plate.midX - lw / 2, y + gs.height + 20, 20, medium: true, t >= 10.38 ? Ink.text : Ink.muted, kern: 1)
    b.ctx.restoreGState()
}

/// One short caption at a time, bottom centre, typed in.
typealias CaptionTable = [((Double) -> String, Double, Double)]
let desktopCaptions: CaptionTable = [
    ({ t in "\(pendingCount(t)) QUESTIONS" }, 1.55, 4.2),
    ({ _ in "WAITING" }, 4.45, 6.0),
    ({ _ in "ONE PILL" }, 7.5, 12.2),
]

func drawCaption(_ b: Board, _ t: Double, _ caps: CaptionTable = desktopCaptions) {
    guard let c = caps.first(where: { t >= $0.1 && t < $0.2 }) else { return }
    let full = c.0(t)
    let size: CGFloat = 38
    let typed = min(full.count, Int((t - c.1) * 30) + 1)
    let s = String(full.prefix(typed))
    let lh = Board.lineH(size, medium: true)
    let fw = Board.width(full, size, medium: true) + CGFloat(full.count) * 3
    let r = CGRect(x: ((DW - fw) / 2 - 32).rounded(), y: 870, width: fw + 64, height: lh + 36)
    b.fillRound(r, 12, Ink.surface)
    b.strokeRound(r, 12, 2, Ink.border)
    let x = r.minX + 32 + b.text(s, r.minX + 32, r.minY + 18, size, medium: true, Ink.text, kern: 3)
    if typed < full.count {
        b.fill(CGRect(x: x + 3, y: r.minY + 18 + lh * 0.18, width: Board.width("M", size) * 0.62, height: lh * 0.64), Ink.text)
    }
}

func drawDesktopEnd(_ b: Board, _ t: Double) {
    guard t >= 14.3 else { return }
    // a plate behind the text only; the desktop keeps working around it
    let plate = CGRect(x: (DW - 900) / 2, y: 220, width: 900, height: 690)
    b.ctx.saveGState()
    cellClip(b, plate, cell: 30) { i, j, _, _ in t >= 14.3 + hash01(i, j, 33) * 0.15 }
    b.fillRound(plate, 18, Ink.surface.a(0.92))
    b.strokeRound(plate, 18, 2, Ink.border)
    b.ctx.restoreGState()
    guard t >= 14.45 else { return }
    let pitch: CGFloat = 22, cell: CGFloat = 16
    let rows = MatrixFrames.orbit.rows(at: max(0, t - 14.65))
    let gs = gridSize(rows, pitch: pitch, cell: cell)
    let oy: CGFloat = 270
    drawGrid(b, rows, x: (DW - gs.width) / 2, y: oy, pitch: pitch, cell: cell, ink: Ink.orange) { r, c in
        t >= 14.45 + hash01(r, c, 13) * 0.18
    }
    func typed(_ s: String, from a: Double, rate: Double) -> String { String(s.prefix(t < a ? 0 : Int((t - a) * rate) + 1)) }
    let name = "Nudge"
    let nw = Board.width(name, 132, medium: true)
    let ny = oy + gs.height + 40
    b.text(typed(name, from: 14.67, rate: 36), (DW - nw) / 2, ny, 132, medium: true, Ink.text)
    let sub = "Answer Claude Code from a floating pill"
    let sw = Board.width(sub, 32)
    let sy = ny + Board.lineH(132, medium: true) + 18
    b.text(typed(sub, from: 14.85, rate: 140), (DW - sw) / 2, sy, 32, Ink.muted)
    if t >= 15.15 {
        let rw: CGFloat = 120, n = steps(t, from: 15.15, 0.08, 6)
        b.fill(CGRect(x: (DW - rw) / 2, y: sy + Board.lineH(32) + 34, width: rw * CGFloat(n) / 6, height: 2), Ink.border)
    }
    let url = "github.com/ulvosama/nudge"
    let uw = Board.width(url, 32, medium: true)
    b.text(typed(url, from: 15.21, rate: 120), (DW - uw) / 2, sy + Board.lineH(32) + 70, 32, medium: true, Ink.text)
    let foot = "macOS · free & open source"
    let fw = Board.width(foot, 22)
    b.text(typed(foot, from: 15.4, rate: 140), (DW - fw) / 2, sy + Board.lineH(32) + 70 + Board.lineH(32) + 18, 22, Ink.muted)
}

// MARK: - Frame

func renderDesktop(_ b: Board, _ t: Double) {
    b.clear(rgb(0x161514))
    drawWallpaper(b)
    for wi in wins.indices.sorted(by: { zKey($0, t) < zKey($1, t) }) { drawWindow(b, wi, t) }
    drawDock(b, t)
    drawMenuBar(b, t)
    drawCursor(b, t)
    // sleep, focus and end dims: cells switch between darkness levels
    let cell: CGFloat = 40
    for j in 0..<Int(ceil(DH / cell)) { for i in 0..<Int(ceil(DW / cell)) {
        let d = cellDark(hash01(i, j, 41), t)
        if d > 0 { b.fill(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell), rgb(0x000000, d)) }
    } }
    // the windows an answer just reached, lifted out of the dim
    for wi in wins.indices.sorted(by: { zKey($0, t) < zKey($1, t) }) where spotlit(wi, t) { drawWindow(b, wi, t) }
    let top = pillTop(t)
    var pillBottom = top
    var pillCenter = CGPoint(x: DW / 2, y: top + 40)
    if let pill = desktopPill(t) {
        let ps = pill.size(DK)
        let px = ((DW - ps.width) / 2).rounded()
        pillBottom = top + ps.height
        pillCenter = CGPoint(x: DW / 2, y: top + ps.height / 2)
        b.ctx.saveGState()
        let rect = CGRect(x: px - 2, y: top - 2, width: ps.width + 4, height: ps.height + 4)
        if t < 6.4 {
            cellClip(b, rect, cell: 10) { i, j, nx, _ in t >= 6.02 + Double(i) / Double(nx) * 0.24 + hash01(i, j, 2) * 0.1 }
        }
        b.fillRound(rect.offsetBy(dx: 0, dy: 10), Theme.radius * DK, rgb(0x000000, 0.3))
        pill.draw(b, x: px, y: top, k: DK, lw: 2)
        b.ctx.restoreGState()
    }
    drawHandoff(b, t, target: pillCenter)
    drawDesktopCard(b, t, pillBottom: pillBottom)
    drawDesktopFingerprint(b, t, pillBottom: pillBottom)
    drawCaption(b, t)
    drawDesktopEnd(b, t)
}
