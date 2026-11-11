import Foundation
import Darwin

// Shared between the Nudge app and its nudge-hook helper.
//
// Where things live:
//   ~/.claude/sessions/<pid>.json   Claude Code's own live status per process (source of truth:
//                                   busy / idle / waiting + waitingFor). Nudge only reads it.
//   ~/.nudge/sessions/<sid>.json    what the hooks add: host app bundle id, the last question text.
//   ~/.nudge/requests/<id>.json     a permission request the helper is holding for Nudge to answer
//                                   (the raw hook payload plus nudge_* fields).
//   ~/.nudge/responses/<id>.json    Nudge's answer to a held request.
//   ~/.nudge/alive                  touched every second by the app; the helper only holds a
//                                   request while this is fresh.
//   ~/.nudge/hold-off               present when "Answer from Nudge" is turned off.
//   ~/.nudge/permissions.jsonl      the permission log (see PermLog), kept for 24 h.
//   ~/.nudge/perm-pending/<sid>/    requests handed to the terminal, waiting to see if the tool ran.
//   ~/.nudge/record-off             present when "Record permissions" is turned off.

enum Paths {
    static let home = FileManager.default.homeDirectoryForCurrentUser
    private static let env = ProcessInfo.processInfo.environment
    /// NUDGE_HOME / NUDGE_CLAUDE_SESSIONS / NUDGE_CLAUDE_SETTINGS: sandbox overrides for the tests.
    static let root = env["NUDGE_HOME"].map { URL(fileURLWithPath: $0) } ?? home.appendingPathComponent(".nudge")
    static let sessions = root.appendingPathComponent("sessions")
    static let requests = root.appendingPathComponent("requests")
    static let responses = root.appendingPathComponent("responses")
    static let alive = root.appendingPathComponent("alive")
    static let holdOff = root.appendingPathComponent("hold-off")
    static let permLog = root.appendingPathComponent("permissions.jsonl")
    static let permLock = root.appendingPathComponent(".permissions.lock")
    static let permPending = root.appendingPathComponent("perm-pending")
    static let recordOff = root.appendingPathComponent("record-off")
    /// {"mode": "normal"|"quick", "until": t} while auto-approval is on; the helper stamps it on requests.
    static let autoMode = root.appendingPathComponent("auto-mode")
    static let hookScript = root.appendingPathComponent("hook.sh")
    static let helperPath = root.appendingPathComponent("helper_path")
    /// Claude Code's config folder: CLAUDE_CONFIG_DIR when set (rare for a GUI app), else ~/.claude.
    static let claudeDir = env["CLAUDE_CONFIG_DIR"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? home.appendingPathComponent(".claude")
    static let claudeSettings = env["NUDGE_CLAUDE_SETTINGS"].map { URL(fileURLWithPath: $0) }
        ?? claudeDir.appendingPathComponent("settings.json")
    static let claudeSessions = env["NUDGE_CLAUDE_SESSIONS"].map { URL(fileURLWithPath: $0) }
        ?? claudeDir.appendingPathComponent("sessions")

    /// ~/.nudge holds raw tool inputs (commands can carry secrets): owner-only.
    static func secureRoot() {
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
    }
}

/// How long the helper holds a request before handing it to the terminal.
let holdSeconds: Double = 300
/// The app is considered gone when `alive` is older than this.
let aliveWindow: Double = 3

struct Ask: Codable, Equatable {
    var id: String
    var text: String
}

/// What the hooks know about a session beyond Claude's own status file.
struct SessionDetail: Codable, Equatable {
    var id: String
    var bundle: String = ""
    var updated: Double = 0
    var asks: [Ask] = []            // last AskUserQuestion / ExitPlanMode text, for observe-only cards
}

// MARK: - Detail files

func detailFile(_ sid: String) -> URL { Paths.sessions.appendingPathComponent("\(sid).json") }
func detailLock(_ sid: String) -> String { Paths.sessions.appendingPathComponent(".\(sid).lock").path }

func loadDetail(_ sid: String) -> SessionDetail? {
    (try? Data(contentsOf: detailFile(sid))).flatMap { try? JSONDecoder().decode(SessionDetail.self, from: $0) }
}

func saveDetail(_ s: SessionDetail) {
    if let data = try? JSONEncoder().encode(s) { try? data.write(to: detailFile(s.id), options: .atomic) }
}

/// Serializes read-modify-write of one detail file between concurrent hook processes.
func withDetailLock<T>(_ sid: String, _ body: () -> T) -> T {
    try? FileManager.default.createDirectory(at: Paths.sessions, withIntermediateDirectories: true)
    let fd = open(detailLock(sid), O_CREAT | O_RDWR | O_EXLOCK, 0o644)
    defer { if fd >= 0 { close(fd) } }
    return body()
}

// MARK: - Held requests

func requestFile(_ id: String) -> URL { Paths.requests.appendingPathComponent("\(id).json") }
func responseFile(_ id: String) -> URL { Paths.responses.appendingPathComponent("\(id).json") }

func appIsAlive() -> Bool {
    guard let m = (try? FileManager.default.attributesOfItem(atPath: Paths.alive.path))?[.modificationDate] as? Date
    else { return false }
    return Date().timeIntervalSince(m) < aliveWindow
}

func writeJSON(_ obj: Any, to url: URL) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]) {
        try? data.write(to: url, options: .atomic)
    }
}

func readJSON(_ url: URL) -> [String: Any]? {
    (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}

// MARK: - Processes

/// Parent pid and short process name, via sysctl.
func processInfo(_ pid: pid_t) -> (ppid: pid_t, name: String)? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let name = withUnsafePointer(to: &info.kp_proc.p_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN) + 1) { String(cString: $0) }
    }
    return (info.kp_eproc.e_ppid, name)
}

/// Single-quoted for /bin/sh, so a folder named `a"$(x)` stays a folder name.
func shellQuote(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }

func isAlive(_ pid: Int32) -> Bool { pid > 0 && (kill(pid, 0) == 0 || errno != ESRCH) }

// MARK: - Permission text

/// The one line that says what a request is for: the command, file, URL… or the first question.
func permSummary(_ tool: String, _ input: [String: Any]) -> String {
    if tool == "AskUserQuestion" {
        return ((input["questions"] as? [[String: Any]])?.first?["question"] as? String) ?? ""
    }
    for key in ["command", "file_path", "url", "pattern", "path", "prompt", "description"] {
        if let v = input[key] as? String, !v.isEmpty { return v }
    }
    return canonicalJSON(input)
}

/// Human label for Claude's "Yes, and don't ask again for …" suggestions ("Bash(npm run build:*)").
func ruleLabel(_ any: Any?) -> String? {
    guard let list = any as? [[String: Any]], !list.isEmpty else { return nil }
    let parts: [String] = list.flatMap { s -> [String] in
        switch s["type"] as? String {
        case "addRules", "replaceRules":
            return (s["rules"] as? [[String: Any]] ?? []).map { r in
                let tool = r["toolName"] as? String ?? ""
                if let c = r["ruleContent"] as? String, !c.isEmpty { return "\(tool)(\(c))" }
                return tool
            }
        case "setMode": return ["mode \(s["mode"] as? String ?? "")"]
        case "addDirectories": return (s["directories"] as? [String] ?? [])
        default: return []
        }
    }
    return parts.isEmpty ? nil : parts.joined(separator: ", ")
}

/// Stable JSON text (sorted keys, unescaped slashes): the exact tool input as it is logged and matched.
func canonicalJSON(_ any: Any) -> String {
    guard JSONSerialization.isValidJSONObject(any),
          let d = try? JSONSerialization.data(withJSONObject: any, options: [.sortedKeys, .withoutEscapingSlashes])
    else { return "" }
    return String(data: d, encoding: .utf8) ?? ""
}

// MARK: - Permission log

/// ~/.nudge/permissions.jsonl: one JSON event per line, appended by the helper.
///   request   a PermissionRequest: session, tool, exact tool_input, Claude's suggested rule
///   decision  how Nudge answered it, or that it went to the terminal (and why)
///   ran       a request that went to the terminal was followed by the tool running (PostToolUse)
/// The app drops everything older than `permKeep` and turns the events into one row per request.
let permKeep: Double = 24 * 3600

struct PermRow: Equatable {
    var id: String
    var requested: Double
    var sessionId = ""
    var sessionName = ""
    var cwd = ""
    var host = ""
    var kind = "permission"         // "permission" | "question"
    var tool = ""
    var summary = ""
    var input = ""                  // exact tool_input JSON
    var suggestedRule = ""
    var decision = "pending_in_nudge"
    var decidedBy = ""              // "nudge" | "terminal"
    var decided: Double?
    var reason = ""                 // why it went to the terminal
    var message = ""                // deny message
    var answers = ""                // AskUserQuestion answers, JSON
    var rememberedRule = ""         // the rule added with "Yes, don't ask again"
    var autoMode = ""               // auto-approval when it was asked: "off" | "normal" | "quick" ("" = not recorded)
    var autoDelay: Double?          // seconds auto-approval waited before answering
}

/// Auto-approval mode right now, from the file the app keeps: "off", "normal" or "quick".
func currentAutoMode(now: Double = Date().timeIntervalSince1970) -> String {
    guard let d = try? Data(contentsOf: Paths.autoMode),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let until = o["until"] as? Double, until > now else { return "off" }
    return o["mode"] as? String == "quick" ? "quick" : "normal"
}

enum PermLog {
    static func withLock<T>(_ body: () -> T) -> T {
        try? FileManager.default.createDirectory(at: Paths.root, withIntermediateDirectories: true)
        let fd = open(Paths.permLock.path, O_CREAT | O_RDWR | O_EXLOCK, 0o600)
        defer { if fd >= 0 { close(fd) } }
        return body()
    }

    static func append(_ event: [String: Any]) { withLock { appendLocked(event) } }

    /// Append for a caller that already holds `withLock` (the lock isn't reentrant).
    static func appendLocked(_ event: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return }
        data.append(0x0A)
        let fd = open(Paths.permLog.path, O_CREAT | O_WRONLY | O_APPEND, 0o600)
        guard fd >= 0 else { return }
        _ = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        close(fd)
    }

    static func events() -> [[String: Any]] {
        guard let data = try? Data(contentsOf: Paths.permLog) else { return [] }
        return data.split(separator: 0x0A).compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }
    }

    /// Drop requests (and their events) older than `permKeep`, and stale terminal-pending files.
    static func prune(now: Double = Date().timeIntervalSince1970) {
        let cutoff = now - permKeep
        let fm = FileManager.default
        withLock {
            let all = events()
            let old = Set(all.filter { $0["type"] as? String == "request" && ($0["t"] as? Double ?? 0) < cutoff }
                .compactMap { $0["id"] as? String })
            let kept = all.filter { e in
                !old.contains(e["id"] as? String ?? "") && (e["t"] as? Double ?? 0) >= cutoff
            }
            if kept.count != all.count {
                var out = Data()
                for e in kept {
                    if let d = try? JSONSerialization.data(withJSONObject: e, options: [.sortedKeys, .withoutEscapingSlashes]) {
                        out.append(d); out.append(0x0A)
                    }
                }
                try? out.write(to: Paths.permLog, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Paths.permLog.path)
            }
            for dir in (try? fm.contentsOfDirectory(at: Paths.permPending, includingPropertiesForKeys: nil)) ?? [] {
                let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
                for f in files {
                    let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                    if (m?.timeIntervalSince1970 ?? 0) < cutoff { try? fm.removeItem(at: f) }
                }
                if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
            }
        }
        // Answers whose helper had already given up (timed out, or Claude cancelled) stay behind.
        for f in (try? fm.contentsOfDirectory(at: Paths.responses, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if !fm.fileExists(atPath: requestFile(f.deletingPathExtension().lastPathComponent).path),
               now - (m?.timeIntervalSince1970 ?? 0) > 60 { try? fm.removeItem(at: f) }
        }
    }

    /// One row per request since `since`, oldest first. `status` gives a live session's Claude
    /// status ("busy" | "idle" | "waiting"), nil when the session is gone; it settles requests
    /// that went to the terminal and never ran.
    static func rows(since: Double, status: (String) -> String?) -> [PermRow] {
        let all = events()
        var rows: [String: PermRow] = [:]
        var order: [String] = []
        var handed = Set<String>()
        var helper: [String: Int32] = [:]
        var requestTimes: [String: [Double]] = [:]     // session -> request times, for "a later dialog"
        for e in all {
            guard let id = e["id"] as? String, let t = e["t"] as? Double else { continue }
            switch e["type"] as? String {
            case "request":
                var r = PermRow(id: id, requested: t)
                r.sessionId = e["session_id"] as? String ?? ""
                r.sessionName = e["session_name"] as? String ?? ""
                r.cwd = e["cwd"] as? String ?? ""
                r.host = e["host"] as? String ?? ""
                r.tool = e["tool"] as? String ?? ""
                r.kind = r.tool == "AskUserQuestion" ? "question" : "permission"
                r.summary = e["summary"] as? String ?? ""
                r.input = e["input"] as? String ?? ""
                r.suggestedRule = e["suggested_rule"] as? String ?? ""
                r.autoMode = e["auto_mode"] as? String ?? ""
                helper[id] = Int32(e["helper_pid"] as? Int ?? 0)
                requestTimes[r.sessionId, default: []].append(t)
                if rows[id] == nil { order.append(id) }
                rows[id] = r
            case "decision":
                guard var r = rows[id] else { continue }
                r.decision = e["decision"] as? String ?? ""
                r.decidedBy = e["by"] as? String ?? ""
                r.decided = t
                r.reason = e["reason"] as? String ?? ""
                r.message = e["message"] as? String ?? ""
                r.answers = e["answers"] as? String ?? ""
                r.rememberedRule = e["remembered_rule"] as? String ?? ""
                if r.decidedBy == "nudge_auto" {
                    r.autoDelay = e["auto_delay"] as? Double
                    // Logs from before modes were recorded: a sub-second wait can only be quick.
                    r.autoMode = e["auto_mode"] as? String ?? (r.autoMode.isEmpty || r.autoMode == "off"
                        ? ((r.autoDelay ?? 1) < 1 ? "quick" : "normal") : r.autoMode)
                }
                if r.decision == "handed_to_terminal" { handed.insert(id) }
                rows[id] = r
            case "ran":
                guard var r = rows[id] else { continue }
                r.decision = r.kind == "question" ? "answered_in_terminal" : "allowed_in_terminal"
                r.decidedBy = "terminal"
                r.decided = t
                if let a = e["answers"] as? String, !a.isEmpty { r.answers = a }
                handed.remove(id)
                rows[id] = r
            default: continue
            }
        }
        // Went to the terminal, never ran: Claude stops its turn after a denial, so idle (or gone,
        // or a later dialog in the same session) means it was denied or interrupted.
        for id in handed {
            guard var r = rows[id] else { continue }
            let later = requestTimes[r.sessionId]?.contains { $0 > r.requested } == true
            switch status(r.sessionId) {
            case nil, "idle"?: r.decision = "not_run"
            case _ where later: r.decision = "not_run"
            case "waiting"?: r.decision = "waiting_in_terminal"
            default: r.decision = "in_progress"
            }
            r.decidedBy = "terminal"
            r.decided = nil             // the terminal doesn't say when
            rows[id] = r
        }
        // Still held by a helper that died without writing a decision: Claude cancelled it.
        for id in order where rows[id]?.decision == "pending_in_nudge" && !isAlive(helper[id] ?? 0) {
            rows[id]?.decision = "cancelled"
        }
        return order.compactMap { rows[$0] }.filter { $0.requested >= since }
    }
}
