import SwiftUI

// Dot-matrix indicators: cells switch on and off on a grid, nothing
// rotates, no blur. Keyframes are exact cell states; a timer steps an integer frame index,
// so an animating indicator redraws a few times a second, not 60.
//
// Cell legend:  '#' ink   '+' ink at 70% (muted)   '-' ink at 35%   'o' off cell   '.' nothing

struct MatrixFrames {
    let frames: [[String]]      // keyframes, each a list of rows
    let still: [String]         // Reduce Motion / resting frame
    let period: Double          // seconds for one pass over `frames`
    let loops: Bool

    /// Orbit: a 90° arc travels the ring. 1.6 s, linear, loops. Static: three-quarter ring.
    static let orbit = MatrixFrames(frames: [
        ["..oo##..", ".ooo###.", "oo....##", "oo....##", "oo....oo", "oo....oo", ".oooooo.", "..oooo.."],
        ["..oooo..", ".oooooo.", "oo....o#", "oo....##", "oo....##", "oo....##", ".oooo##.", "..oooo.."],
        ["..oooo..", ".oooooo.", "oo....oo", "oo....oo", "oo....oo", "oo....#o", ".oo####.", "..####.."],
        ["..oooo..", ".oooooo.", "oo....oo", "oo....oo", "##....oo", "##....oo", ".###ooo.", "..##oo.."],
        ["..oooo..", ".##oooo.", "##....oo", "##....oo", "##....oo", "#o....oo", ".oooooo.", "..oooo.."],
        ["..####..", ".####oo.", "o#....oo", "oo....oo", "oo....oo", "oo....oo", ".oooooo.", "..oooo.."],
    ], still: ["..oo##..", ".ooo###.", "oo....##", "oo....##", "##....##", "##....##", ".######.", "..####.."],
       period: 1.6, loops: true)

    /// Breathe: a 3×3 block ripples out from the centre and back. 2.0 s, loops.
    /// Static: centre dot.
    static let breathe = MatrixFrames(frames: [
        ["...", ".#.", "..."],
        [".+.", "+#+", ".+."],
        ["+#+", "###", "+#+"],
        ["###", "#+#", "###"],
        ["#+#", "+.+", "#+#"],
        ["+.+", "...", "+.+"],
    ], still: ["---", "-#-", "---"], period: 2.0, loops: true)

    /// Chase: a lit cell with a fading tail runs round a 3×3 ring, the size of Breathe. 0.8 s,
    /// loops. Used in orange for APPROVING. Static: the full ring.
    static let chase: MatrixFrames = {
        let ring = [(0, 0), (0, 1), (0, 2), (1, 2), (2, 2), (2, 1), (2, 0), (1, 0)]
        let frames = (0..<ring.count).map { i -> [String] in
            var g = Array(repeating: Array("ooo"), count: 3)
            g[1][1] = "."
            let (hr, hc) = ring[i], (tr, tc) = ring[(i + ring.count - 1) % ring.count]
            g[tr][tc] = "-"; g[hr][hc] = "#"
            return g.map { String($0) }
        }
        return MatrixFrames(frames: frames, still: ["###", "#.#", "###"], period: 0.8, loops: true)
    }()

    /// Mode icons in the pill, drawn still at about text height: Awake, Auto, Auto-quick.
    static let eye = MatrixFrames(frames: [], still: ["..###..", ".#...#.", "#..#..#", ".#...#.", "..###.."], period: 0, loops: false)
    static let check = MatrixFrames(frames: [], still: [".....##", "....##.", "##.##..", ".###...", "..#...."], period: 0, loops: false)
    static let bolt = MatrixFrames(frames: [], still: ["...###.", "..##...", ".#####.", "...##..", "..##...", ".##...."], period: 0, loops: false)

    /// Resting shapes for the small 3×3 row tiles.
    static let dot = MatrixFrames(frames: [], still: ["ooo", "o#o", "ooo"], period: 0, loops: false)
    static let ring = MatrixFrames(frames: [], still: ["###", "#o#", "###"], period: 0, loops: false)
    static let block = MatrixFrames(frames: [], still: ["###", "###", "###"], period: 0, loops: false)
    static let empty = MatrixFrames(frames: [], still: ["o"], period: 0, loops: false)
}

/// Draws one set of MatrixFrames. `animate` false (or Reduce Motion) shows the still frame.
struct MatrixView: View {
    let frames: MatrixFrames
    var animate = true
    var ink: Color
    var pitch: CGFloat = 3
    var cell: CGFloat = 2
    /// Background sessions: every other cell drops to "off", a checker you can tell by shape.
    var checker = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let moving = animate && !reduceMotion && !frames.frames.isEmpty
        Group {
            if moving {
                let step = frames.period / Double(frames.frames.count)
                TimelineView(.periodic(from: .now, by: step)) { context in
                    let i = Int(context.date.timeIntervalSinceReferenceDate / step) % frames.frames.count
                    grid(frames.frames[i])
                }
            } else {
                grid(frames.still)
            }
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    private var size: CGSize {
        let rows = frames.still.count
        let cols = frames.still.first?.count ?? 0
        return CGSize(width: CGFloat(cols) * pitch - (pitch - cell), height: CGFloat(rows) * pitch - (pitch - cell))
    }

    private func grid(_ rows: [String]) -> some View {
        let p = Palette.current(contrast)
        return Canvas { ctx, _ in
            for (r, row) in rows.enumerated() {
                for (c, ch) in row.enumerated() {
                    var color: Color
                    switch ch {
                    case "#": color = ink
                    case "+": color = p.muted.opacity(0.7)
                    case "-": color = ink.opacity(0.35)
                    case "o": color = p.offCell
                    default: continue
                    }
                    if checker && (r + c) % 2 == 1 && ch != "." { color = p.offCell }
                    let rect = CGRect(x: CGFloat(c) * pitch, y: CGFloat(r) * pitch, width: cell, height: cell)
                    ctx.fill(Path(rect), with: .color(color))
                }
            }
        }
    }
}

/// Stamp: faint outline → ink outline → centre → solid, 0.4 s, once.
/// Reduce Motion: appears solid. Used for "your turn" in ink (orange stays for "asks").
struct StampView: View {
    var ink: Color
    var side: CGFloat = 12
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var frame = 0

    var body: some View {
        let p = Palette.current(contrast)
        ZStack {
            switch reduceMotion ? 4 : frame {
            case 0: Rectangle().strokeBorder(p.muted.opacity(0.6), lineWidth: 1)
            case 1: Rectangle().strokeBorder(ink, lineWidth: 1)
            case 2:
                Rectangle().strokeBorder(ink, lineWidth: 1)
                Rectangle().fill(ink).frame(width: side / 2, height: side / 2)
            default: Rectangle().fill(ink)
            }
        }
        .frame(width: side, height: side)
        .task {
            guard !reduceMotion else { return }
            for f in 1...4 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                frame = f
            }
        }
        .accessibilityHidden(true)
    }
}
