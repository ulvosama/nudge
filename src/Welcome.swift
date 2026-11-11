import AppKit
import SwiftUI

// First run: what Nudge does, permission to add its Claude Code hooks, and the shortcuts.
// Same shell as the other windows: dark surface, Plex Mono, hairlines, dot-matrix marks.

final class WelcomeModel: ObservableObject {
    @Published var step = 0
    @Published var problem: String?
    @Published var installed = false
}

final class WelcomeWindow: NSObject, NSWindowDelegate {
    private let model = WelcomeModel()
    private var window: NSWindow!
    private weak var store: Store?

    init(store: Store) {
        self.store = store
        super.init()
        window = fittedWindow("Welcome to Nudge", WelcomeView(
            model: model,
            settingsPath: Paths.claudeSettings.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"),
            onAddHooks: { [weak self] in self?.addHooks() },
            onSkip: { [weak self] in self?.skip() },
            onDone: { [weak self] in self?.window.close() }), delegate: self)
    }

    func show() {
        model.installed = HookInstaller.isInstalled
        model.problem = store?.hookProblem
        // Already set up (opened again from the menu): start at the shortcuts.
        model.step = model.installed ? 2 : 0
        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    private func addHooks() {
        store?.installHooks()
        model.problem = store?.hookProblem
        model.installed = HookInstaller.isInstalled
        if model.problem == nil { model.step = 2 }
    }

    /// "Not now": nothing is written; the menu's "Install Claude Code hooks" does it later.
    private func skip() {
        UserDefaults.standard.set(true, forKey: "welcomeDone")
        model.step = 2
    }

    func windowWillClose(_ notification: Notification) {
        UserDefaults.standard.set(true, forKey: "welcomeDone")
    }
}

struct WelcomeView: View {
    @ObservedObject var model: WelcomeModel
    let settingsPath: String
    let onAddHooks: () -> Void
    let onSkip: () -> Void
    let onDone: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    static let width: CGFloat = 340

    var body: some View {
        let p = Palette.current(contrast)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                MatrixView(frames: .orbit, ink: p.orange, pitch: 4, cell: 3)
                Text("NUDGE").font(Theme.mono(13, medium: true)).foregroundStyle(p.text)
                Spacer()
                StepDots(step: model.step)
            }
            Hairline().padding(.top, 8)
            Group {
                switch model.step {
                case 0: intro(p)
                case 1: hooks(p)
                default: shortcuts(p)
                }
            }
            .padding(.top, 6)
            .frame(minHeight: 170, alignment: .topLeading)
            Hairline()
            HStack(spacing: 4) {
                Spacer()
                switch model.step {
                case 0:
                    TextAction(title: "Continue", primary: true) { model.step = 1 }
                        .keyboardShortcut(.defaultAction)
                case 1:
                    TextAction(title: "Not now", primary: false, action: onSkip)
                        .keyboardShortcut(.cancelAction)
                    TextAction(title: "Add hooks", primary: true, action: onAddHooks)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityHint("Adds Nudge's hooks to Claude Code's settings. A backup is kept.")
                default:
                    TextAction(title: "Done", primary: true, action: onDone)
                        .keyboardShortcut(.defaultAction)
                }
            }
            .padding(.trailing, -6)
        }
        .frame(width: Self.width, alignment: .leading)
        .padding(.horizontal, windowMargin)
        .padding(.bottom, windowMargin - 6)
        .padding(.top, 8)
        .background(p.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Welcome to Nudge")
    }

    private func intro(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Answer Claude Code from a floating pill.")
                .font(Theme.mono(13, medium: true)).foregroundStyle(p.text)
            Text("Nudge watches your Claude Code sessions. When one asks for permission, the pill turns orange and you answer right there, without finding the terminal.")
                .font(Theme.mono(12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            FeatureRow(frames: .breathe, ink: p.text, text: "WORKING / ASKS / YOUR TURN at a glance")
            FeatureRow(frames: .eye, ink: p.text, text: "Keeps the Mac awake while Claude works")
            FeatureRow(frames: .check, ink: p.text, text: "Auto-approve, only after Touch ID")
        }
    }

    private func hooks(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Connect to Claude Code")
                .font(Theme.mono(13, medium: true)).foregroundStyle(p.text)
            Text("Nudge adds a few hooks to \(settingsPath) so Claude can hand it permission requests. Your other settings stay as they are, and a copy of the file is kept as settings.json.before-nudge.")
                .font(Theme.mono(12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            Text("If Nudge isn't running, Claude asks in the terminal as usual. Remove the hooks any time from the menu.")
                .font(Theme.mono(12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let problem = model.problem {
                Text(problem).font(Theme.mono(11)).foregroundStyle(p.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func shortcuts(_ p: Palette) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.installed ? "You're set." : "Hooks not added yet")
                .font(Theme.mono(13, medium: true)).foregroundStyle(p.text)
            Text(model.installed
                 ? "Restart Claude Code sessions that were already running so they pick up the hooks."
                 : "Nudge shows your sessions but can't answer for them. Use \"Install Claude Code hooks\" in its menu when you're ready.")
                .font(Theme.mono(12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 4)
            ShortcutRow(label: "Allow", keys: "⌘↩")
            ShortcutRow(label: "Pick an option", keys: "⌘1–9")
            ShortcutRow(label: "Answer in the terminal", keys: "Esc")
            ShortcutRow(label: "Jump to the question", keys: "⌃⌥J")
            ShortcutRow(label: "Menu", keys: "right-click")
        }
    }
}

/// Three cells, the current one lit.
private struct StepDots: View {
    let step: Int
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let p = Palette.current(contrast)
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { i in
                Rectangle().fill(i == min(step, 2) ? p.text : p.offCell).frame(width: 4, height: 4)
            }
        }
        .accessibilityLabel("Step \(min(step, 2) + 1) of 3")
    }
}

private struct FeatureRow: View {
    let frames: MatrixFrames
    let ink: Color
    let text: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        HStack(spacing: 10) {
            MatrixView(frames: frames, ink: ink, pitch: 2, cell: 1.5).frame(width: 16)
            Text(text).font(Theme.mono(12)).foregroundStyle(Palette.current(contrast).text)
        }
    }
}

/// "Allow ········ ⌘↩"
private struct ShortcutRow: View {
    let label: String
    let keys: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        let p = Palette.current(contrast)
        HStack(spacing: 6) {
            Text(label.uppercased()).font(Theme.mono(11)).foregroundStyle(p.muted)
            Leader()
            Text(keys).font(Theme.mono(12, medium: true)).foregroundStyle(p.text)
        }
        .accessibilityElement(children: .combine)
    }
}
