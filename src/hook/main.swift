import Foundation
import Darwin

// nudge-hook <event>, called by Claude Code hooks (via ~/.nudge/hook.sh) with the hook JSON on stdin.
//
//   start / pre   record details (host app, question text) for the widget. Prints nothing.
//   perm          PermissionRequest: hold the request so Nudge can answer it. Prints Nudge's
//                 decision, or nothing to hand the question to the normal terminal dialog.
//   ran           PostToolUse / PostToolUseFailure: a request that went to the terminal ran.
//   end           forget the session.
//
// perm and ran also write the permission log (PermLog) unless "Record permissions" is off.
//
// Claude's live state (busy / idle / waiting) comes from Claude itself, not from here.

func questionText(_ tool: String, _ input: [String: Any]) -> String {
    if tool == "ExitPlanMode" { return "Plan ready — approve or keep planning?" }
    if let qs = input["questions"] as? [[String: Any]], let q = qs.first?["question"] as? String {
        return qs.count > 1 ? "\(q) (+\(qs.count - 1) more)" : q
    }
    return "Claude has a question"
}

func recordDetail(_ sid: String, _ event: String, _ obj: [String: Any]) {
    withDetailLock(sid) {
        if event == "end" {
            try? FileManager.default.removeItem(at: detailFile(sid))
            unlink(detailLock(sid))
            return
        }
        var d = loadDetail(sid) ?? SessionDetail(id: sid)
        if d.bundle.isEmpty { d.bundle = ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "" }
        if event == "pre", let tool = obj["tool_name"] as? String {
            let input = obj["tool_input"] as? [String: Any] ?? [:]
            d.asks = [Ask(id: obj["tool_use_id"] as? String ?? "", text: questionText(tool, input))]
        }
        d.updated = Date().timeIntervalSince1970
        saveDetail(d)
    }
}

enum HoldResult {
    case answered([String: Any])    // Nudge's response
    case terminal(String)           // went to the terminal dialog, and why
}

/// Test sessions (NUDGE_TEST_SESSION) are answered and logged only by their sandboxed hook,
/// never by the real Nudge on this machine.
let foreignTest: Bool = {
    let env = ProcessInfo.processInfo.environment
    return env["NUDGE_TEST_SESSION"] != nil && env["NUDGE_HOME"] == nil
}()

/// Hold a PermissionRequest until Nudge answers, Nudge goes away, or `holdSeconds` pass.
func hold(_ obj: [String: Any], _ raw: Data) -> HoldResult {
    let fm = FileManager.default
    guard appIsAlive() else { return .terminal("nudge_not_running") }
    guard !fm.fileExists(atPath: Paths.holdOff.path) else { return .terminal("answer_from_nudge_off") }
    // Claude always shows its own "Ready to code?" dialog for a plan, whatever a hook answers
    // (tested on 2.1.283, via PermissionRequest and PreToolUse), so holding it would only delay it.
    if obj["tool_name"] as? String == "ExitPlanMode" { return .terminal("plan_dialog") }
    if foreignTest { return .terminal("test_session") }

    let id = UUID().uuidString
    var request = obj
    request["nudge_request_id"] = id
    request["nudge_created"] = Date().timeIntervalSince1970
    request["nudge_helper_pid"] = Int(getpid())
    writeJSON(request, to: requestFile(id))
    defer {
        try? fm.removeItem(at: requestFile(id))
        try? fm.removeItem(at: responseFile(id))
    }

    let deadline = Date().addingTimeInterval(holdSeconds)
    var lastAliveCheck = Date.distantPast
    while Date() < deadline {
        if let response = readJSON(responseFile(id)) {
            emit(response)
            return .answered(response)
        }
        if Date().timeIntervalSince(lastAliveCheck) > 1 {
            lastAliveCheck = Date()
            if !appIsAlive() { return .terminal("nudge_closed") }
        }
        usleep(100_000)
    }
    return .terminal("timeout")
}

/// Turn Nudge's response into the PermissionRequest decision JSON. "handoff" prints nothing.
func emit(_ r: [String: Any]) {
    guard let action = r["action"] as? String, action != "handoff" else { return }
    var decision: [String: Any] = ["behavior": action == "deny" ? "deny" : "allow"]
    if let m = r["message"] as? String, !m.isEmpty { decision["message"] = m }
    if let u = r["updatedInput"] { decision["updatedInput"] = u }
    if let p = r["updatedPermissions"] { decision["updatedPermissions"] = p }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
    if let data = try? JSONSerialization.data(withJSONObject: out) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write("\n".data(using: .utf8)!)
    }
}

// MARK: - Permission log

var recording: Bool { !foreignTest && !FileManager.default.fileExists(atPath: Paths.recordOff.path) }

/// Claude's own name for a session ("debug-session-state-issues"), from its status files.
func sessionName(_ sid: String) -> String {
    for f in (try? FileManager.default.contentsOfDirectory(at: Paths.claudeSessions, includingPropertiesForKeys: nil)) ?? []
    where f.pathExtension == "json" {
        if let d = readJSON(f), d["sessionId"] as? String == sid, let n = d["name"] as? String { return n }
    }
    return ""
}

/// The tool input as it is matched between PermissionRequest and PostToolUse: answers to an
/// AskUserQuestion only exist on the second, so they are left out.
func matchKey(_ obj: [String: Any]) -> String {
    var input = obj["tool_input"] as? [String: Any] ?? [:]
    input["answers"] = nil
    return (obj["tool_name"] as? String ?? "") + " " + canonicalJSON(input)
}

func logRequest(_ id: String, _ sid: String, _ obj: [String: Any]) {
    let tool = obj["tool_name"] as? String ?? ""
    let input = obj["tool_input"] as? [String: Any] ?? [:]
    let cwd = obj["cwd"] as? String ?? ""
    let name = sessionName(sid)
    PermLog.append([
        "type": "request", "id": id, "t": Date().timeIntervalSince1970, "helper_pid": Int(getpid()),
        "session_id": sid, "session_name": name.isEmpty ? (cwd as NSString).lastPathComponent : name, "cwd": cwd,
        "host": ProcessInfo.processInfo.environment["__CFBundleIdentifier"] ?? "",
        "tool": tool, "summary": permSummary(tool, input), "input": canonicalJSON(input),
        "suggested_rule": ruleLabel(obj["permission_suggestions"]) ?? "",
        "auto_mode": currentAutoMode(),
    ])
}

func logResult(_ id: String, _ sid: String, _ obj: [String: Any], _ result: HoldResult) {
    var e: [String: Any] = ["type": "decision", "id": id, "t": Date().timeIntervalSince1970]
    switch result {
    case .answered(let r) where r["action"] as? String == "handoff":
        logResult(id, sid, obj, .terminal(r["reason"] as? String ?? "handed_off"))
        return
    case .answered(let r) where r["auto"] as? Bool == true:
        e["by"] = "nudge_auto"
        e["decision"] = (r["updatedInput"] as? [String: Any])?["answers"] != nil ? "auto_answered" : "auto_allowed"
        if let a = (r["updatedInput"] as? [String: Any])?["answers"] { e["answers"] = canonicalJSON(a) }
        e["auto_delay"] = r["auto_delay"] as? Double ?? 0
        if let m = r["auto_mode"] as? String { e["auto_mode"] = m }
    case .answered(let r):
        e["by"] = "nudge"
        if r["action"] as? String == "deny" {
            e["decision"] = "denied"
            e["message"] = r["message"] as? String ?? ""
        } else if let answers = (r["updatedInput"] as? [String: Any])?["answers"] {
            e["decision"] = "answered"
            e["answers"] = canonicalJSON(answers)
        } else if let p = r["updatedPermissions"] {
            e["decision"] = "allowed_always"
            e["remembered_rule"] = ruleLabel(p) ?? ""
        } else {
            e["decision"] = "allowed"
        }
    case .terminal(let reason):
        e["by"] = "terminal"
        e["decision"] = "handed_to_terminal"
        e["reason"] = reason
        // Remember it, so PostToolUse can say whether the tool then ran.
        var pending: [String: Any] = ["id": id, "t": Date().timeIntervalSince1970, "key": matchKey(obj)]
        if let u = obj["tool_use_id"] as? String { pending["tool_use_id"] = u }
        writeJSON(pending, to: Paths.permPending.appendingPathComponent(sid).appendingPathComponent("\(id).json"))
    }
    PermLog.append(e)
}

/// PostToolUse: if this tool call went to the terminal earlier, log that it ran. Tool calls
/// that never asked find no pending folder and return after one directory read.
func logRan(_ sid: String, _ obj: [String: Any]) {
    guard recording else { return }
    let fm = FileManager.default
    let dir = Paths.permPending.appendingPathComponent(sid)
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil), !files.isEmpty else { return }
    PermLog.withLock {
        let pending = files.compactMap { f in readJSON(f).map { (f, $0) } }
            .sorted { ($0.1["t"] as? Double ?? 0) < ($1.1["t"] as? Double ?? 0) }
        let useID = obj["tool_use_id"] as? String ?? ""
        let key = matchKey(obj)
        guard let (file, p) = pending.first(where: { !useID.isEmpty && $0.1["tool_use_id"] as? String == useID })
                ?? pending.first(where: { $0.1["key"] as? String == key }),
              let id = p["id"] as? String else { return }
        try? fm.removeItem(at: file)
        if ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).isEmpty { try? fm.removeItem(at: dir) }
        var e: [String: Any] = ["type": "ran", "id": id, "t": Date().timeIntervalSince1970]
        if let a = (obj["tool_input"] as? [String: Any])?["answers"] { e["answers"] = canonicalJSON(a) }
        PermLog.appendLocked(e)
    }
}

let event = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let input = FileHandle.standardInput.readDataToEndOfFile()
let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))

if let obj = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any] {
    let sid = String(String.UnicodeScalarView((obj["session_id"] as? String ?? "").unicodeScalars.filter { allowed.contains($0) }))
    if event == "ran" {
        if !sid.isEmpty { logRan(sid, obj) }
    } else if !sid.isEmpty {
        recordDetail(sid, event, obj)
        if event == "perm" {
            let logID = UUID().uuidString
            let record = recording
            if record { logRequest(logID, sid, obj) }
            let result = hold(obj, input)
            if record { logResult(logID, sid, obj, result) }
        }
    }
}
