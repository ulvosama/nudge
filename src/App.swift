import AppKit
import Carbon.HIToolbox
import SwiftUI
import ServiceManagement
import IOKit.ps
import IOKit.pwr_mgt

// MARK: - Entry

#if !SNAPSHOT
@main
struct NudgeMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    let lock = LockOverlay()
    var panel: NSPanel!

    /// `nudge://…` links (see NudgeCommand), e.g. from `open` in a Claude session.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { if let cmd = NudgeCommand.parse(url) { store.run(cmd) } }
    }

    func applicationWillTerminate(_ note: Notification) {
        // Never leave Claude paused on a question nobody can answer.
        store.releaseAll()
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        // A sandboxed test run (NUDGE_HOME) leaves the real hooks, login item and widget alone.
        let sandbox = ProcessInfo.processInfo.environment["NUDGE_HOME"] != nil

        // One widget only. The copy in /Applications wins over any other (build folder, DMG).
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != me.processIdentifier }
        if !others.isEmpty && !sandbox {
            if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                others.forEach { $0.terminate() }
            } else {
                NSApp.terminate(nil)
                return
            }
        }

        Theme.registerFonts()
        if !sandbox {
            Paths.secureRoot()
            if Installer.offerMoveToApplications() { return }
            LoginItem.enableOnFirstRunFromApplications()
        }

        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 60, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)   // above the lock
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true

        let host = SizingHostingView(rootView: RootView(store: store))
        host.sizingOptions = [.intrinsicContentSize]
        host.onSize = { [weak self] size in self?.store.layout(size) }
        host.menuProvider = { [weak self] in self?.store.makeMenu() }
        panel.contentView = host

        store.window = panel
        store.host = host
        lock.onClick = { [weak self] in self?.store.pulse += 1 }
        store.onLockChange = { [weak self] on in
            guard let self else { return }
            if on { self.lock.show(); self.panel.orderFrontRegardless() } else { self.lock.hide() }
        }
        store.loadAnchor()
        store.applyHotKey()
        store.layout(host.intrinsicContentSize)
        panel.orderFrontRegardless()
        store.start()

        // Hooks: refresh them if you already said yes; ask first otherwise (Welcome).
        if !sandbox || ProcessInfo.processInfo.environment["NUDGE_WELCOME"] != nil {
            switch HookInstaller.launchAction() {
            case .refresh: store.hookProblem = HookInstaller.install()
            case .welcome: store.showWelcome()
            case .none: break
            }
        }

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.store.layout(nil) }
    }
}

/// Borderless panels can't become key by default; the open session list needs to, for the
/// keyboard (↑ ↓ ↵ esc). It stays non-activating, so the terminal's app remains frontmost.
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Reports its SwiftUI content's size so the panel can fit it exactly (a GeometryReader
/// preference only ever reported 0x0 here), shows the native right-click menu, and routes
/// keys to the store while the list is open.
final class SizingHostingView<V: View>: NSHostingView<V> {
    var onSize: ((CGSize) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    override var acceptsFirstResponder: Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = menuProvider?() else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.onSize?(self.intrinsicContentSize)
        }
    }
}

// MARK: - Model

enum Status: Int { case asking = 0, working, done, idle }

/// Claude Code's own live status for one process: ~/.claude/sessions/<pid>.json.
struct ClaudeProc: Equatable {
    let pid: Int32
    let sessionId: String
    let cwd: String
    let kind: String            // "interactive" | "bg"
    let name: String?
    let jobId: String?
    let status: String          // "busy" | "idle" | "waiting"
    let waitingFor: String?
    let statusUpdatedAt: Double // ms

    init?(_ d: [String: Any]) {
        guard let pid = d["pid"] as? Int, let sid = d["sessionId"] as? String else { return nil }
        self.pid = Int32(pid)
        sessionId = sid
        cwd = d["cwd"] as? String ?? ""
        kind = d["kind"] as? String ?? "interactive"
        name = d["name"] as? String
        jobId = d["jobId"] as? String
        status = d["status"] as? String ?? "idle"
        waitingFor = d["waitingFor"] as? String
        statusUpdatedAt = (d["statusUpdatedAt"] as? Double) ?? (d["updatedAt"] as? Double) ?? 0
    }
}

struct Session: Identifiable, Equatable {
    let proc: ClaudeProc
    let detail: SessionDetail?
    let status: Status

    var id: String { proc.sessionId }
    var project: String {
        let n = (proc.cwd as NSString).lastPathComponent
        return n.isEmpty ? "Claude" : n
    }
    /// Claude's own session name ("debug-session-state-issues"), else the project folder.
    var name: String { proc.name?.isEmpty == false ? proc.name! : project }
    var background: Bool { proc.kind == "bg" }
    var since: Double { proc.statusUpdatedAt / 1000 }

    var message: String {
        switch status {
        case .asking:
            // The hooks' question text, if it belongs to this wait; else what Claude says it waits for.
            if let d = detail, let a = d.asks.last, d.updated >= since - 3 { return a.text }
            return (proc.waitingFor ?? "input").capitalizingFirst
        case .working: return "Working…"
        case .done: return "Finished — your turn"
        case .idle: return "Ready"
        }
    }
}

extension String {
    var capitalizingFirst: String { prefix(1).uppercased() + dropFirst() }
}

struct AskOption: Equatable {
    let label: String
    let detail: String?
}

struct AskQuestion: Equatable {
    let text: String
    let header: String?
    let options: [AskOption]
    let multi: Bool
}

/// One thing waiting on you. Held items are PermissionRequests the helper is holding for Nudge
/// to answer; observed items are dialogs already showing in a terminal.
struct AskItem: Identifiable, Equatable {
    enum Kind: Equatable { case permission, questions, observed }

    let id: String
    let session: Session
    let kind: Kind
    let created: Double
    let tool: String
    let body: String
    let questions: [AskQuestion]
    let rememberLabel: String?      // "Bash(npm run build:*)" when Claude offers "don't ask again"
    let held: Bool
    let request: Data               // raw request JSON (held items)

    var requestObject: [String: Any] {
        (try? JSONSerialization.jsonObject(with: request) as? [String: Any]) ?? [:]
    }

    static func held(_ r: [String: Any], _ raw: Data, session: Session) -> AskItem {
        let tool = r["tool_name"] as? String ?? "Tool"
        let input = r["tool_input"] as? [String: Any] ?? [:]
        var kind = Kind.permission
        var body = ""
        var questions: [AskQuestion] = []
        switch tool {
        case "AskUserQuestion":
            kind = .questions
            questions = (input["questions"] as? [[String: Any]] ?? []).map { q in
                AskQuestion(text: q["question"] as? String ?? "",
                            header: q["header"] as? String,
                            options: (q["options"] as? [[String: Any]] ?? []).map {
                                AskOption(label: $0["label"] as? String ?? "", detail: $0["description"] as? String)
                            },
                            multi: q["multiSelect"] as? Bool ?? false)
            }
            body = questions.first?.text ?? ""
        default:
            body = permSummary(tool, input)
        }
        return AskItem(id: r["nudge_request_id"] as? String ?? UUID().uuidString, session: session, kind: kind,
                       created: r["nudge_created"] as? Double ?? Date().timeIntervalSince1970, tool: tool,
                       body: body, questions: questions,
                       rememberLabel: ruleLabel(r["permission_suggestions"]), held: true, request: raw)
    }

    static func observed(_ s: Session) -> AskItem {
        AskItem(id: "obs-\(s.id)-\(Int(s.since))", session: s, kind: .observed, created: s.since,
                tool: "", body: s.message, questions: [], rememberLabel: nil, held: false, request: Data())
    }
}

/// What the text field on the card is for, when it's open.
enum Draft: Equatable { case deny, other }

/// What a `nudge://` link asks for. Turning auto-approval on still needs your Touch ID / password:
/// the link only fills in the window and brings up the confirmation.
///   nudge://awake/on | nudge://awake/off | nudge://auto/off
///   nudge://auto/on?mode=quick|normal&hours=1..24&questions=0|1&awake=0|1
enum NudgeCommand: Equatable {
    case awake(Bool)
    case autoOff
    case autoOn(hours: Int, quick: Bool, questions: Bool, awake: Bool)

    static func parse(_ url: URL) -> NudgeCommand? {
        guard url.scheme?.lowercased() == "nudge", let c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let action = c.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        let q = Dictionary((c.queryItems ?? []).map { ($0.name.lowercased(), $0.value ?? "") }, uniquingKeysWith: { $1 })
        func flag(_ k: String, _ d: Bool) -> Bool { q[k].map { ["1", "true", "yes", "on"].contains($0.lowercased()) } ?? d }
        switch (c.host?.lowercased() ?? "", action) {
        case ("awake", "on"): return .awake(true)
        case ("awake", "off"): return .awake(false)
        case ("auto", "off"): return .autoOff
        case ("auto", "on"):
            let asked = min(max(Int(q["hours"] ?? "") ?? 2, 1), Int(Store.autoMaxHours))
            // Snap to a chip in the window, so it shows exactly what you're confirming.
            let hours = AutoModel.choices.min { abs($0 - asked) < abs($1 - asked) || (abs($0 - asked) == abs($1 - asked) && $0 > $1) } ?? 2
            return .autoOn(hours: hours, quick: q["mode"]?.lowercased() == "quick",
                           questions: flag("questions", false), awake: flag("awake", true))
        default: return nil
        }
    }
}

final class Store: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var asks: [AskItem] = []
    @Published var expanded = false

    // The card: which ask is showing, and progress through it.
    @Published var currentID: String?
    @Published var step = 0                        // AskUserQuestion: which question
    @Published var picks = Set<Int>()              // AskUserQuestion: chosen options on this step
    @Published var answers: [String: String] = [:] // AskUserQuestion: question text → answer
    @Published var draftMode: Draft?
    @Published var draft = ""
    @Published var pulse = 0                       // clicks on the lock: the card nudges

    /// Observed asks you chose "Later" for (held ones can't wait: Claude is paused on them).
    @Published var laterIDs = Set<String>()
    @Published var selection: Int?

    @Published var soundOn: Bool = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(soundOn, forKey: "soundOn") }
    }
    @Published var loginOn: Bool = LoginItem.isEnabled
    @Published var hotKeyOn: Bool = UserDefaults.standard.object(forKey: "hotKeyOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(hotKeyOn, forKey: "hotKeyOn"); applyHotKey() }
    }
    @Published var holdOn: Bool = UserDefaults.standard.object(forKey: "holdOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(holdOn, forKey: "holdOn"); syncHoldFlag() }
    }
    @Published var lockOn: Bool = UserDefaults.standard.object(forKey: "lockOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(lockOn, forKey: "lockOn"); updateLock() }
    }
    @Published var recordOn: Bool = UserDefaults.standard.object(forKey: "recordOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordOn, forKey: "recordOn"); syncRecordFlag() }
    }
    @Published var awakeOn: Bool = UserDefaults.standard.object(forKey: "awakeOn") as? Bool ?? true {
        didSet { UserDefaults.standard.set(awakeOn, forKey: "awakeOn"); updateAwake() }
    }

    weak var window: NSWindow?
    weak var host: NSView?
    var onLockChange: ((Bool) -> Void)?
    private(set) var locked = false
    private var outsideClickMonitor: Any?
    private var keyMonitor: Any?
    private var hotKey: HotKey?
    private let awake = SleepGuard()
    /// The Mac is being kept awake right now (shown on the chip and in the menu header).
    @Published private(set) var keepingAwake = false

    /// Auto-approval: Nudge answers held requests itself, each 1–15 s after it was asked, until
    /// `autoUntil` (at most `autoMaxHours` ahead). Turned on only after authentication (AutoApproveWindow).
    static let autoMaxHours = 24.0
    let autoMaxDelay = 15
    /// Quick mode: answer a fraction of a second after the ask (never instantly, always under 1 s
    /// counting the 0.25 s detection tick and the helper's 0.1 s poll).
    static let quickDelay = 0.15...0.6
    @Published private(set) var autoQuick = false
    @Published private(set) var autoUntil: Date?
    @Published private(set) var autoQuestions = false
    /// Keep the Mac awake while working (on power) for as long as auto-approval is on.
    @Published private(set) var autoAwake = false
    private var autoSince = Date.distantPast
    /// When each held ask will be auto-answered, and the delay drawn for it.
    private(set) var autoDue: [String: (at: Date, delay: Double)] = [:]
    private var autoWindow: AutoApproveWindow?

    /// The widget is pinned by the corner nearest the screen edges, so it grows away from
    /// them. `anchor` is that corner in screen coordinates; only a drag changes it.
    @Published var pinRight = true
    @Published var pinBottom = false
    private var anchor = NSPoint.zero
    private var timer: Timer?
    private var announced = Set<String>()
    private var wasBusy: [String: Bool] = [:]
    /// When each session's current "waiting" began (our clock). Claude 2.1.300 shows "waiting"
    /// for ~0.2 s while it hands a permission request to the hooks; only a wait that lasts
    /// `waitDebounce` is a real terminal dialog.
    private var waitingSince: [String: Date] = [:]
    var waitDebounce: TimeInterval = 0.7
    private var dragStart: (mouse: NSPoint, origin: NSPoint)?
    private var lastAliveTouch = Date.distantPast
    private var lastPrune = Date.distantPast
    private var exportWindow: PermExportWindow?

    var asking: [Session] { sessions.filter { $0.status == .asking } }
    /// The queue the card walks through: held first (Claude is paused on them), then observed.
    var visibleAsks: [AskItem] { asks.filter { !laterIDs.contains($0.id) && !quiet($0) } }
    /// Asks that need you (quick auto-approval handles the rest silently).
    var openAsks: [AskItem] { asks.filter { !quiet($0) } }
    var current: AskItem? { visibleAsks.first { $0.id == currentID } ?? visibleAsks.first }
    var currentIndex: Int { current.flatMap { c in visibleAsks.firstIndex { $0.id == c.id } } ?? 0 }
    var activeCount: Int { sessions.filter { $0.status != .idle }.count }

    init() { resumeAuto() }

    // MARK: Self-update

    let updater = Updater()
    /// Default on for signed GitHub releases (each one is verified against this app's Developer ID
    /// team). Off for a source checkout: there it would build and run whatever lands on main.
    @Published var autoUpdate: Bool = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool
        ?? (Updater.defaultMode() == .release) {
        didSet { UserDefaults.standard.set(autoUpdate, forKey: "autoUpdate") }
    }
    /// Install a READY update (automatic mode, or you asked from the menu).
    private var installWhenReady = false

    func checkForUpdates(manual: Bool) {
        installWhenReady = manual || autoUpdate
        updater.check()
    }

    /// Called from reload: install once nothing is waiting on you, so no question is dropped.
    private func maybeInstallUpdate() {
        guard installWhenReady, case .ready = updater.state, !asks.contains(where: \.held), draftMode == nil,
              !approving, ((try? FileManager.default.contentsOfDirectory(atPath: Paths.requests.path)) ?? [])
                .allSatisfy({ !$0.hasSuffix(".json") }) else { return }
        installWhenReady = false
        updater.install { releaseAll() }
    }

    func start() {
        updater.onChange = { [weak self] in self?.objectWillChange.send() }
        if autoUpdate {
            DispatchQueue.main.asyncAfter(deadline: .now() + Updater.startupDelay) { [weak self] in
                self?.checkForUpdates(manual: false)
            }
        }
        syncHoldFlag()
        syncRecordFlag()
        reload()
        // .common: keep answering (and keep `alive` fresh) while a menu is open; NSMenu tracking
        // runs the run loop in a mode a default-mode timer never fires in.
        let t = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.reload() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    // MARK: Reading state

    func reload() {
        let fm = FileManager.default
        let now = Date()
        if now.timeIntervalSince(lastAliveTouch) >= 1 {
            lastAliveTouch = now
            if !fm.createFile(atPath: Paths.alive.path, contents: nil) {
                try? fm.createDirectory(at: Paths.root, withIntermediateDirectories: true)
            }
        }
        if now.timeIntervalSince(lastPrune) >= 3600 {
            lastPrune = now
            DispatchQueue.global(qos: .utility).async { PermLog.prune() }
        }

        // Claude's processes, newest status per session.
        var procs: [String: ClaudeProc] = [:]
        for f in (try? fm.contentsOfDirectory(at: Paths.claudeSessions, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let d = readJSON(f), let p = ClaudeProc(d), isAlive(p.pid) else { continue }
            if let old = procs[p.sessionId], old.statusUpdatedAt > p.statusUpdatedAt { continue }
            procs[p.sessionId] = p
        }

        // Requests the helper is holding; drop any whose helper died (Claude cancelled the hook).
        var held: [String: [([String: Any], Data)]] = [:]
        for f in (try? fm.contentsOfDirectory(at: Paths.requests, includingPropertiesForKeys: nil)) ?? []
        where f.pathExtension == "json" {
            guard let raw = try? Data(contentsOf: f),
                  let r = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] else { continue }
            let helper = Int32(r["nudge_helper_pid"] as? Int ?? 0)
            if !isAlive(helper) { try? fm.removeItem(at: f); continue }
            held[r["session_id"] as? String ?? "", default: []].append((r, raw))
        }

        for p in procs.values {
            if p.status == "waiting" { waitingSince[p.sessionId] = waitingSince[p.sessionId] ?? now }
            else { waitingSince[p.sessionId] = nil }
        }
        waitingSince = waitingSince.filter { procs[$0.key] != nil }
        func realWait(_ sid: String) -> Bool {
            guard let since = waitingSince[sid] else { return false }
            return now.timeIntervalSince(since) >= waitDebounce
        }

        var found: [Session] = []
        for p in procs.values {
            let status: Status
            if held[p.sessionId] != nil || realWait(p.sessionId) {
                status = .asking; wasBusy[p.sessionId] = true
            } else if p.status == "busy" || p.status == "waiting" {
                status = .working; wasBusy[p.sessionId] = true
            } else {
                status = wasBusy[p.sessionId] == true ? .done : .idle
            }
            found.append(Session(proc: p, detail: loadDetail(p.sessionId), status: status))
        }
        // A held request whose session has no status file (an older Claude Code, or one that
        // writes elsewhere) would otherwise sit unseen for the whole hold. Show it anyway.
        for (sid, reqs) in held where procs[sid] == nil {
            let r = reqs[0].0
            if let p = ClaudeProc(["pid": r["nudge_helper_pid"] as? Int ?? 0, "sessionId": sid,
                                   "cwd": r["cwd"] as? String ?? "", "status": "waiting"]) {
                found.append(Session(proc: p, detail: loadDetail(sid), status: .asking))
            }
        }
        wasBusy = wasBusy.filter { procs[$0.key] != nil }
        found.sort {
            if $0.status != $1.status { return $0.status.rawValue < $1.status.rawValue }
            return $0.since > $1.since
        }

        var items: [AskItem] = []
        for s in found {
            if let reqs = held[s.id] {
                items += reqs.map { AskItem.held($0.0, $0.1, session: s) }
            } else if realWait(s.id) {
                items.append(.observed(s))
            }
        }
        items.sort {
            if $0.held != $1.held { return $0.held }
            return $0.created < $1.created
        }

        // New asks: sound + VoiceOver announcement, once each.
        // Quick auto-approval answers silently: no sound, no card, just APPROVING on the chip.
        let fresh = items.filter { !announced.contains($0.id) && !quiet($0) }
        if let first = fresh.first {
            if soundOn { NSSound(named: "Glass")?.play() }
            announce("\(first.session.name) asks: \(first.kind == .questions ? first.questions.first?.text ?? first.body : first.body)")
        }
        announced = Set(items.map(\.id))

        if found != sessions { sessions = found }
        if items != asks { asks = items }
        laterIDs.formIntersection(Set(items.map(\.id)))
        if current?.id != currentID { select(current?.id) }
        if let sel = selection, sel >= sessions.count { selection = sessions.isEmpty ? nil : sessions.count - 1 }
        runAuto(now)
        maybeInstallUpdate()
        updateApproving(now)
        updateLock()
        updateAwake()
    }

    // MARK: Auto-approval

    var autoOn: Bool { autoUntil.map { $0 > Date() } ?? false }

    /// Time left, "5h 12m" / "4m"; nil when off.
    var autoLeft: String? {
        guard autoOn, let u = autoUntil else { return nil }
        let m = Int((u.timeIntervalSinceNow / 60).rounded(.up))
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// Quick mode handles this ask without showing it: no card, no sound, no lock.
    func quiet(_ item: AskItem) -> Bool { autoQuick && autoHandles(item) }

    /// The chip shows APPROVING while a quick approval is pending, and for at least
    /// `approvingMin` so the animation is seen even when the approval takes 0.2 s.
    static let approvingMin = 0.8
    @Published private(set) var approving = false
    private var approvingSince: Date?
    private func updateApproving(_ now: Date) {
        if asks.contains(where: quiet) {
            if approvingSince == nil { approvingSince = now }
        } else if let since = approvingSince, now.timeIntervalSince(since) >= Self.approvingMin {
            approvingSince = nil
        }
        let on = approvingSince != nil
        if on != approving { approving = on }
    }

    /// Whether auto-approval will answer this ask: held permissions, and questions if chosen.
    func autoHandles(_ item: AskItem) -> Bool {
        autoOn && holdOn && item.held && (item.kind == .permission || (item.kind == .questions && autoQuestions))
    }

    func startAuto(hours: Double, questions: Bool, awake: Bool = false, quick: Bool = false, now: Date = Date()) {
        let until = now.addingTimeInterval(min(max(hours, 0), Self.autoMaxHours) * 3600)
        autoSince = now
        autoUntil = until
        autoQuestions = questions
        autoAwake = awake
        autoQuick = quick
        autoDue = [:]
        let d = UserDefaults.standard
        d.set(until.timeIntervalSince1970, forKey: "autoUntil")
        d.set(now.timeIntervalSince1970, forKey: "autoSince")
        d.set(questions, forKey: "autoQuestions")
        d.set(awake, forKey: "autoAwake")
        d.set(quick, forKey: "autoQuick")
        writeAutoMode()
        if !holdOn { holdOn = true }
        announce("Auto-approval on for \(autoLeft ?? "")")
        reload()
    }

    func stopAuto() {
        guard autoUntil != nil else { return }
        autoUntil = nil
        autoAwake = false
        autoQuick = false
        autoDue = [:]
        for k in ["autoUntil", "autoSince", "autoQuestions", "autoAwake", "autoQuick"] { UserDefaults.standard.removeObject(forKey: k) }
        writeAutoMode()
        announce("Auto-approval ended")
        updateLock()
    }

    /// After a relaunch: carry on until the saved end time, never more than `autoMaxHours` ahead.
    private func resumeAuto() {
        let d = UserDefaults.standard
        let until = d.double(forKey: "autoUntil"), now = Date().timeIntervalSince1970
        if until > now && until - now <= Self.autoMaxHours * 3600 {
            autoUntil = Date(timeIntervalSince1970: until)
            autoSince = Date(timeIntervalSince1970: d.double(forKey: "autoSince"))
            autoQuestions = d.bool(forKey: "autoQuestions")
            autoAwake = d.bool(forKey: "autoAwake")
            autoQuick = d.bool(forKey: "autoQuick")
            writeAutoMode()
        } else {
            for k in ["autoUntil", "autoSince", "autoQuestions", "autoAwake", "autoQuick"] { d.removeObject(forKey: k) }
        }
    }

    /// Tell the helper the mode, so each logged request says whether auto-approval was on.
    private func writeAutoMode() {
        if let u = autoUntil {
            writeJSON(["mode": autoQuick ? "quick" : "normal", "until": u.timeIntervalSince1970], to: Paths.autoMode)
        } else {
            try? FileManager.default.removeItem(at: Paths.autoMode)
        }
    }

    func run(_ cmd: NudgeCommand) {
        switch cmd {
        case .awake(let on):
            awakeOn = on
            announce(on ? "Stay awake on" : "Stay awake off")
        case .autoOff:
            stopAuto()
        case let .autoOn(hours, quick, questions, awake):
            if autoWindow == nil { autoWindow = AutoApproveWindow(store: self) }
            autoWindow?.show(prefill: (hours, quick, questions, awake), confirm: true)
        }
    }

    func showAutoApprove() {
        if autoWindow == nil { autoWindow = AutoApproveWindow(store: self) }
        autoWindow?.show()
    }

    /// Give each handled ask a random due time 1–15 s (quick: 0.15–0.6 s) after it was asked (or after auto-approval
    /// started, if older), and answer it once due. Anything you do first wins.
    private func runAuto(_ now: Date) {
        if autoUntil != nil && (!autoOn || !holdOn) { stopAuto(); return }
        guard autoOn else { return }
        autoDue = autoDue.filter { id, _ in asks.contains { $0.id == id } }
        for item in asks where autoHandles(item) {
            let due: (at: Date, delay: Double)
            if let d = autoDue[item.id] {
                due = d
            } else {
                let delay = autoQuick ? (Double.random(in: Self.quickDelay) * 1000).rounded() / 1000
                                      : Double(Int.random(in: 1...autoMaxDelay))
                let from = max(item.created, autoSince.timeIntervalSince1970)
                due = (Date(timeIntervalSince1970: from + delay), delay)
                autoDue[item.id] = due
                // Don't wait for the next 0.25 s tick: wake exactly when it's due.
                let wait = due.at.timeIntervalSince(now)
                if wait > 0 && wait < 1 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in self?.reload() }
                }
            }
            guard now >= due.at else { continue }
            // You're typing a reply or partway through the questions: leave it to you.
            if item.id == current?.id && (draftMode != nil || step > 0 || !picks.isEmpty) { continue }
            var response: [String: Any] = ["action": "allow", "auto": true, "auto_delay": due.delay,
                                           "auto_mode": autoQuick ? "quick" : "normal"]
            if item.kind == .questions {
                var input = item.requestObject["tool_input"] as? [String: Any] ?? [:]
                var answers: [String: String] = [:]
                for q in item.questions { if let first = q.options.first { answers[q.text] = first.label } }
                input["answers"] = answers
                response["updatedInput"] = input
            }
            autoDue[item.id] = nil
            respond(item, response)
        }
    }

    /// Keep the Mac awake while a session is working and the power adapter is connected.
    private func updateAwake() {
        awake.hold((awakeOn || (autoOn && autoAwake)) && (sessions.contains { $0.status == .working } || approving) && SleepGuard.onPower())
        if keepingAwake != awake.held { keepingAwake = awake.held }
    }

    func clearFinished() {
        for s in sessions where s.status == .done { wasBusy[s.id] = false }
        reload()
    }

    // MARK: The card

    /// Show a different ask; progress on the previous one is dropped.
    func select(_ id: String?) {
        currentID = id
        step = 0
        picks = []
        answers = [:]
        draftMode = nil
        draft = ""
    }

    func cycle(_ delta: Int) {
        let list = visibleAsks
        guard !list.isEmpty else { return }
        select(list[(currentIndex + delta + list.count) % list.count].id)
    }

    /// Numbered choice n (1-based) on the current card, or its primary action for n == 0 (⌘↩).
    func choose(_ n: Int) {
        guard let item = current else { return }
        switch item.kind {
        case .permission:
            let remember = item.rememberLabel != nil
            switch n {
            case 0, 1: respond(item, ["action": "allow"])
            case 2 where remember: respond(item, ["action": "allow", "updatedPermissions": suggestions(item)])
            case 2, 3: startDraft(.deny)
            default: break
            }
        case .questions:
            guard item.questions.indices.contains(step) else { return }
            let q = item.questions[step]
            if n == 0 && !q.multi && picks.isEmpty {
                choose(1)                     // ⌘↩ on a single choice = the first (recommended) option
            } else if n == 0 {
                confirmStep()
            } else if n == q.options.count + 1 {
                startDraft(.other)
            } else if q.options.indices.contains(n - 1) {
                if q.multi {
                    if picks.contains(n - 1) { picks.remove(n - 1) } else { picks.insert(n - 1) }
                } else {
                    picks = [n - 1]
                    confirmStep()
                }
            }
        case .observed:
            if n == 0 || n == 1 { openSession(item.session) }
        }
    }

    private func startDraft(_ mode: Draft) {
        draftMode = mode
        draft = ""
    }

    /// ↩ in the text field.
    func submitDraft() {
        guard let item = current, let mode = draftMode else { return }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch mode {
        case .deny:
            respond(item, ["action": "deny", "message": text.isEmpty ? "The user declined this tool call." : text])
        case .other:
            guard !text.isEmpty, item.questions.indices.contains(step) else { return }
            answers[item.questions[step].text] = text
            advanceStep(item)
        }
    }

    private func confirmStep() {
        guard let item = current, item.questions.indices.contains(step) else { return }
        let q = item.questions[step]
        let labels = picks.sorted().compactMap { q.options.indices.contains($0) ? q.options[$0].label : nil }
        guard !labels.isEmpty else { return }
        answers[q.text] = labels.joined(separator: ", ")
        advanceStep(item)
    }

    private func advanceStep(_ item: AskItem) {
        draftMode = nil
        draft = ""
        picks = []
        if step + 1 < item.questions.count {
            step += 1
            return
        }
        var input = item.requestObject["tool_input"] as? [String: Any] ?? [:]
        input["answers"] = answers
        respond(item, ["action": "allow", "updatedInput": input])
    }

    private func suggestions(_ item: AskItem) -> Any {
        item.requestObject["permission_suggestions"] ?? []
    }

    /// Esc: close the text field, else let the terminal handle this one.
    func escape() {
        if draftMode != nil { draftMode = nil; draft = ""; return }
        guard let item = current else { return }
        if item.held { respond(item, ["action": "handoff", "reason": "esc_in_nudge"]) } else { later(item) }
    }

    func later(_ item: AskItem) {
        laterIDs.insert(item.id)
        select(visibleAsks.first?.id)
        updateLock()
    }

    /// ⌘O: jump to the session; a held question goes back to its terminal dialog first.
    func openCurrent() {
        guard let item = current else { return }
        if item.held { respond(item, ["action": "handoff", "reason": "opened_terminal"]) }
        openSession(item.session)
    }

    private func respond(_ item: AskItem, _ response: [String: Any]) {
        // Only answer a request the helper is still holding; one it gave up on went to the terminal.
        if item.held, FileManager.default.fileExists(atPath: requestFile(item.id).path) {
            writeJSON(response, to: responseFile(item.id))
        }
        asks.removeAll { $0.id == item.id }
        select(visibleAsks.first?.id)
        updateLock()
    }

    // MARK: Lock and keys

    private func updateLock() {
        let want = lockOn && holdOn && visibleAsks.contains { $0.held && !autoHandles($0) }
        if want != locked {
            locked = want
            onLockChange?(want)
            if want { takeKeys() } else if !expanded { releaseKeys() }
        }
        installKeyMonitor(locked || expanded || window?.isKeyWindow == true)
    }

    /// Make the panel key without activating Nudge, so hotkeys land here.
    func takeKeys() {
        window?.makeKey()
        if let host { window?.makeFirstResponder(host) }
        installKeyMonitor(true)
    }

    private func releaseKeys() {
        installKeyMonitor(false)
        if window?.isKeyWindow == true { window?.orderOut(nil); window?.orderFrontRegardless() }
    }

    private func installKeyMonitor(_ on: Bool) {
        if on, keyMonitor == nil {
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                (self?.handleKey(e) ?? false) ? nil : e
            }
        } else if !on, let m = keyMonitor {
            NSEvent.removeMonitor(m)
            keyMonitor = nil
        }
    }

    /// Keys while the card or the list has the keyboard. True when handled.
    func handleKey(_ e: NSEvent) -> Bool {
        let cmd = e.modifierFlags.contains(.command)
        let shift = e.modifierFlags.contains(.shift)
        let code = Int(e.keyCode)

        if expanded {
            switch code {
            case kVK_Escape: closePanel()
            case kVK_DownArrow where !sessions.isEmpty: selection = min((selection ?? -1) + 1, sessions.count - 1)
            case kVK_UpArrow where !sessions.isEmpty: selection = max((selection ?? sessions.count) - 1, 0)
            case kVK_Return, kVK_ANSI_KeypadEnter:
                if let i = selection, sessions.indices.contains(i) { openSession(sessions[i]) }
            default: return false
            }
            return true
        }

        guard current != nil else { return false }
        if draftMode != nil {
            // The text field gets ordinary typing and ↩; we only take Esc.
            if code == kVK_Escape { escape(); return true }
            return false
        }
        switch code {
        case kVK_Escape: escape()
        case kVK_Return where cmd, kVK_ANSI_KeypadEnter where cmd: choose(0)
        case kVK_Tab: cycle(shift ? -1 : 1)
        case kVK_ANSI_O where cmd: openCurrent()
        case kVK_ANSI_RightBracket where cmd: cycle(1)
        case kVK_ANSI_LeftBracket where cmd: cycle(-1)
        default:
            let digits = [kVK_ANSI_1, kVK_ANSI_2, kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5,
                          kVK_ANSI_6, kVK_ANSI_7, kVK_ANSI_8, kVK_ANSI_9]
            if cmd, let i = digits.firstIndex(of: code) { choose(i + 1); return true }
            return false
        }
        return true
    }

    // MARK: Sessions

    /// The regular app (terminal, editor, Claude desktop) hosting this session.
    private func terminalApp(_ s: Session) -> NSRunningApplication? {
        var pid = s.proc.pid
        for _ in 0..<16 where pid > 1 {
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular { return app }
            guard let info = processInfo(pid) else { break }
            pid = info.ppid
        }
        if let b = s.detail?.bundle, !b.isEmpty {
            return NSRunningApplication.runningApplications(withBundleIdentifier: b).first
        }
        return nil
    }

    /// Open a session: bring its terminal forward, or attach a background session in a new one.
    @discardableResult
    func openSession(_ s: Session) -> Bool {
        closePanel()
        if s.background, let job = s.proc.jobId ?? Optional(String(s.id.prefix(8))) {
            let url = Paths.root.appendingPathComponent("attach-\(job).command")
            let script = "#!/bin/sh\ncd \(shellQuote(s.proc.cwd)) 2>/dev/null\nexec claude attach \(shellQuote(job))\n"
            try? script.write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return NSWorkspace.shared.open(url)
        }
        guard let app = terminalApp(s) else { return false }
        if let url = app.bundleURL {
            let cfg = NSWorkspace.OpenConfiguration()
            cfg.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: cfg)
        } else {
            app.activate()
        }
        return true
    }

    // MARK: Open / close the list

    func togglePanel() { expanded ? closePanel() : openPanel() }

    func openPanel() {
        guard !expanded else { return }
        expanded = true
        selection = sessions.isEmpty ? nil : 0
        takeKeys()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePanel()
        }
    }

    func closePanel() {
        guard expanded else { return }
        expanded = false
        selection = nil
        if let m = outsideClickMonitor { NSEvent.removeMonitor(m); outsideClickMonitor = nil }
        if !locked { releaseKeys() }
    }

    /// ⌃⌥J: bring the oldest question forward (the card takes the keyboard), or its terminal.
    func jumpToQuestion() {
        guard let item = visibleAsks.first ?? openAsks.first else { return }
        laterIDs.remove(item.id)
        select(item.id)
        if item.held { takeKeys() } else { openSession(item.session) }
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    func applyHotKey() {
        hotKey = nil
        guard hotKeyOn else { return }
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_J), modifiers: UInt32(controlKey | optionKey)) { [weak self] in
            self?.jumpToQuestion()
        }
    }

    private func syncHoldFlag() {
        let fm = FileManager.default
        if holdOn { try? fm.removeItem(at: Paths.holdOff) } else { fm.createFile(atPath: Paths.holdOff.path, contents: nil) }
        if !holdOn {
            // Release anything already held back to the terminal.
            for item in asks where item.held { respond(item, ["action": "handoff", "reason": "answer_from_nudge_off"]) }
        }
    }

    private func syncRecordFlag() {
        let fm = FileManager.default
        if recordOn { try? fm.removeItem(at: Paths.recordOff) } else { fm.createFile(atPath: Paths.recordOff.path, contents: nil) }
    }

    /// Live Claude status for a session id, nil when it's gone (settles terminal outcomes in the log).
    func claudeStatus(_ sid: String) -> String? { sessions.first { $0.id == sid }?.proc.status }

    func showExport() {
        if exportWindow == nil { exportWindow = PermExportWindow(store: self) }
        exportWindow?.show()
    }

    // MARK: Welcome and hooks

    /// Shown in the menu (and the Welcome window) when Nudge couldn't add or remove its hooks.
    @Published var hookProblem: String?
    @Published var hooksInstalled = HookInstaller.isInstalled
    private var welcomeWindow: WelcomeWindow?

    func showWelcome() {
        if welcomeWindow == nil { welcomeWindow = WelcomeWindow(store: self) }
        welcomeWindow?.show()
    }

    /// Welcome's "Add hooks" and the menu's "Install Claude Code hooks".
    func installHooks() {
        hookProblem = HookInstaller.install()
        hooksInstalled = HookInstaller.isInstalled
        UserDefaults.standard.set(true, forKey: "welcomeDone")
    }

    func removeHooks() {
        hookProblem = HookInstaller.uninstall()
        hooksInstalled = HookInstaller.isInstalled
    }

    /// Hand every held question back to the terminal (quitting, or turning answering off).
    func releaseAll() {
        for item in asks where item.held { writeJSON(["action": "handoff", "reason": "nudge_quit"], to: responseFile(item.id)) }
    }

    // MARK: Dragging

    func drag() {
        guard let w = window else { return }
        let m = NSEvent.mouseLocation
        if dragStart == nil { dragStart = (m, w.frame.origin) }
        guard let st = dragStart else { return }
        w.setFrameOrigin(NSPoint(x: st.origin.x + m.x - st.mouse.x, y: st.origin.y + m.y - st.mouse.y))
    }

    func endDrag() {
        dragStart = nil
        guard let w = window else { return }
        setAnchor(from: w.frame)
        layout(nil)
    }

    // MARK: Placement

    func loadAnchor() {
        let d = UserDefaults.standard
        if d.object(forKey: "anchorX") != nil {
            anchor = NSPoint(x: d.double(forKey: "anchorX"), y: d.double(forKey: "anchorY"))
            pinRight = d.bool(forKey: "pinRight")
            pinBottom = d.bool(forKey: "pinBottom")
        } else if d.object(forKey: "x") != nil {
            // v1.0/1.1 saved the top-left corner.
            setAnchor(from: NSRect(x: d.double(forKey: "x"), y: d.double(forKey: "y") - 44, width: 60, height: 44))
            d.removeObject(forKey: "x"); d.removeObject(forKey: "y")
        } else {
            let v = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            anchor = NSPoint(x: v.maxX - 12, y: v.maxY - 12)
            pinRight = true; pinBottom = false
        }
    }

    private func setAnchor(from f: NSRect) {
        let center = NSPoint(x: f.midX, y: f.midY)
        let v = (NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main)?.visibleFrame ?? f
        pinRight = f.midX > v.midX
        pinBottom = f.midY < v.midY
        anchor = NSPoint(x: pinRight ? f.maxX : f.minX, y: pinBottom ? f.minY : f.maxY)
        let d = UserDefaults.standard
        d.set(anchor.x, forKey: "anchorX"); d.set(anchor.y, forKey: "anchorY")
        d.set(pinRight, forKey: "pinRight"); d.set(pinBottom, forKey: "pinBottom")
    }

    /// Place the panel for a content size (nil: current size): pinned corner at the anchor,
    /// then clamped onto the screen. The clamp never moves the anchor, so nothing drifts.
    func layout(_ size: CGSize?) {
        guard let w = window, dragStart == nil else { return }
        let size = size ?? w.frame.size
        guard size.width > 0, size.height > 0 else { return }
        var f = NSRect(x: pinRight ? anchor.x - size.width : anchor.x,
                       y: pinBottom ? anchor.y : anchor.y - size.height,
                       width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(anchor) } ?? NSScreen.main
        if let v = screen?.visibleFrame {
            f.origin.x = min(max(f.minX, v.minX), v.maxX - f.width)
            f.origin.y = min(max(f.minY, v.minY), v.maxY - f.height)
        }
        if f != w.frame { w.setFrame(f, display: true) }
    }

    // MARK: Menu

    /// Native NSMenu in the shell language: a mono glance header, mono items, muted shortcuts.
    func makeMenu() -> NSMenu {
        let m = NSMenu()
        m.appearance = NSAppearance(named: .darkAqua)
        let n = openAsks.count
        var header = n > 0 ? "NUDGE  ·  \(sessions.count) SESSIONS  ·  \(n) ASKS" : "NUDGE  ·  \(sessions.count) SESSIONS"
        if keepingAwake { header += "  ·  AWAKE" }
        if let left = autoLeft { header += "  ·  AUTO \(autoQuick ? "QUICK " : "")\(left)" }
        let h = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        h.attributedTitle = NSAttributedString(string: header, attributes: [
            .font: Theme.nsMono(11, medium: true), .foregroundColor: NSColor(Palette(highContrast: false).muted),
        ])
        h.isEnabled = false
        m.addItem(h)
        m.addItem(.separator())
        m.addItem(ActionItem(expanded ? "Hide sessions" : "Show sessions") { [weak self] in self?.togglePanel() })
        let jump = ActionItem("Jump to question", key: "j", modifiers: [.control, .option]) { [weak self] in self?.jumpToQuestion() }
        jump.isEnabled = n > 0
        m.addItem(jump)
        m.addItem(.separator())
        m.addItem(ActionItem("Answer from Nudge", checked: holdOn) { [weak self] in self?.holdOn.toggle() })
        if let left = autoLeft {
            m.addItem(ActionItem("Stop auto-approval (\(left) left)", checked: true) { [weak self] in self?.stopAuto() })
        } else {
            m.addItem(ActionItem("Auto-approve…") { [weak self] in self?.showAutoApprove() })
        }
        m.addItem(ActionItem("Lock screen while asking", checked: lockOn) { [weak self] in self?.lockOn.toggle() })
        m.addItem(ActionItem("Record permissions (24 h)", checked: recordOn) { [weak self] in self?.recordOn.toggle() })
        m.addItem(ActionItem("Stay awake while working on power", checked: awakeOn) { [weak self] in self?.awakeOn.toggle() })
        m.addItem(ActionItem("Sound on question", checked: soundOn) { [weak self] in self?.soundOn.toggle() })
        m.addItem(ActionItem("Shortcut ⌃⌥J", checked: hotKeyOn) { [weak self] in self?.hotKeyOn.toggle() })
        m.addItem(ActionItem("Open at login", checked: loginOn) { [weak self] in self?.toggleLogin() })
        m.addItem(.separator())
        m.addItem(ActionItem("Export permissions…") { [weak self] in self?.showExport() })
        m.addItem(ActionItem("Clear finished sessions") { [weak self] in self?.clearFinished() })
        m.addItem(.separator())
        if let problem = hookProblem {
            let p = NSMenuItem(title: "", action: nil, keyEquivalent: "")
            p.attributedTitle = NSAttributedString(string: "Hooks: " + problem, attributes: [
                .font: Theme.nsMono(11), .foregroundColor: NSColor(Palette(highContrast: false).orange),
            ])
            p.isEnabled = false
            m.addItem(p)
        }
        hooksInstalled = HookInstaller.isInstalled
        if hooksInstalled {
            m.addItem(ActionItem("Remove Claude Code hooks") { [weak self] in self?.removeHooks() })
        } else {
            m.addItem(ActionItem("Install Claude Code hooks") { [weak self] in self?.installHooks() })
        }
        m.addItem(ActionItem("Welcome & shortcuts…") { [weak self] in self?.showWelcome() })
        m.addItem(.separator())
        let ver = NSMenuItem(title: updater.summary, action: nil, keyEquivalent: "")
        ver.isEnabled = false
        m.addItem(ver)
        if updater.enabled {
            let check = ActionItem("Check for updates now") { [weak self] in self?.checkForUpdates(manual: true) }
            check.isEnabled = updater.state != .checking
            m.addItem(check)
            m.addItem(ActionItem("Update automatically", checked: autoUpdate) { [weak self] in self?.autoUpdate.toggle() })
        }
        m.addItem(ActionItem("Nudge on GitHub") { NSWorkspace.shared.open(Updater.repoPage) })
        m.addItem(ActionItem("Uninstall Nudge…") { [weak self] in self.map { Installer.uninstall(store: $0) } })
        m.addItem(.separator())
        m.addItem(ActionItem("Quit Nudge", key: "q", modifiers: [.command]) { NSApp.terminate(nil) })
        return m
    }

    /// The list's "⋯" button: the same menu, under the pointer.
    func showMenu() {
        makeMenu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func toggleLogin() {
        LoginItem.set(!loginOn)
        loginOn = LoginItem.isEnabled
    }
}

/// Menu item that runs a closure.
final class ActionItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, key: String = "",
         modifiers: NSEvent.ModifierFlags = [], _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
        state = checked ? .on : .off
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.nsMono(12), .foregroundColor: NSColor(Palette(highContrast: false).text),
        ])
    }

    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

// MARK: - Views

struct RootView: View {
    @ObservedObject var store: Store

    var body: some View {
        // Pinned right: align right so the chip stays put. Pinned to the bottom half: the card
        // and the list open upward, above the chip.
        VStack(alignment: store.pinRight ? .trailing : .leading, spacing: 6) {
            if store.pinBottom { attachment }
            Chip(store: store)
            if !store.pinBottom { attachment }
        }
        .padding(10)
        .fixedSize()
        .environment(\.colorScheme, .dark)
    }

    /// Below the chip: the open list, or else the card for the current question.
    @ViewBuilder private var attachment: some View {
        if store.expanded {
            SessionPanel(store: store)
        } else if let item = store.current {
            AnswerCard(store: store, item: item)
        }
    }
}

/// What the chip shows. State is a shape + motion + word; orange only for "asks".
struct ChipState {
    enum Kind: Hashable { case none, ready, working, approving, asks(moving: Bool), done }
    let kind: Kind
    /// Mode icons after the word: Awake (eye), Auto (check) or Auto-quick (bolt).
    enum Icon: Hashable { case awake, auto, quick }
    /// The state word ("WORKING"), the session count (" · 2") and the mode icons.
    var base: String?
    var count = ""
    var icons: [Icon] = []
    var word: String? { base.map { $0 + count } }
    var label: String

    init(_ store: Store) {
        let asks = store.openAsks
        let working = store.sessions.filter { $0.status == .working }
        let done = store.sessions.filter { $0.status == .done }
        if let first = asks.first {
            kind = .asks(moving: !store.visibleAsks.isEmpty)
            base = "ASKS"
            count = asks.count > 1 ? " · \(asks.count)" : ""
            label = "Nudge. \(asks.count) \(asks.count == 1 ? "question" : "questions"). \(first.session.name) asks: \(first.body)"
        } else if store.approving || !working.isEmpty {
            // Approving is the working pill with another word and indicator, same suffixes.
            let quietIDs = Set(store.asks.filter(store.quiet).map(\.session.id))
            let n = store.sessions.filter { $0.status == .working || quietIDs.contains($0.id) }.count
            kind = store.approving ? .approving : .working
            base = store.approving ? "APPROVING" : "WORKING"
            count = n > 1 ? " · \(n)" : ""
            label = (store.approving ? "Nudge. Auto-approving a permission." : "Nudge. \(working.count) \(working.count == 1 ? "session" : "sessions") working.")
                + (store.keepingAwake ? " Keeping the Mac awake." : "")
        } else if let d = done.first {
            kind = .done
            base = "YOUR TURN"
            label = "Nudge. \(d.name) finished. Your turn."
        } else if !store.sessions.isEmpty {
            kind = .ready
            label = "Nudge. \(store.sessions.count) Claude \(store.sessions.count == 1 ? "session" : "sessions") ready."
        } else {
            kind = .none
            label = "Nudge. No Claude sessions."
        }
        if store.keepingAwake {
            icons.append(.awake)
            if kind != .working && kind != .approving { label += " Keeping the Mac awake." }
        }
        if let left = store.autoLeft {
            icons.append(store.autoQuick ? .quick : .auto)
            label += " Auto-approving\(store.autoQuick ? ", quick" : ""), \(left) left."
        }
    }
}

struct Chip: View {
    @ObservedObject var store: Store
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hover = false
    @State private var pressed = false
    @State private var dragging = false

    var body: some View {
        let p = Palette.current(contrast)
        let st = ChipState(store)
        HStack(spacing: 8) {
            indicator(st.kind, p)
                .frame(width: 24, height: 24)
                .id(st.kind)            // restart Stamp / timelines when the state changes
            if let base = st.base {
                HStack(spacing: 0) {
                    // WORKING and APPROVING take the same width, so the pill doesn't jump.
                    ZStack(alignment: .leading) {
                        if st.kind == .working || st.kind == .approving { Text("APPROVING").hidden() }
                        Text(base).foregroundStyle(st.kind == .approving ? p.orange : p.text)
                    }
                    Text(st.count).foregroundStyle(p.text)
                }
                .font(Theme.mono(11, medium: true))
                .lineLimit(1)
                .fixedSize()
            }
            if !st.icons.isEmpty {
                HStack(spacing: 5) {
                    ForEach(st.icons, id: \.self) { icon in
                        MatrixView(frames: icon == .awake ? .eye : icon == .quick ? .bolt : .check,
                                   animate: false, ink: p.text, pitch: 2, cell: 1.5)
                    }
                }
                .padding(.leading, st.base == nil ? 0 : -1)   // 8 pt HStack gap - 1 = 7 pt after the text
            }
        }
        .padding(.leading, 5)
        .padding(.trailing, st.word == nil && st.icons.isEmpty ? 5 : 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius)
            .strokeBorder(hover || store.expanded ? p.muted : p.border, lineWidth: 1))
        .opacity(pressed ? 0.75 : 1)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius))
        .onHover { hover = $0 }
        // One gesture for press, drag and click, so a drag never also counts as a click.
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { v in
                pressed = true
                if dragging || hypot(v.translation.width, v.translation.height) > 3 {
                    dragging = true
                    store.drag()
                }
            }
            .onEnded { _ in
                if dragging { store.endDrag() } else { store.togglePanel() }
                pressed = false
                dragging = false
            })
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(st.label)
        .accessibilityHint(store.expanded ? "Closes the session list." : "Opens the session list.")
        .accessibilityAction { store.togglePanel() }
    }

    @ViewBuilder private func indicator(_ kind: ChipState.Kind, _ p: Palette) -> some View {
        switch kind {
        case .none: MatrixView(frames: .empty, animate: false, ink: p.muted, pitch: 3, cell: 3)
        case .ready: MatrixView(frames: .breathe, animate: false, ink: p.text, pitch: 4, cell: 3)
        case .working: MatrixView(frames: .breathe, ink: p.text, pitch: 4, cell: 3)
        case .asks(let moving): MatrixView(frames: .orbit, animate: moving, ink: p.orange)
        case .approving: MatrixView(frames: .chase, ink: p.orange, pitch: 4, cell: 3)
        case .done: StampView(ink: p.text, side: 12)
        }
    }
}

/// The question card: Claude's options, numbered, answered with ⌘↩ / ⌘1–9, Esc hands off.
struct AnswerCard: View {
    @ObservedObject var store: Store
    let item: AskItem
    @Environment(\.colorSchemeContrast) private var contrast
    @FocusState private var fieldFocused: Bool
    @State private var nudge: CGFloat = 0

    var body: some View {
        let p = Palette.current(contrast)
        VStack(alignment: .leading, spacing: 8) {
            header(p)
            content(p)
            if store.draftMode != nil { field(p) }
            Rectangle().fill(p.border).frame(height: 1)
            if store.autoHandles(item) {
                TimelineView(.periodic(from: .now, by: 1)) { _ in footer(p) }
            } else {
                footer(p)
            }
        }
        .padding(.horizontal, Theme.padX)
        .padding(.vertical, 10)
        .frame(width: Theme.cardWidth + 60, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(item.held ? p.muted : p.border, lineWidth: 1))
        .modifier(Shake(amount: nudge))
        .onChange(of: store.pulse) { _, _ in withAnimation(.linear(duration: 0.3)) { nudge += 1 } }
        .onChange(of: store.draftMode) { _, mode in fieldFocused = mode != nil }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(item.session.name) asks")
    }

    private func header(_ p: Palette) -> some View {
        let count = store.visibleAsks.count
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Rectangle().fill(p.orange).frame(width: 6, height: 6)
                Text(item.session.name.uppercased())
                    .font(Theme.mono(11, medium: true)).foregroundStyle(p.muted).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                if count > 1 {
                    Text("\(store.currentIndex + 1) OF \(count)").font(Theme.mono(11, medium: true)).foregroundStyle(p.text)
                }
            }
            Text(item.session.name != item.session.project ? "\(item.session.project) · \(time(item.created))" : time(item.created))
                .font(Theme.mono(11)).foregroundStyle(p.muted).lineLimit(1)
        }
    }

    @ViewBuilder private func content(_ p: Palette) -> some View {
        switch item.kind {
        case .permission:
            Text(item.tool.uppercased()).font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
            codeBlock(item.body, p, lines: 6)
            options(p, [
                ("Yes", nil),
                item.rememberLabel.map { ("Yes, don't ask again for \($0)", nil) },
                ("No, tell Claude what to do differently…", nil),
            ].compactMap { $0 })
        case .questions:
            if item.questions.indices.contains(store.step) {
                let q = item.questions[store.step]
                Text(questionHeader(q)).font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
                Text(q.text).font(Theme.mono(12, medium: true)).foregroundStyle(p.text)
                    .fixedSize(horizontal: false, vertical: true)
                options(p, q.options.map { ($0.label, $0.detail) } + [("Other…", nil)], multi: q.multi)
            }
        case .observed:
            Text(item.body).font(Theme.mono(12)).foregroundStyle(p.text)
                .lineLimit(4).fixedSize(horizontal: false, vertical: true)
            Text(item.session.background ? "Waiting in a background session."
                                         : "Waiting in the terminal. Nudge can't answer this one.")
                .font(Theme.mono(11)).foregroundStyle(p.muted)
            HStack(spacing: 4) {
                TextAction(title: item.session.background ? "⌘↩ Open session" : "⌘↩ Open terminal", primary: true) {
                    store.openSession(item.session)
                }
                TextAction(title: "Later", primary: false) { store.later(item) }
            }
            .padding(.leading, -6)
        }
    }

    private func questionHeader(_ q: AskQuestion) -> String {
        var parts: [String] = []
        if item.questions.count > 1 { parts.append("QUESTION \(store.step + 1)/\(item.questions.count)") }
        if let h = q.header, !h.isEmpty { parts.append(h.uppercased()) }
        if q.multi { parts.append("CHOOSE ANY · ⌘↩ NEXT") }
        return parts.isEmpty ? "QUESTION" : parts.joined(separator: " · ")
    }

    private func options(_ p: Palette, _ list: [(String, String?)], multi: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(list.enumerated()), id: \.offset) { i, o in
                OptionRow(number: i + 1, label: o.0, detail: o.1,
                          primary: i == 0 && !multi,
                          checked: multi && i < list.count - 1 ? store.picks.contains(i) : nil) {
                    store.choose(i + 1)
                }
            }
        }
    }

    private func codeBlock(_ text: String, _ p: Palette, lines: Int) -> some View {
        Text(text)
            .font(Theme.mono(11))
            .foregroundStyle(p.text)
            .lineLimit(lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).fill(p.border.opacity(0.45)))
            .textSelection(.enabled)
    }

    private func field(_ p: Palette) -> some View {
        let prompt: String
        switch store.draftMode {
        case .deny: prompt = "Tell Claude what to do instead"
        default: prompt = "Your answer"
        }
        return TextField(prompt, text: $store.draft)
            .textFieldStyle(.plain)
            .font(Theme.mono(12))
            .foregroundStyle(p.text)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 4).strokeBorder(p.muted, lineWidth: 1))
            .focused($fieldFocused)
            .onSubmit { store.submitDraft() }
    }

    private func footer(_ p: Palette) -> some View {
        let more = store.visibleAsks.count > 1 ? "  tab next" : ""
        let hints: String
        if store.draftMode != nil {
            hints = "↩ send  esc back"
        } else if !item.held {
            hints = "esc later" + more
        } else {
            let primary: String
            switch item.kind {
            case .questions:
                let last = store.step + 1 >= item.questions.count
                let multi = item.questions.indices.contains(store.step) && item.questions[store.step].multi
                primary = multi ? (last ? "⌘↩ submit" : "⌘↩ next") : "⌘↩ first"
            default: primary = "⌘↩ yes"
            }
            hints = "\(primary)  esc terminal  ⌘O open" + more
        }
        if store.draftMode == nil, store.autoHandles(item), let due = store.autoDue[item.id] {
            let secs = max(0, Int(due.at.timeIntervalSinceNow.rounded(.up)))
            let auto = "auto-\(item.kind == .questions ? "answer" : "yes") " + (store.autoQuick ? "now  " : "in \(secs)s  ")
            return (Text(auto).font(Theme.mono(11, medium: true)).foregroundStyle(p.text)
                + Text(hints).font(Theme.mono(11)).foregroundStyle(p.muted)).lineLimit(1)
        }
        return Text(hints).font(Theme.mono(11)).foregroundStyle(p.muted).lineLimit(1)
    }

    private func time(_ t: Double) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: t))
    }
}

/// One numbered choice: "⌘1  Yes". Click or press its shortcut.
struct OptionRow: View {
    let number: Int
    let label: String
    let detail: String?
    let primary: Bool
    let checked: Bool?          // multi-select state, nil for single choice
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number <= 9 ? "⌘\(number)" : "  ")
                    .font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
                    .frame(width: 24, alignment: .leading)
                if let checked {
                    Text(checked ? "[x]" : "[ ]").font(Theme.mono(12)).foregroundStyle(checked ? p.text : p.muted)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).font(Theme.mono(12, medium: primary)).foregroundStyle(p.text)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail, !detail.isEmpty {
                        Text(detail).font(Theme.mono(11)).foregroundStyle(p.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 4)
                if primary { Text("⌘↩").font(Theme.mono(11)).foregroundStyle(p.muted) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover ? p.border : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -6)
        .onHover { hover = $0 }
        .accessibilityLabel("\(label)\(checked == true ? ", selected" : "")")
        .accessibilityHint("Command \(number)")
    }
}

/// Side-to-side wobble: the card's answer to a click on the locked screen.
struct Shake: GeometryEffect {
    var amount: CGFloat
    var animatableData: CGFloat {
        get { amount }
        set { amount = newValue }
    }
    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: 5 * sin(amount * .pi * 4), y: 0))
    }
}

/// A text button in the file's style: mono, no chrome, hover plate, 28 pt tall.
struct TextAction: View {
    let title: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        Button(action: action) {
            Text(title)
                .font(Theme.mono(12, medium: primary))
                .foregroundStyle(primary || hover ? p.text : p.muted)
                .padding(.horizontal, 6)
                .frame(minHeight: 28)
                .background(RoundedRectangle(cornerRadius: 4).fill(hover ? p.border : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityLabel(title.replacingOccurrences(of: "⌘↩ ", with: ""))
    }
}

struct SessionPanel: View {
    @ObservedObject var store: Store
    @Environment(\.colorSchemeContrast) private var contrast
    static let maxRows = 6

    var body: some View {
        let p = Palette.current(contrast)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("CLAUDE SESSIONS").font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
                Spacer()
                Text("\(store.sessions.count)").font(Theme.mono(11, medium: true)).foregroundStyle(p.muted)
            }
            .padding(.horizontal, Theme.padX)
            .padding(.top, 8)
            Hairline()
            if store.sessions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("NO SESSIONS").font(Theme.mono(12, medium: true)).foregroundStyle(p.text)
                    Text("Start Claude Code in a terminal and it shows up here.")
                        .font(Theme.mono(11)).foregroundStyle(p.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, Theme.padX)
                .padding(.vertical, 6)
            } else if store.sessions.count > Self.maxRows {
                ScrollView { rows }.frame(height: CGFloat(Self.maxRows) * 46)
            } else {
                rows
            }
            Hairline()
            HStack(spacing: 0) {
                Text("↑↓ select  ↩ open  esc close").font(Theme.mono(11)).foregroundStyle(p.muted)
                Spacer()
                TextAction(title: "⋯", primary: false) { store.showMenu() }
                    .accessibilityLabel("More")
            }
            .padding(.leading, Theme.padX)
            .padding(.trailing, 6)
            .padding(.bottom, 2)
        }
        .frame(width: Theme.cardWidth, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.radius).fill(p.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(p.border, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Claude sessions")
    }

    // Re-render every 30 s so the "3m" times keep moving.
    private var rows: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(store.sessions.enumerated()), id: \.element.id) { i, s in
                    SessionRow(session: s, selected: store.selection == i, now: context.date) {
                        store.selection = i
                        if s.status == .asking, let item = store.asks.first(where: { $0.session.id == s.id }) {
                            // An asking row brings its question card forward.
                            store.laterIDs.remove(item.id)
                            store.select(item.id)
                            store.closePanel()
                        } else {
                            store.openSession(s)
                        }
                    }
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: Session
    let selected: Bool
    let now: Date
    let open: () -> Void
    @State private var hover = false
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let p = Palette.current(contrast)
        let asks = session.status == .asking
        Button(action: open) {
            HStack(alignment: .top, spacing: 10) {
                tile(p).frame(width: 11, height: 16)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.name).font(Theme.mono(12)).foregroundStyle(p.text).lineLimit(1)
                        Leader()
                        Text(word).font(Theme.mono(11, medium: true)).foregroundStyle(asks ? p.text : p.muted)
                            .lineLimit(1).fixedSize()
                    }
                    Text(detail)
                        .font(Theme.mono(11))
                        .foregroundStyle(p.muted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 4).fill(hover || selected ? p.border.opacity(0.7) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? p.muted : .clear, lineWidth: 1))
            .contentShape(Rectangle())
            .padding(.horizontal, 4)
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("\(session.name), \(session.background ? "background, " : "")\(spoken). \(session.message)")
        .accessibilityHint(asks ? "Shows its question." : session.background ? "Opens it in a new terminal." : "Opens its terminal.")
    }

    private var word: String {
        switch session.status {
        case .asking: return "ASKS"
        case .working: return "WORKING"
        case .done: return "YOUR TURN"
        case .idle: return "READY"
        }
    }

    private var spoken: String {
        switch session.status {
        case .asking: return "asks"
        case .working: return "working"
        case .done: return "finished, your turn"
        case .idle: return "ready"
        }
    }

    private var detail: String {
        let where_ = session.name != session.project ? "\(session.project) · " : ""
        let base = session.status == .asking ? session.message : "\(session.message)  ·  \(ago(session.since))"
        return (session.background ? "Background · " : "") + where_ + base
    }

    @ViewBuilder private func tile(_ p: Palette) -> some View {
        let bg = session.background
        switch session.status {
        case .asking: MatrixView(frames: .ring, animate: false, ink: p.orange, pitch: 4, cell: 3, checker: bg)
        case .working: MatrixView(frames: .breathe, ink: p.text, pitch: 4, cell: 3, checker: bg)
        case .done: MatrixView(frames: .block, animate: false, ink: p.text, pitch: 4, cell: 3, checker: bg)
        case .idle: MatrixView(frames: .dot, animate: false, ink: p.text, pitch: 4, cell: 3, checker: bg)
        }
    }

    private func ago(_ t: Double) -> String {
        let s = max(0, Int(now.timeIntervalSince1970 - t))
        if s < 60 { return "now" }
        if s < 3600 { return "\(s / 60)m" }
        if s < 86400 { return "\(s / 3600)h" }
        return "\(s / 86400)d"
    }
}

// MARK: - Screen lock

/// While a held question is open: every screen dims and swallows clicks, one level below the
/// Nudge panel, which keeps the keyboard. Esc on the card always lifts it.
final class LockOverlay {
    private var windows: [NSPanel] = []
    var onClick: (() -> Void)?

    func show() {
        hide()
        for screen in NSScreen.screens {
            let w = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            w.level = .statusBar
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            w.backgroundColor = NSColor(srgbRed: 0x14 / 255, green: 0x14 / 255, blue: 0x13 / 255, alpha: 0.45)
            w.isOpaque = false
            w.hasShadow = false
            w.hidesOnDeactivate = false
            w.ignoresMouseEvents = false
            let v = ClickSink(frame: NSRect(origin: .zero, size: screen.frame.size))
            v.onClick = { [weak self] in self?.onClick?() }
            w.contentView = v
            w.setFrame(screen.frame, display: false)
            w.orderFrontRegardless()
            windows.append(w)
        }
    }

    func hide() {
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}

private final class ClickSink: NSView {
    var onClick: (() -> Void)?
    override func mouseDown(with event: NSEvent) { onClick?() }
    override func rightMouseDown(with event: NSEvent) { onClick?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Sleep guard

/// A power assertion that stops idle system sleep (the display may still sleep), like `caffeinate -i`.
/// macOS drops it when Nudge quits. Closing a laptop's lid still sleeps it.
final class SleepGuard {
    private var id: IOPMAssertionID = 0
    private(set) var held = false

    func hold(_ on: Bool) {
        guard on != held else { return }
        if on {
            held = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                               IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                               "Nudge: Claude Code session working" as CFString, &id) == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(id)
            held = false
        }
    }

    /// True when drawing from the power adapter (also true on a desktop Mac).
    static func onPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }
}

// MARK: - Global shortcut

/// A system-wide hotkey via Carbon's RegisterEventHotKey: needs no Accessibility permission.
final class HotKey {
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false
    private var ref: EventHotKeyRef?
    private let id: UInt32

    init?(keyCode: UInt32, modifiers: UInt32, _ action: @escaping () -> Void) {
        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x4E44_4745), id: id)   // 'NDGE'
        guard RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref) == noErr else {
            return nil
        }
        HotKey.handlers[id] = action
    }

    deinit {
        if let ref { UnregisterEventHotKey(ref) }
        HotKey.handlers[id] = nil
    }

    private static func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKey.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// MARK: - Claude Code hooks

enum HookInstaller {
    static let marker = "/.nudge/hook.sh"
    /// Our hook command: the usual ~/.nudge path, or the sandbox one under NUDGE_HOME.
    static func isOurs(_ command: Any?) -> Bool {
        guard let c = command as? String else { return false }
        return c.contains(marker) || c.contains(Paths.hookScript.path)
    }

    // (event, matcher, argument passed to the helper, timeout in seconds)
    // Claude's own ~/.claude/sessions status says busy / idle / waiting; the hooks only add the
    // question details and let Nudge answer permission requests (held up to `holdSeconds`).
    static let entries: [(String, String?, String, Int)] = [
        ("SessionStart", nil, "start", 10),
        ("PreToolUse", "AskUserQuestion|ExitPlanMode", "pre", 10),
        ("PermissionRequest", "", "perm", Int(holdSeconds) + 30),
        // A request that went to the terminal and then ran (or ran and failed) was allowed there.
        ("PostToolUse", "", "ran", 10),
        ("PostToolUseFailure", "", "ran", 10),
        ("SessionEnd", nil, "end", 10),
    ]

    static let script = """
    #!/bin/sh
    # Nudge: relays Claude Code hook events to the Nudge app's helper.
    # If Nudge has been removed this does nothing, so Claude is never affected.
    H="$(cat "$HOME/.nudge/helper_path" 2>/dev/null)"
    if [ -x "$H" ]; then exec "$H" "$1"; fi
    cat >/dev/null
    exit 0

    """

    /// What to do at launch. Hooks are only ever added after you said yes (Welcome, or the menu).
    enum LaunchAction { case refresh, welcome, none }

    static var optedOut: Bool {
        get { UserDefaults.standard.bool(forKey: "hooksOptOut") }
        set { UserDefaults.standard.set(newValue, forKey: "hooksOptOut") }
    }

    static func launchAction() -> LaunchAction {
        if optedOut { return .none }
        if isInstalled { return .refresh }          // you said yes before (or an earlier version did)
        return UserDefaults.standard.bool(forKey: "welcomeDone") ? .none : .welcome
    }

    /// Our hook is in Claude's settings.
    static var isInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return containsOurs(obj)
    }

    static func containsOurs(_ settings: [String: Any]) -> Bool {
        ((settings["hooks"] as? [String: Any]) ?? [:]).values
            .flatMap { ($0 as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .contains { isOurs($0["command"]) }
    }

    /// settings.json, through a symlink (dotfile managers) so we edit the real file in place.
    static var settingsURL: URL { Paths.claudeSettings.resolvingSymlinksInPath() }

    /// Adds (or refreshes) the hooks. Returns a problem to show you, or nil when all is well.
    @discardableResult
    static func install() -> String? {
        let fm = FileManager.default
        Paths.secureRoot()
        for dir in [Paths.sessions, Paths.requests, Paths.responses] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try? script.write(to: Paths.hookScript, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hookScript.path)
        // Point the hooks at this copy if it lives in /Applications, or if the current target is gone.
        // A copy run from the DMG or Downloads (move declined) mustn't steal them: it vanishes on eject.
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/nudge-hook").path
        let current = (try? String(contentsOf: Paths.helperPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if Bundle.main.bundlePath.hasPrefix("/Applications/") || !fm.isExecutableFile(atPath: current) {
            try? helper.write(to: Paths.helperPath, atomically: true, encoding: .utf8)
        }

        optedOut = false
        return editSettings { hooks in
            let cmd = "\"\(Paths.hookScript.path)\""
            for (event, matcher, arg, timeout) in entries {
                var group: [String: Any] = ["hooks": [["type": "command", "command": "\(cmd) \(arg)", "timeout": timeout]]]
                if let matcher { group["matcher"] = matcher }
                var list = hooks[event] as? [[String: Any]] ?? []
                list.append(group)
                hooks[event] = list
            }
        }
    }

    /// Removes our hooks and remembers that, so the next launch doesn't put them back.
    @discardableResult
    static func uninstall() -> String? {
        optedOut = true
        return editSettings { _ in }
    }

    /// Strips our entries, lets `add` put them back, and writes only if something changed.
    /// Anything we don't understand is left exactly as it is and reported instead.
    static func editSettings(_ add: (inout [String: Any]) -> Void) -> String? {
        let url = settingsURL
        let fm = FileManager.default
        var settings: [String: Any] = [:]
        var original: NSDictionary = [:]
        if fm.fileExists(atPath: url.path) {
            guard (try? Data(contentsOf: url)) != nil else {
                return "Nudge couldn't read \(Paths.claudeSettings.path), so it left it alone."
            }
        }
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "\(Paths.claudeSettings.path) isn't plain JSON (comments or a trailing comma?), so Nudge left it alone."
            }
            settings = obj
            original = obj as NSDictionary
        }

        if settings["hooks"] != nil && !(settings["hooks"] is [String: Any]) {
            return "\"hooks\" in settings.json isn't an object, so Nudge left it alone."
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for (event, value) in hooks {
            guard let list = value as? [[String: Any]] else {
                if entries.contains(where: { $0.0 == event }) {
                    return "hooks.\(event) in settings.json isn't a list, so Nudge left it alone."
                }
                continue
            }
            // Drop only our own hook; keep anything you put in the same group.
            let kept: [[String: Any]] = list.compactMap { group in
                guard let hs = group["hooks"] as? [[String: Any]] else { return group }
                let rest = hs.filter { !isOurs($0["command"]) }
                if rest.count == hs.count { return group }
                if rest.isEmpty { return nil }
                var g = group; g["hooks"] = rest; return g
            }
            hooks[event] = kept.isEmpty ? nil : kept
        }
        add(&hooks)
        settings["hooks"] = hooks.isEmpty ? nil : hooks

        if (settings as NSDictionary).isEqual(original) { return nil }

        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Keep a copy of the file as it was before Nudge, refreshed whenever it has none of our hooks.
        let backup = url.deletingLastPathComponent().appendingPathComponent("settings.json.before-nudge")
        if !containsOurs(original as? [String: Any] ?? [:]), let data = try? Data(contentsOf: url) {
            try? fm.removeItem(at: backup)
            // It may hold tokens (env, apiKeyHelper): owner-only, like the original should be.
            fm.createFile(atPath: backup.path, contents: data, attributes: [.posixPermissions: 0o600])
        }
        guard let out = try? JSONSerialization.data(withJSONObject: settings,
                                                    options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              (try? out.write(to: url, options: .atomic)) != nil else {
            return "Nudge couldn't write \(Paths.claudeSettings.path)."
        }
        return nil
    }
}

// MARK: - Move to Applications, uninstall

enum Installer {
    /// Run from the DMG, Downloads or anywhere outside /Applications: offer to move there, since
    /// the hooks, login item and updates all need a stable home. True when this copy is quitting.
    static func offerMoveToApplications() -> Bool {
        let here = Bundle.main.bundleURL
        guard !here.path.hasPrefix("/Applications/"), here.pathExtension == "app" else { return false }
        if UserDefaults.standard.bool(forKey: "skipMoveOffer") { return false }
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Move Nudge to Applications?"
        a.informativeText = "Nudge works best from the Applications folder: its Claude Code hooks, login item and updates all point there."
        a.addButton(withTitle: "Move to Applications")
        a.addButton(withTitle: "Not now")
        a.showsSuppressionButton = true
        a.suppressionButton?.title = "Don't ask again"
        let r = a.runModal()
        if a.suppressionButton?.state == .on { UserDefaults.standard.set(true, forKey: "skipMoveOffer") }
        guard r == .alertFirstButtonReturn else { return false }

        let dest = URL(fileURLWithPath: "/Applications/Nudge.app")
        let fm = FileManager.default
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        where app.processIdentifier != getpid() { app.terminate() }
        // Copy beside it first, so a failed copy leaves the installed one untouched.
        let tmp = URL(fileURLWithPath: "/Applications/.Nudge-new-\(getpid()).app")
        try? fm.removeItem(at: tmp)
        do {
            try fm.copyItem(at: here, to: tmp)
            if fm.fileExists(atPath: dest.path) { try fm.trashItem(at: dest, resultingItemURL: nil) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            try? fm.removeItem(at: tmp)
            NSAlert(error: error).runModal()
            return false
        }
        // Leave the original where it can't confuse: trash it unless it's on a read-only disk (the DMG).
        if fm.isWritableFile(atPath: here.deletingLastPathComponent().path), !here.path.contains("/AppTranslocation/") {
            try? fm.trashItem(at: here, resultingItemURL: nil)
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: dest, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return true
    }

    /// Removes the hooks, ~/.nudge, the login item and settings, moves the app to the Trash, quits.
    static func uninstall(store: Store) {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Uninstall Nudge?"
        a.informativeText = """
        This removes Nudge's hooks from Claude Code's settings, deletes ~/.nudge (including the \
        permission log), turns off open-at-login, and moves Nudge to the Trash.
        """
        a.addButton(withTitle: "Uninstall")
        a.addButton(withTitle: "Cancel")
        a.buttons.first?.hasDestructiveAction = true
        guard a.runModal() == .alertFirstButtonReturn else { return }

        store.releaseAll()
        if let problem = HookInstaller.uninstall() {
            let e = NSAlert()
            e.messageText = "Nudge couldn't remove its hooks"
            e.informativeText = problem + "\n\nRemove the entries containing \"/.nudge/hook.sh\" by hand. Nothing else was changed."
            e.runModal()
            return
        }
        LoginItem.set(false)
        let fm = FileManager.default
        try? fm.removeItem(at: Paths.root)
        // Claude sessions already running still call hook.sh until restarted: leave it in place.
        // With no helper_path it does nothing, so those sessions just ask in the terminal.
        try? fm.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        try? HookInstaller.script.write(to: Paths.hookScript, atomically: true, encoding: .utf8)
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: Paths.hookScript.path)
        if let id = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: id) }
        try? fm.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
        NSApp.terminate(nil)
    }
}

// MARK: - Login item

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) {
        if on { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
    }

    static func enableOnFirstRunFromApplications() {
        let d = UserDefaults.standard
        guard !d.bool(forKey: "loginSetUp"), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        set(true)
        d.set(true, forKey: "loginSetUp")
    }
}
