import AppKit

// Renders the 1024px app icon in Nudge's shell style: a #20201E squircle with the Orbit
// indicator's resting frame (a three-quarter dot-matrix ring) in orange.
//   icon <out.png> [<small.png>]
// The optional second file is the 16/32 px variant: a 5×5 ring with fewer, larger cells, so the
// mark stays crisp where the 8×8 grid would blur.
let size: CGFloat = 1024

func hex(_ v: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: a)
}

func render(_ rows: [String], inset: CGFloat, radius: CGFloat, fill: CGFloat, to path: String) {
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext


let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: NSColor.black.withAlphaComponent(0.45).cgColor)
hex(0x20201E).setFill()
squircle.fill()
ctx.restoreGState()
hex(0x3A3935).setStroke()
squircle.lineWidth = 6
squircle.stroke()

// Cells: '#' lit, 'o' off. Top row first. The grid fills `fill` of the squircle's width.
let n = CGFloat(rows.count)
let pitch = (rect.width * fill) / (n - 0.28), cell = pitch * 0.72
let gridSide = pitch * (n - 1) + cell
let origin = CGPoint(x: (size - gridSide) / 2, y: (size - gridSide) / 2)
for (r, row) in rows.enumerated() {
    for (c, ch) in row.enumerated() where ch != "." {
        (ch == "#" ? hex(0xCE6B32) : hex(0x3A3935)).setFill()
        let y = origin.y + CGFloat(rows.count - 1 - r) * pitch
        NSBezierPath(rect: CGRect(x: origin.x + CGFloat(c) * pitch, y: y, width: cell, height: cell)).fill()
    }
}
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

let args = CommandLine.arguments
// Orbit static frame, 8×8.
render(["..oo##..", ".ooo###.", "oo....##", "oo....##", "##....##", "##....##", ".######.", "..####.."],
       inset: 100, radius: 185, fill: 0.71, to: args[1])
if args.count > 2 {
    // Small sizes: a 5×5 three-quarter ring, edge to edge with a thinner rim.
    render([".oo#.", "o...#", "#...#", "#...#", ".###."], inset: 40, radius: 200, fill: 0.74, to: args[2])
}
