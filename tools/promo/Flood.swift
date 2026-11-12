import AppKit
import SwiftUI

// Video 3, "hundreds of questions": 1920×1080, 60 fps, 21.0 s. Compiled with Promo.swift,
// Desktop.swift (desktop chrome, windows, captions, end card) and tools/brand/Kit.swift.
//
//   promo flood                  raw RGBA frames on stdout (1260 frames)
//   promo still-flood <t> <png>  one frame
//
//   0.0–3.0   focus      close-up: Claude types one permission question
//   3.0–3.6   pull back  stepped zoom out to the desktop
//   3.6–8.4   flood      243 more questions pop in, faster and faster; counter → 247; freeze
//   8.4–9.8   arrival    screen dims, the pill builds in at centre, a ripple of cells
//   9.8–13.6  flow       right-click → menu → Auto-approve… → 4h → Quick → Turn on… → Touch ID
//   13.6–16.6 clear      APPROVING; a wave from the pill stamps and removes every question
//   16.6–18.0 calm       pill steps up to its home, every session works
//   18.0–21.0 end card   over the working desktop

let FFRAMES = 1260
let FK: CGFloat = 3.4               // pill scale
let FPILL_Y: CGFloat = 228          // pill top at centre stage
let FUI_K: CGFloat = 2.1            // menu / Auto window scale
let FTOTAL = 247
let WAVE0 = 13.7, WAVE_LEN = 2.4

// MARK: - Data

struct FloodAsk {
    let session: String
    let tool: String
    let command: String
    let rect: CGRect
    let spawn: Double
    var clear: Double
}

let floodSessions = ["api", "web", "docs", "infra", "mobile", "auth", "billing", "ml", "search", "admin", "cli",
                     "worker", "ios", "android", "data", "edge", "notify", "reports"]
let floodCommands: [(String, String)] = [
    ("Bash", "npm test"), ("Bash", "git push origin main"), ("Bash", "rm -rf build/"), ("Bash", "terraform apply"),
    ("Edit", "src/auth.ts"), ("Bash", "npm install"), ("Bash", "docker compose up"), ("Fetch", "api.github.com"),
    ("Bash", "pytest -q"), ("Edit", "package.json"), ("Bash", "kubectl rollout restart"), ("Bash", "git rebase main"),
    ("Write", "migrations/042.sql"), ("Bash", "cargo build --release"), ("Bash", "npx prisma migrate"),
    ("Edit", "README.md"), ("Bash", "make deploy"), ("Bash", "aws s3 sync dist/"), ("Bash", "pnpm lint --fix"),
    ("Edit", "infra/main.tf"),
]

let MINI = CGSize(width: 300, height: 122)
let floodPillCenter = CGPoint(x: DW / 2, y: FPILL_Y + 48)
let waveMax: CGFloat = {
    let c = floodPillCenter
    return [CGPoint(x: 0, y: 0), CGPoint(x: DW, y: 0), CGPoint(x: 0, y: DH), CGPoint(x: DW, y: DH)]
        .map { hypot($0.x - c.x, $0.y - c.y) }.max()!
}()
func waveTime(_ p: CGPoint) -> Double {
    WAVE0 + Double(hypot(p.x - floodPillCenter.x, p.y - floodPillCenter.y) / waveMax) * WAVE_LEN
}

let floodAsks: [FloodAsk] = {
    let n = FTOTAL - 4
    return (0..<n).map { i in
        let x = 24 + CGFloat(hash01(i, 1, 77)) * (DW - MINI.width - 48)
        let y = 44 + CGFloat(hash01(i, 2, 77)) * (900 - MINI.height - 44)
        let r = CGRect(x: x.rounded(), y: y.rounded(), width: MINI.width, height: MINI.height)
        let c = floodCommands[Int(hash01(i, 3, 77) * Double(floodCommands.count))]
        let spawn = 3.6 + 3.9 * pow(Double(i + 1) / Double(n), 0.45)
        return FloodAsk(session: floodSessions[Int(hash01(i, 4, 77) * Double(floodSessions.count))],
                        tool: c.0, command: c.1, rect: r, spawn: spawn,
                        clear: waveTime(CGPoint(x: r.midX, y: r.midY)))
    }
}()

/// The four windows' own questions (window 0 is the one typed in the close-up).
let floodWinAsks: [Ask] = [(0, "Bash", "npm test"), (1, "Bash", "git push origin main"), (2, "Edit", "docs/setup.md"),
                           (3, "Bash", "terraform apply")].map { wi, tool, cmd in
    let f = wins[wi].frame
    return Ask(time: wi == 0 ? 1.05 : 0.8, win: wi, tool: tool, command: cmd, resolve: waveTime(CGPoint(x: f.midX, y: f.midY)))
}

func floodCount(_ t: Double) -> Int {
    guard t >= 0.0 else { return 0 }
    let win = floodWinAsks.filter { t >= max($0.time, 2.6) && t < $0.resolve }.count
    let minis = floodAsks.filter { t >= $0.spawn && t < $0.clear + 0.14 }.count
    return win + minis
}

func floodClock(_ t: Double) -> String {
    var m = 9 * 60 + 41
    if t >= 3.6 { m += Int(min(1, (t - 3.6) / 3.9) * 131) }
    if t >= 17.0 { m += 1 }
    return String(format: "Tue %d:%02d", m / 60, m % 60)
}

// MARK: - Close-up typing (window 0)

let typedLead = 1.15, typeRate = 42.0
let blockText = ["Bash command", "  npm test", "Do you want to proceed?", "❯ 1. Yes", "  2. No"]
let blockTotal = blockText.map(\.count).reduce(0, +)
let typedDone = typedLead + Double(blockTotal) / typeRate      // ≈ 2.4 s

func floodWinState(_ wi: Int, _ t: Double) -> WinState {
    let a = floodWinAsks[wi]
    let askAt = wi == 0 ? a.time : 0.8
    let waiting = t >= askAt && t < a.resolve
    let active = min(t, askAt) + max(0, t - a.resolve)
    var st = WinState(waiting: waiting ? [a] : [], active: active)
    st.handed = t >= 9.0
    st.alert = waiting && t < 9.0 && (wi != 0 || t >= typedDone)
    st.fresh = wi == 0 && t >= typedDone && t < typedDone + 0.14
    if wi == 0 && t < typedDone {
        st.blockChars = max(0, Int((t - typedLead) * typeRate))
        st.cursor = Int(t * 4) % 2 == 0 || t >= typedLead
    }
    return st
}

// MARK: - Mini question block

func drawMiniAsk(_ b: Board, _ a: FloodAsk, _ i: Int, _ t: Double) {
    guard t >= a.spawn, t < a.clear + 0.26 else { return }
    let r = a.rect
    b.ctx.saveGState()
    if t < a.spawn + 0.08 {
        cellClip(b, r.insetBy(dx: -4, dy: -4), cell: 14) { ci, cj, _, _ in t >= a.spawn + hash01(ci, cj, i) * 0.08 }
    } else if t >= a.clear + 0.14 {
        cellClip(b, r.insetBy(dx: -4, dy: -4), cell: 14) { ci, cj, _, _ in t < a.clear + 0.14 + hash01(ci, cj, i + 7) * 0.12 }
    }
    b.fillRound(r.offsetBy(dx: 0, dy: 8), 10, rgb(0x000000, 0.35))
    b.fillRound(r, 10, rgb(0x1B1A18))
    let handed = t >= 9.0
    let fresh = t < a.spawn + 0.12
    b.strokeRound(r, 10, fresh ? 4 : 2, handed ? Ink.border : Ink.orange)
    let x = r.minX + 16
    var y = r.minY + 12
    b.fill(CGRect(x: x, y: y + 5, width: 8, height: 8), handed ? Ink.muted : Ink.orange)
    b.text(a.session.uppercased(), x + 16, y, 13, medium: true, Ink.muted, kern: 1)
    y += 24
    let head = a.tool == "Bash" ? "Bash command" : a.tool == "Edit" ? "Edit file" : a.tool == "Write" ? "Write file" : "Fetch"
    b.text(head, x, y, 15, medium: true, handed ? Ink.muted : Ink.text); y += 22
    b.text("  " + a.command, x, y, 15, handed ? Ink.muted : Ink.text); y += 24
    b.text("❯ 1. Yes   2. No", x, y, 15, medium: true, handed ? Ink.muted : Ink.text)
    // the wave's stamp, top right
    if t >= a.clear {
        drawStamp(b, center: CGPoint(x: r.maxX - 24, y: r.minY + 21), side: 14, frame: min(3, Int((t - a.clear) / 0.035)),
                  ink: Ink.text, lw: 2)
    }
    b.ctx.restoreGState()
}

// MARK: - Ripple

func drawRipple(_ b: Board, _ t: Double, center c: CGPoint) {
    guard t >= 8.95 && t < 9.95 else { return }
    let cell: CGFloat = 24
    let r0 = CGFloat(t - 8.95) * 2300
    let rings: [(CGFloat, CGColor)] = [(r0, Ink.orange), (r0 - 90, Ink.muted.a(0.8)), (r0 - 180, Ink.off)]
    for j in 0..<Int(DH / cell) + 1 { for i in 0..<Int(DW / cell) + 1 {
        let p = CGPoint(x: CGFloat(i) * cell + cell / 2, y: CGFloat(j) * cell + cell / 2)
        let d = hypot(p.x - c.x, (p.y - c.y) * 1.3)
        for (rr, col) in rings where rr > 0 && abs(d - rr) < 16 {
            b.fill(CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14), col)
            break
        }
    } }
}

/// The clearing wave's front: a ring of light cells travelling out from the pill.
func drawWaveFront(_ b: Board, _ t: Double) {
    guard t >= WAVE0 && t < WAVE0 + WAVE_LEN + 0.1 else { return }
    let cell: CGFloat = 24
    let r = CGFloat((t - WAVE0) / WAVE_LEN) * waveMax
    let c = floodPillCenter
    for j in 0..<Int(DH / cell) + 1 { for i in 0..<Int(DW / cell) + 1 {
        let p = CGPoint(x: CGFloat(i) * cell + cell / 2, y: CGFloat(j) * cell + cell / 2)
        let d = hypot(p.x - c.x, p.y - c.y)
        if abs(d - r) < 14 { b.fill(CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12), Ink.text.a(0.85)) }
        else if abs(d - (r - 60)) < 12 { b.fill(CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12), Ink.off) }
    } }
}

// MARK: - Nudge menu (src/App.swift menu, in the shell language)

struct MenuRow { let title: String; var checked = false; var key = ""; var sep = false; var header = false }
let nudgeMenu: [MenuRow] = [
    MenuRow(title: "NUDGE  ·  18 SESSIONS  ·  247 ASKS", header: true), MenuRow(title: "", sep: true),
    MenuRow(title: "Show sessions"), MenuRow(title: "Jump to question", key: "⌃⌥J"), MenuRow(title: "", sep: true),
    MenuRow(title: "Answer from Nudge", checked: true), MenuRow(title: "Auto-approve…"),
    MenuRow(title: "Lock screen while asking"), MenuRow(title: "Stay awake while working on power", checked: true),
    MenuRow(title: "", sep: true), MenuRow(title: "Export permissions…"),
]
let menuTarget = 6

/// Draws the menu with its top-left at `o`; returns each row's rect.
@discardableResult
func drawNudgeMenu(_ b: Board, o: CGPoint, k: CGFloat, hover: Int?, draw: Bool = true) -> [CGRect] {
    let w: CGFloat = 330 * k, rowH: CGFloat = 22 * k, sepH: CGFloat = 11 * k, pad: CGFloat = 5 * k
    var rects: [CGRect] = []
    var y = o.y + pad
    for row in nudgeMenu {
        let h = row.sep ? sepH : rowH
        rects.append(CGRect(x: o.x + pad, y: y, width: w - 2 * pad, height: h))
        y += h
    }
    guard draw else { return rects }
    let frame = CGRect(x: o.x, y: o.y, width: w, height: y + pad - o.y)
    b.fillRound(frame.offsetBy(dx: 0, dy: 12), 8 * k, rgb(0x000000, 0.4))
    b.fillRound(frame, 8 * k, rgb(0x2A2825))
    b.strokeRound(frame, 8 * k, 2, Ink.border)
    for (i, row) in nudgeMenu.enumerated() {
        let r = rects[i]
        if row.sep { b.fill(CGRect(x: r.minX + 6 * k, y: r.midY, width: r.width - 12 * k, height: 2), Ink.border); continue }
        if hover == i { b.fillRound(r, 4 * k, Ink.border) }
        let size: CGFloat = (row.header ? 11 : 13) * k
        let ty = r.midY - Board.lineH(size, medium: row.header) / 2
        if row.checked { b.text("✓", r.minX + 6 * k, ty, size, Ink.text) }
        b.text(row.title, r.minX + 22 * k, ty, size, medium: row.header || hover == i, row.header ? Ink.muted : Ink.text)
        if !row.key.isEmpty {
            let kw = Board.width(row.key, size)
            b.text(row.key, r.maxX - 10 * k - kw, ty, size, Ink.muted)
        }
    }
    return rects
}

// MARK: - Auto-approve window (src/Export.swift AutoApproveView)

struct AutoLayout {
    var frame = CGRect.zero
    var hourChips: [CGRect] = []
    var speedChips: [CGRect] = []
    var cancel = CGRect.zero
    var turnOn = CGRect.zero
}

let autoHours = [1, 2, 4, 6, 24]

@discardableResult
func drawAutoWindow(_ b: Board, center cx: CGFloat, top: CGFloat, k: CGFloat, hours: Int, quick: Bool, busy: Bool,
                    hover: CGRect? = nil, draw: Bool = true) -> AutoLayout {
    var L = AutoLayout()
    let margin: CGFloat = 20, content: CGFloat = 300, titleH: CGFloat = 28
    let W = (content + 2 * margin) * k
    let x0 = (cx - W / 2).rounded()
    let px = x0 + margin * k
    let l12 = Board.lineH(12 * k), l12m = Board.lineH(12 * k, medium: true)
    var y = top + titleH * k + 8 * k
    let textY = y
    y += 2 * l12 + 12 * k
    func chips(_ titles: [String], on: Int, at yy: CGFloat) -> [CGRect] {
        var xx = px - 8 * k
        return titles.enumerated().map { i, s in
            let w = Board.width(s, 12 * k, medium: i == on) + 16 * k
            defer { xx += w + 4 * k }
            return CGRect(x: xx, y: yy, width: w, height: 26 * k)
        }
    }
    let hourTitles = autoHours.map { "\($0)h" }
    let hOn = autoHours.firstIndex(of: hours) ?? 1
    L.hourChips = chips(hourTitles, on: hOn, at: y); y += 26 * k + 4 * k
    let speedTitles = ["Normal 15s", "Quick <1s"]
    L.speedChips = chips(speedTitles, on: quick ? 1 : 0, at: y); y += 26 * k + 10 * k
    let check1 = y; y += 22 * k + 6 * k
    let check2 = y; y += 22 * k + 8 * k
    let rule = y; y += 1 * k
    let btnY = y
    let tw = Board.width(busy ? "Confirming…" : "Turn on…", 12 * k, medium: true) + 12 * k
    let cw = Board.width("Cancel", 12 * k) + 12 * k
    let right = px + content * k + 6 * k
    L.turnOn = CGRect(x: right - tw, y: btnY, width: tw, height: 28 * k)
    L.cancel = CGRect(x: L.turnOn.minX - 4 * k - cw, y: btnY, width: cw, height: 28 * k)
    y += 28 * k + (margin - 6) * k
    L.frame = CGRect(x: x0, y: top, width: W, height: y - top)
    guard draw else { return L }

    b.fillRound(L.frame.offsetBy(dx: 0, dy: 18), 12 * k / 1.4, rgb(0x000000, 0.45))
    b.fillRound(L.frame, 10 * k, Ink.surface)
    b.strokeRound(L.frame, 10 * k, 2, Ink.border)
    for (i, c) in [UInt32(0xFF5F57), 0xFEBC2E, 0x28C840].enumerated() {
        let d = 12 * k / 1.0 * 0.95
        b.fillRound(CGRect(x: x0 + 12 * k + CGFloat(i) * 20 * k, y: top + (titleH * k - d) / 2, width: d, height: d), d / 2,
                    i == 0 ? rgb(c) : Ink.border)
    }
    let tt = "Auto-approve"
    b.text(tt, x0 + W / 2 - Board.width(tt, 13 * k, medium: true) / 2, top + (titleH * k - Board.lineH(13 * k, medium: true)) / 2,
           13 * k, medium: true, Ink.muted)
    b.text("Approves every permission for you,", px, textY, 12 * k, Ink.muted)
    b.text("\(quick ? "under 1 s" : "1–15 s") after it's asked.", px, textY + l12, 12 * k, Ink.muted)
    func drawChips(_ rects: [CGRect], _ titles: [String], on: Int) {
        for (i, r) in rects.enumerated() {
            if i == on { b.fillRound(r, 4 * k, Ink.border) }
            else if let h = hover, h == r { b.strokeRound(r, 4 * k, 1.5, Ink.border) }
            let m = i == on
            b.text(titles[i], r.minX + 8 * k, r.midY - (m ? l12m : l12) / 2, 12 * k, medium: m, m || hover == r ? Ink.text : Ink.muted)
        }
    }
    drawChips(L.hourChips, hourTitles, on: hOn)
    drawChips(L.speedChips, speedTitles, on: quick ? 1 : 0)
    for (yy, title, on) in [(check1, "Answer questions (first option)", false), (check2, "Keep Mac awake while working", true)] {
        let ty = yy + (22 * k - l12m) / 2
        let bw = b.text(on ? "[x]" : "[ ]", px, ty, 12 * k, medium: true, Ink.text)
        b.text(title, px + bw + 8 * k, ty, 12 * k, on ? Ink.text : Ink.muted)
    }
    b.fill(CGRect(x: px, y: rule, width: content * k, height: max(1, k)), Ink.border)
    if let h = hover, h == L.turnOn || h == L.cancel { b.fillRound(h, 4 * k, Ink.border) }
    b.text("Cancel", L.cancel.minX + 6 * k, L.cancel.midY - l12 / 2, 12 * k, hover == L.cancel ? Ink.text : Ink.muted)
    b.text(busy ? "Confirming…" : "Turn on…", L.turnOn.minX + 6 * k, L.turnOn.midY - l12m / 2, 12 * k, medium: true, Ink.text)
    return L
}

// MARK: - Touch ID (same grid and motion as the other videos)

func drawTouchID(_ b: Board, _ t: Double, start s: Double, center c: CGPoint) {
    guard t >= s && t < s + 0.86 else { return }
    let pitch: CGFloat = 14, cell: CGFloat = 10
    let gs = gridSize(fingerprint, pitch: pitch, cell: cell)
    let lh = Board.lineH(20, medium: true)
    let ph = gs.height + 56 + lh + 18
    let plate = CGRect(x: c.x - gs.width / 2 - 44, y: c.y - ph / 2, width: gs.width + 88, height: ph)
    let x = plate.minX + 44, y = plate.minY + 32
    b.ctx.saveGState()
    cellClip(b, plate.insetBy(dx: -2, dy: -2), cell: 16) { i, j, _, _ in
        let h = hash01(i, j, 17)
        if t >= s + 0.72 { return t < s + 0.72 + h * 0.12 }
        return t >= s + h * 0.1
    }
    b.fillRound(plate.offsetBy(dx: 0, dy: 14), 12, rgb(0x000000, 0.4))
    b.fillRound(plate, Theme.radius * FUI_K, Ink.surface)
    b.strokeRound(plate, Theme.radius * FUI_K, 2, Ink.muted)
    func dist(_ r: Int, _ c: Int) -> Double {
        let dx = Double(c) - 6, dy = (Double(r) - 7) * 0.82
        return (dx * dx + dy * dy).squareRoot()
    }
    let rows = fingerprint.enumerated().map { (r, row) -> String in
        String(row.enumerated().map { (cc, ch) -> Character in ch == "#" && t < s + 0.14 + dist(r, cc) / 7 * 0.45 ? "o" : ch })
    }
    drawGrid(b, rows, x: x, y: y, pitch: pitch, cell: cell, ink: Ink.text)
    let done = t >= s + 0.6
    let label = done ? "TOUCH ID ✓" : String("TOUCH ID".prefix(max(0, Int((t - s - 0.14) * 40))))
    let lw = Board.width("TOUCH ID ✓", 20, medium: true)
    b.text(label, plate.midX - lw / 2, y + gs.height + 20, 20, medium: true, done ? Ink.text : Ink.muted, kern: 1)
    b.ctx.restoreGState()
}

// MARK: - Flow timing

let floodCursorPath: [(Double, CGFloat, CGFloat, Bool)] = {
    // targets are computed from the real layouts so clicks land on the drawn controls
    let pill = floodPill(10.0)!
    let ps = pill.size(FK)
    let click = CGPoint(x: DW / 2 + ps.width / 2 - 70, y: FPILL_Y + ps.height / 2 + 6)
    let rows = drawNudgeMenu(Board.dummy, o: CGPoint(x: click.x, y: click.y + 8), k: FUI_K, hover: nil, draw: false)
    let item = rows[menuTarget]
    let L = autoLayout(hours: 2, quick: false, busy: false)
    let h4 = L.hourChips[2], q = L.speedChips[1], on = L.turnOn
    return [
        (9.80, 1300, 760, false), (10.20, click.x, click.y, true),
        (10.62, item.minX + 120, item.midY, true),
        (11.12, h4.midX, h4.midY, true), (11.52, q.midX, q.midY, true), (11.98, on.midX, on.midY, true),
    ]
}()

extension Board { static let dummy = Board(width: 1, height: 1) }

let autoTop: CGFloat = FPILL_Y + 140
func autoLayout(hours: Int, quick: Bool, busy: Bool) -> AutoLayout {
    drawAutoWindow(Board.dummy, center: DW / 2, top: autoTop, k: FUI_K, hours: hours, quick: quick, busy: busy, draw: false)
}

func floodCursor(_ t: Double) -> CGPoint? {
    guard t >= 9.8 && t < 12.12 else { return nil }
    let path = floodCursorPath
    for i in 1..<path.count where t < path[i].0 {
        let a = path[i - 1], b = path[i]
        let p = CGFloat(smooth((t - a.0) / (b.0 - a.0 - 0.06)))
        return CGPoint(x: a.1 + (b.1 - a.1) * p, y: a.2 + (b.2 - a.2) * p)
    }
    let l = path.last!
    return CGPoint(x: l.1, y: l.2)
}

func drawArrow(_ b: Board, _ p: CGPoint, _ t: Double) {
    for c in floodCursorPath where c.3 && t >= c.0 && t < c.0 + 0.18 {
        let n = steps(t, from: c.0, 0.18, 3)
        let r = CGFloat(10 + n * 8)
        b.ctx.setStrokeColor(Ink.text.a(0.8)); b.ctx.setLineWidth(2)
        b.ctx.strokeEllipse(in: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
    }
    let s: CGFloat = 1.8
    let pts: [CGPoint] = [(0, 0), (0, 17), (4, 13), (7, 20), (9.5, 19), (6.5, 12), (12, 12)].map {
        CGPoint(x: p.x + $0.0 * s, y: p.y + $0.1 * s)
    }
    let path = CGMutablePath(); path.addLines(between: pts); path.closeSubpath()
    b.ctx.addPath(path); b.ctx.setFillColor(rgb(0xFFFFFF)); b.ctx.fillPath()
    b.ctx.addPath(path); b.ctx.setStrokeColor(rgb(0x000000)); b.ctx.setLineWidth(1.4); b.ctx.strokePath()
}

// MARK: - Pill

func floodPillTop(_ t: Double) -> CGFloat {
    let n = steps(t, from: 16.6, 0.3, 10)
    return (FPILL_Y + (DPILL_TOP - FPILL_Y) * CGFloat(n) / 10).rounded()
}

func floodPill(_ t: Double) -> Pill? {
    guard t >= 8.6 else { return nil }
    var icons: [Glyph] = []
    if t >= 13.0 {
        var eye = Glyph(rows: Eye.open)
        if t < 13.2 { eye.show = { r, c in t >= 13.0 + hash01(r, c, 7) * 0.2 } }
        icons.append(eye)
    }
    if t >= 13.0 && t < 13.4 {
        let n = Int((t - 13.0) / 0.026) + 1
        let lit = Set(checkStroke.prefix(n).map { $0.0 * 10 + $0.1 })
        var g = Glyph(rows: MatrixFrames.check.still)
        g.show = { r, c in lit.contains(r * 10 + c) }
        if t >= 13.3 && t < 13.38 { g.lift = -1 }
        icons.append(g)
    }
    if t >= 13.4 {
        var g = Glyph(rows: MatrixFrames.bolt.still)
        let rowsOn = Int((t - 13.4) / 0.04) + 1
        g.show = { r, _ in r < rowsOn }
        icons.append(g)
    }
    let n = floodCount(t)
    if t >= 13.55 && n > 0 { return .approving(t - 13.55, icons: icons) }
    if n == 0 { return .working(t, icons: icons) }
    return .asks(t - 8.6, count: n, icons: icons)
}

// MARK: - Frame

let floodCaptions: CaptionTable = [
    ({ t in "\(floodCount(t)) QUESTIONS" }, 3.9, 8.4),
    ({ _ in "ONE PILL" }, 9.0, 9.9),
    ({ _ in "AUTO · QUICK" }, 12.95, 15.2),
    ({ _ in "ALL CLEAR" }, 16.25, 17.9),
]

func floodDark(_ p: CGPoint, _ h: Double, _ t: Double) -> CGFloat {
    if t >= 18.0 + h * 0.4 { return 0.8 }
    if t >= 8.4 + h * 0.2 && t < waveTime(p) + 0.1 { return 0.6 }
    return 0
}

/// Everything that lives "on the desktop" (under the dim): wallpaper, windows, questions, chrome.
func drawFloodDesktop(_ b: Board, _ t: Double, focusOnly: Bool = false) {
    drawWallpaper(b)
    for wi in [2, 3, 1, 0] { drawWindow(b, wi, t, floodWinState(wi, t)) }
    for (i, a) in floodAsks.enumerated() { drawMiniAsk(b, a, i, t) }
    drawDock(b, t, bouncing: t >= 3.6 && t < 7.5)
    drawMenuBar(b, t, count: t >= 2.4 ? floodCount(t) : 0, clock: floodClock(t))
}

func renderFlood(_ b: Board, _ t: Double) {
    b.clear(rgb(0x161514))
    // close-up and pull back: the desktop drawn through a stepped zoom about window 0
    let zoomSteps = steps(t, from: 3.0, 0.6, 10)
    let z: CGFloat = 2.2 - 1.2 * CGFloat(zoomSteps) / 10
    let f = wins[0].frame
    let focus = CGPoint(x: f.midX, y: f.midY)
    let target = CGPoint(x: DW / 2 + (focus.x - DW / 2) * CGFloat(zoomSteps) / 10,
                         y: DH / 2 + (focus.y - DH / 2) * CGFloat(zoomSteps) / 10)
    b.ctx.saveGState()
    if z != 1 {
        b.ctx.translateBy(x: target.x, y: target.y)
        b.ctx.scaleBy(x: z, y: z)
        b.ctx.translateBy(x: -focus.x, y: -focus.y)
    }
    drawFloodDesktop(b, t)
    if t < 3.6 {
        // spotlight on the typing window: the rest dims, then comes back with the pull-back
        let dim = 0.62 * (1 - CGFloat(zoomSteps) / 10)
        if dim > 0 {
            b.fill(CGRect(x: -2000, y: -2000, width: 6000, height: 6000), rgb(0x000000, dim))
            drawWindow(b, 0, t, floodWinState(0, t))
        }
    }
    b.ctx.restoreGState()

    // focus dim from Nudge's arrival; the clearing wave lifts it; the end card dims again
    let cell: CGFloat = 40
    for j in 0..<Int(ceil(DH / cell)) { for i in 0..<Int(ceil(DW / cell)) {
        let p = CGPoint(x: CGFloat(i) * cell + cell / 2, y: CGFloat(j) * cell + cell / 2)
        let d = floodDark(p, hash01(i, j, 41), t)
        if d > 0 { b.fill(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell), rgb(0x000000, d)) }
    } }

    // the pill
    let top = floodPillTop(t)
    var center = CGPoint(x: DW / 2, y: top + 48)
    drawRipple(b, t, center: floodPillCenter)
    drawWaveFront(b, t)
    if let pill = floodPill(t) {
        let ps = pill.size(FK)
        let px = ((DW - ps.width) / 2).rounded()
        center = CGPoint(x: DW / 2, y: top + ps.height / 2)
        b.ctx.saveGState()
        let rect = CGRect(x: px - 2, y: top - 2, width: ps.width + 4, height: ps.height + 4)
        if t < 8.95 {
            cellClip(b, rect, cell: 12) { i, j, nx, _ in t >= 8.62 + Double(i) / Double(nx) * 0.22 + hash01(i, j, 2) * 0.1 }
        }
        b.fillRound(rect.offsetBy(dx: 0, dy: 12), Theme.radius * FK, rgb(0x000000, 0.35))
        pill.draw(b, x: px, y: top, k: FK, lw: 2)
        b.ctx.restoreGState()
    }
    _ = center

    // flow: menu, Auto window, Touch ID
    let path = floodCursorPath
    if t >= 10.24 && t < 10.74 {
        let o = CGPoint(x: path[1].1, y: path[1].2 + 8)
        b.ctx.saveGState()
        let rows = drawNudgeMenu(b, o: o, k: FUI_K, hover: nil, draw: false)
        let full = CGRect(x: o.x, y: o.y, width: 330 * FUI_K, height: rows.last!.maxY - o.y + 5 * FUI_K)
        if t < 10.34 {
            cellClip(b, full.insetBy(dx: -4, dy: -4), cell: 18) { i, j, _, _ in t >= 10.24 + hash01(i, j, 5) * 0.1 }
        }
        let hover: Int? = t >= 10.5 ? menuTarget : (t >= 10.36 ? 5 + (t >= 10.44 ? 1 : 0) : nil)
        drawNudgeMenu(b, o: o, k: FUI_K, hover: hover)
        b.ctx.restoreGState()
    }
    if t >= 10.76 && t < 13.0 {
        let hours = t >= path[3].0 ? 4 : 2
        let quick = t >= path[4].0
        let busy = t >= path[5].0
        let L = autoLayout(hours: hours, quick: quick, busy: busy)
        var hover: CGRect? = nil
        if let c = floodCursor(t) {
            for r in L.hourChips + L.speedChips + [L.turnOn, L.cancel] where r.insetBy(dx: -4, dy: -4).contains(c) { hover = r }
        }
        b.ctx.saveGState()
        cellClip(b, L.frame.insetBy(dx: -6, dy: -6), cell: 20) { i, j, _, _ in
            let h = hash01(i, j, 19)
            if t >= 12.86 { return t < 12.86 + h * 0.12 }
            return t >= 10.76 + h * 0.12
        }
        drawAutoWindow(b, center: DW / 2, top: autoTop, k: FUI_K, hours: hours, quick: quick, busy: busy, hover: hover)
        b.ctx.restoreGState()
        drawTouchID(b, t, start: 12.08, center: CGPoint(x: L.frame.midX, y: L.frame.midY + 10))
    }
    if let c = floodCursor(t) { drawArrow(b, c, t) }

    drawCaption(b, t, floodCaptions)
    drawDesktopEnd(b, t - 4.0)
}
