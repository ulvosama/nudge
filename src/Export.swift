import AppKit
import LocalAuthentication
import SwiftUI
import UniformTypeIdentifiers

// MARK: - CSV

/// The permission log as CSV: one row per request, oldest first, RFC 4180 quoting, CRLF lines,
/// UTF-8 with a BOM so Excel reads it as UTF-8. Values are exactly as logged.
enum PermCSV {
    static let columns = [
        "requested_at", "session_name", "session_id", "project_dir", "host_app", "kind", "tool", "summary",
        "tool_input_json", "suggested_rule", "decision", "decided_by", "decided_at", "wait_seconds",
        "auto_mode", "auto_delay_seconds",
        "terminal_reason", "deny_message", "answers", "remembered_rule",
    ]

    static func make(_ rows: [PermRow]) -> String {
        let iso = ISO8601DateFormatter()
        iso.timeZone = .current
        iso.formatOptions = [.withInternetDateTime]
        func date(_ t: Double?) -> String { t.map { iso.string(from: Date(timeIntervalSince1970: $0)) } ?? "" }
        var out = "\u{FEFF}" + columns.joined(separator: ",") + "\r\n"
        for r in rows {
            let wait = r.decided.map { String(format: "%.1f", max(0, $0 - r.requested)) } ?? ""
            let fields = [
                date(r.requested), r.sessionName, r.sessionId, r.cwd, r.host, r.kind, r.tool, r.summary,
                r.input, r.suggestedRule, r.decision, r.decidedBy, date(r.decided), wait,
                r.autoMode, r.autoDelay.map { String(format: "%.3f", $0) } ?? "",
                r.reason, r.message, r.answers, r.rememberedRule,
            ]
            out += fields.map(field).joined(separator: ",") + "\r\n"
        }
        return out
    }

    static func field(_ s: String) -> String {
        guard s.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

// MARK: - Utility windows

/// A small titled window in the shell style that always fits its SwiftUI content, also when the
/// content grows or shrinks (the Custom hours field, an error line).
func fittedWindow<V: View>(_ title: String, _ view: V, delegate: NSWindowDelegate) -> NSWindow {
    let host = NSHostingController(rootView: view)
    host.sizingOptions = [.preferredContentSize]
    let w = NSWindow(contentViewController: host)
    w.styleMask = [.titled, .closable]
    w.title = title
    w.titlebarAppearsTransparent = true
    w.appearance = NSAppearance(named: .darkAqua)
    w.backgroundColor = NSColor(Palette(highContrast: false).surface)
    w.isReleasedWhenClosed = false
    w.delegate = delegate
    w.setContentSize(host.view.fittingSize)     // preferredContentSize only applies once shown
    return w
}

/// Standard macOS window margin, and the content width inside it.
let windowMargin: CGFloat = 20
let windowContentWidth: CGFloat = 300

// MARK: - Export window

/// The export range: a preset or a custom 1–24 hours.
final class ExportModel: ObservableObject {
    static let presets = [1, 2, 6, 12, 24]
    @Published var preset: Int? = 24           // nil = custom
    @Published var custom = 8 {
        didSet { if custom != clamped(custom) { custom = clamped(custom) } }
    }
    /// The log for the last 24 h, refreshed while the window is open.
    @Published private(set) var rows: [PermRow] = []
    @Published private(set) var now = Date()

    private let status: (String) -> String?
    private var timer: Timer?

    init(status: @escaping (String) -> String?) { self.status = status }

    var hours: Int { preset ?? custom }
    var since: Double { now.timeIntervalSince1970 - Double(hours) * 3600 }
    var selected: [PermRow] { rows.filter { $0.requested >= since } }

    func clamped(_ h: Int) -> Int { min(max(h, 1), 24) }

    func refresh() {
        now = Date()
        let r = PermLog.rows(since: now.timeIntervalSince1970 - permKeep, status: status)
        if r != rows { rows = r }
    }

    func startLive() {
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.refresh() }
    }

    func stopLive() { timer?.invalidate(); timer = nil }
}

final class PermExportWindow: NSObject, NSWindowDelegate {
    private let model: ExportModel
    private var window: NSWindow!

    init(store: Store) {
        model = ExportModel(status: { [weak store] in store?.claudeStatus($0) })
        super.init()
        window = fittedWindow("Export permissions", ExportView(model: model,
                                                               onExport: { [weak self] in self?.export() },
                                                               onCancel: { [weak self] in self?.window.close() }),
                              delegate: self)
    }

    func show() {
        model.startLive()
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) { model.stopLive() }

    private func export() {
        model.refresh()
        let rows = model.selected
        guard !rows.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HHmm"
        panel.nameFieldStringValue = "Nudge permissions \(stamp.string(from: model.now)) (last \(model.hours)h).csv"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try PermCSV.make(rows).write(to: url, atomically: true, encoding: .utf8)
                window.close()
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } catch {
                NSAlert(error: error).beginSheetModal(for: window)
            }
        }
    }
}

struct ExportView: View {
    @ObservedObject var model: ExportModel
    let onExport: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        let rows = model.selected
        let questions = rows.filter { $0.kind == "question" }.count
        let auto = rows.filter { $0.decidedBy == "nudge_auto" }
        let quick = auto.filter { $0.autoMode == "quick" }.count
        VStack(alignment: .leading, spacing: 0) {
            Text("RANGE").font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
                .padding(.bottom, 6)
            HStack(spacing: 4) {
                ForEach(ExportModel.presets, id: \.self) { h in
                    RangeChip(title: "\(h)h", on: model.preset == h) { model.preset = h }
                }
                RangeChip(title: "Custom", on: model.preset == nil) { model.preset = nil }
            }
            if model.preset == nil {
                HStack(spacing: 8) {
                    Text("Last").font(Theme.mono(12)).foregroundStyle(p.muted)
                    TextField("", value: $model.custom, format: .number)
                        .textFieldStyle(.plain)
                        .font(Theme.mono(12, medium: true))
                        .foregroundStyle(p.text)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 32)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(RoundedRectangle(cornerRadius: 4).strokeBorder(p.border, lineWidth: 1))
                        .accessibilityLabel("Hours, 1 to 24")
                    Stepper("", value: $model.custom, in: 1...24).labelsHidden()
                    Text("hours (1–24)").font(Theme.mono(12)).foregroundStyle(p.muted)
                }
                .padding(.top, 8)
            }
            Hairline().padding(.vertical, 6)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(rows.count)").font(Theme.mono(20, medium: true)).foregroundStyle(p.text)
                    .contentTransition(.numericText())
                    .animation(.default, value: rows.count)
                Text(rows.count == 1 ? "permission" : "permissions").font(Theme.mono(12)).foregroundStyle(p.text)
                if questions > 0 {
                    Text("· \(questions) \(questions == 1 ? "question" : "questions")")
                        .font(Theme.mono(12)).foregroundStyle(p.muted)
                }
            }
            Text("from the last \(model.hours) \(model.hours == 1 ? "hour" : "hours") · since \(since)")
                .font(Theme.mono(11)).foregroundStyle(p.muted)
                .padding(.top, 2)
            if !auto.isEmpty {
                Text("\(auto.count) auto-approved" + (quick == 0 ? "" : quick == auto.count ? " · quick" : " · \(quick) quick"))
                    .font(Theme.mono(11)).foregroundStyle(p.muted)
                    .padding(.top, 2)
            }
            Hairline().padding(.vertical, 6)
            HStack(spacing: 4) {
                Text("Kept for 24 h").font(Theme.mono(11)).foregroundStyle(p.muted)
                Spacer()
                TextAction(title: "Cancel", primary: false, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                TextAction(title: "Export CSV…", primary: true, action: onExport)
                    .keyboardShortcut(.defaultAction)
                    .disabled(rows.isEmpty)
                    .opacity(rows.isEmpty ? 0.4 : 1)
            }
        }
        .frame(width: windowContentWidth, alignment: .leading)
        .padding(.horizontal, windowMargin)
        .padding(.bottom, windowMargin)
        .padding(.top, 8)
        .background(p.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Export permissions. \(rows.count) permissions from the last \(model.hours) hours.")
    }

    private var since: String {
        let f = DateFormatter()
        f.dateFormat = model.hours >= 24 ? "EEE HH:mm" : "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: model.since))
    }
}

/// One range option: mono text, a filled plate when chosen.
struct RangeChip: View {
    let title: String
    let on: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        Button(action: action) {
            Text(title)
                .font(Theme.mono(12, medium: on))
                .foregroundStyle(on || hover ? p.text : p.muted)
                .padding(.horizontal, 8)
                .frame(minHeight: 26)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? p.border : .clear))
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(hover && !on ? p.border : .clear, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Auto-approval

final class AutoModel: ObservableObject {
    static let choices = [1, 2, 4, 6, 24]
    @Published var hours = 2
    @Published var questions = false
    @Published var awake = true
    @Published var quick = false
    @Published var error: String?
    @Published var busy = false
}

/// Turning auto-approval on: pick how long, whether questions count, then Touch ID or password.
final class AutoApproveWindow: NSObject, NSWindowDelegate {
    private let model = AutoModel()
    private var window: NSWindow!
    private weak var store: Store?

    init(store: Store) {
        self.store = store
        super.init()
        window = fittedWindow("Auto-approve", AutoApproveView(model: model,
                                                              onConfirm: { [weak self] in self?.authenticate() },
                                                              onCancel: { [weak self] in self?.window.close() }),
                              delegate: self)
    }

    /// `prefill` comes from a nudge:// link; `confirm` then brings up Touch ID / password at once.
    func show(prefill: (hours: Int, quick: Bool, questions: Bool, awake: Bool)? = nil, confirm: Bool = false) {
        guard !model.busy else { return }
        model.error = nil
        if let p = prefill {
            model.hours = p.hours; model.quick = p.quick; model.questions = p.questions; model.awake = p.awake
        }
        NSApp.activate(ignoringOtherApps: true)
        if !window.isVisible { window.center() }
        window.makeKeyAndOrderFront(nil)
        if confirm { authenticate() }
    }

    private func authenticate() {
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else {
            model.error = err?.localizedDescription ?? "This Mac can't confirm it's you."
            return
        }
        model.busy = true
        model.error = nil
        let hours = model.hours, questions = model.questions, awake = model.awake, quick = model.quick
        ctx.evaluatePolicy(.deviceOwnerAuthentication,
                           localizedReason: "turn on \(quick ? "quick" : "normal") auto-approval of Claude Code permissions for \(hours) h") { ok, e in
            DispatchQueue.main.async {
                self.model.busy = false
                guard ok else {
                    self.model.error = (e as? LAError)?.code == .userCancel ? nil : e?.localizedDescription
                    return
                }
                self.store?.startAuto(hours: Double(hours), questions: questions, awake: awake, quick: quick)
                self.window.close()
            }
        }
    }
}

struct AutoApproveView: View {
    @ObservedObject var model: AutoModel
    let onConfirm: () -> Void
    let onCancel: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        VStack(alignment: .leading, spacing: 0) {
            Text("Approves every permission for you,\n\(model.quick ? "under 1 s" : "1–15 s") after it's asked.")
                .font(Theme.mono(12)).foregroundStyle(p.muted)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 4) {
                ForEach(AutoModel.choices, id: \.self) { h in
                    RangeChip(title: "\(h)h", on: model.hours == h) { model.hours = h }
                }
            }
            .padding(.top, 12)
            .padding(.leading, -8)          // chip text lines up with the text above
            HStack(spacing: 4) {
                RangeChip(title: "Normal 15s", on: !model.quick) { model.quick = false }
                RangeChip(title: "Quick <1s", on: model.quick) { model.quick = true }
            }
            .padding(.top, 4)
            .padding(.leading, -8)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Speed")
            CheckRow(title: "Answer questions (first option)", on: $model.questions).padding(.top, 10)
            CheckRow(title: "Keep Mac awake while working", on: $model.awake).padding(.top, 6)
            if let error = model.error {
                Text(error).font(Theme.mono(11)).foregroundStyle(p.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            Hairline().padding(.top, 8)
            HStack(spacing: 4) {
                Spacer()
                TextAction(title: "Cancel", primary: false, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                TextAction(title: model.busy ? "Confirming…" : "Turn on…", primary: true, action: onConfirm)
                    .disabled(model.busy)
                    .accessibilityHint("Asks for Touch ID or your password.")
            }
            .padding(.trailing, -6)          // button text lines up with the right edge
        }
        .frame(width: windowContentWidth, alignment: .leading)
        .padding(.horizontal, windowMargin)
        .padding(.bottom, windowMargin - 6)
        .padding(.top, 8)
        .background(p.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Auto-approve Claude Code permissions")
    }
}

/// "[x] Label": a mono checkbox row.
struct CheckRow: View {
    let title: String
    @Binding var on: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        Button { on.toggle() } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(on ? "[x]" : "[ ]").font(Theme.mono(12, medium: true)).foregroundStyle(p.text)
                Text(title).font(Theme.mono(12)).foregroundStyle(on ? p.text : p.muted)
            }
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(on ? "on" : "off")
        .accessibilityAddTraits(.isToggle)
    }
}
