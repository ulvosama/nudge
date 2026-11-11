import AppKit
import CoreText
import SwiftUI

// Nudge's "shell" design language.
// Dark shell, IBM Plex Mono, hairlines, dot-matrix indicators. Orange means one thing only:
// a session is waiting on you.

struct Palette {
    let surface: Color
    let border: Color
    let text: Color
    let muted: Color
    let offCell: Color
    let orange: Color

    init(highContrast: Bool) {
        surface = Color(hex: 0x20201E)
        border = Color(hex: highContrast ? 0x6A675F : 0x3A3935)
        text = Color(hex: 0xE7DED2)
        muted = highContrast ? Color(hex: 0xE7DED2) : Color(hex: 0xABA49A)
        offCell = Color(hex: highContrast ? 0x55534E : 0x3A3935)
        orange = Color(hex: 0xCE6B32)
    }

    static func current(_ contrast: ColorSchemeContrast) -> Palette { Palette(highContrast: contrast == .increased) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Theme {
    static let cardWidth: CGFloat = 280
    static let radius: CGFloat = 8
    static let padX: CGFloat = 12

    private static let regular = "IBMPlexMono-Regular"
    private static let medium = "IBMPlexMono-Medium"

    /// IBM Plex Mono ships in Resources/Fonts (ATSApplicationFontsPath). Registering by URL as
    /// well keeps it working when the views run outside the bundle (snapshot builds).
    static func registerFonts(extraDirectory: URL? = nil) {
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), extraDirectory].compactMap { $0 }
        for dir in dirs {
            for name in ["IBMPlexMono-Regular.ttf", "IBMPlexMono-Medium.ttf"] {
                let url = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: url.path) {
                    CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
                }
            }
        }
        if NSFont(name: regular, size: 12) == nil { NSLog("Nudge: IBM Plex Mono missing, using SF Mono") }
    }

    static func mono(_ size: CGFloat, medium isMedium: Bool = false) -> Font {
        let name = isMedium ? medium : regular
        if NSFont(name: name, size: size) != nil { return .custom(name, fixedSize: size) }
        return .system(size: size, weight: isMedium ? .medium : .regular, design: .monospaced)
    }

    static func nsMono(_ size: CGFloat, medium isMedium: Bool = false) -> NSFont {
        NSFont(name: isMedium ? medium : regular, size: size)
            ?? .monospacedSystemFont(ofSize: size, weight: isMedium ? .medium : .regular)
    }
}

/// A 1 pt hairline in the border color, with the file's 5 pt breathing room.
struct Hairline: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Rectangle().fill(Palette.current(contrast).border).frame(height: 1).padding(.vertical, 5)
    }
}

/// Dotted leader between a label and its value ("ACTIVE ······ 5h 00m").
struct Leader: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Canvas { ctx, size in
            let color = Palette.current(contrast).offCell
            var x: CGFloat = 1
            while x < size.width - 1 {
                ctx.fill(Path(CGRect(x: x, y: size.height / 2, width: 1, height: 1)), with: .color(color))
                x += 4
            }
        }
        .frame(minWidth: 8, maxWidth: .infinity, minHeight: 2, maxHeight: 2)
        .accessibilityHidden(true)
    }
}
