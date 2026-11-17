import AppKit
import SwiftUI

// Suite B: Store logic against fake Claude status files and fake held requests (sandboxed).
// Built with the app sources and -D SNAPSHOT (no @main in the app).

var passed = 0, failed = 0
/// With NUDGE_RENDER=<dir>, saves the live chip as a PNG (offscreen, nothing on screen).
@MainActor func renderChip(_ store: Store, _ name: String) {
    guard let dir = ProcessInfo.processInfo.environment["NUDGE_RENDER"] else { return }
    let r = ImageRenderer(content: Chip(store: store).padding(6).background(Color.black).environment(\.colorScheme, .dark)); r.scale = 3
    if let t = r.nsImage?.tiffRepresentation, let png = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: "\(dir)/chip-\(name).png"))
    }
}

func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passed += 1; print("PASS \(name)") } else { failed += 1; print("FAIL \(name)  [\(detail())]") }
}

@main struct StoreTests { static func main() {
    let root = NSTemporaryDirectory() + "nudge-b-\(getpid())"
    setenv("NUDGE_HOME", root, 1)
    setenv("NUDGE_CLAUDE_SESSIONS", root + "/claude-sessions", 1)
    setenv("NUDGE_CLAUDE_SETTINGS", root + "/claude/settings.json", 1)
    let fm = FileManager.default
    for d in ["claude-sessions", "requests", "responses", "sessions"] {
        try? fm.createDirectory(atPath: root + "/" + d, withIntermediateDirectories: true)
    }
    _ = NSApplication.shared
    let me = Int(getpid())
    let dead = 999_991
    let nowMs = Date().timeIntervalSince1970 * 1000

    func claude(_ pid: Int, _ sid: String, _ status: String, kind: String = "interactive", waiting: String? = nil, name: String? = nil, file: String? = nil) {
        var d: [String: Any] = ["pid": pid, "sessionId": sid, "cwd": "/x/proj-\(sid)", "kind": kind,
                                "status": status, "statusUpdatedAt": nowMs]
        if let waiting { d["waitingFor"] = waiting }
        if let name { d["name"] = name }
        writeJSON(d, to: URL(fileURLWithPath: root + "/claude-sessions/\(file ?? sid).json"))
    }
    @discardableResult
    func request(_ sid: String, _ tool: String, _ input: [String: Any], helper: Int = me, created: Double = Date().timeIntervalSince1970, sugg: Bool = false) -> String {
        let id = UUID().uuidString
        var r: [String: Any] = ["session_id": sid, "tool_name": tool, "tool_input": input,
                                "nudge_request_id": id, "nudge_created": created, "nudge_helper_pid": helper]
        if sugg { r["permission_suggestions"] = [["type": "addRules", "rules": [["toolName": "Bash", "ruleContent": "npm run build:*"]], "behavior": "allow", "destination": "localSettings"]] }
        writeJSON(r, to: requestFile(id))
        return id
    }
    /// What the helper would do after reading Nudge's answer: take the response, drop the request.
    func response(_ id: String) -> [String: Any]? {
        let r = readJSON(responseFile(id))
        try? fm.removeItem(at: requestFile(id)); try? fm.removeItem(at: responseFile(id))
        return r
    }
    func clearAll() {
        for d in ["claude-sessions", "requests", "responses"] {
            for f in (try? fm.contentsOfDirectory(atPath: root + "/" + d)) ?? [] { try? fm.removeItem(atPath: root + "/" + d + "/" + f) }
        }
    }

    let store = Store()
    store.soundOn = false
    store.waitDebounce = 0
    var lockEvents: [Bool] = []
    store.onLockChange = { lockEvents.append($0) }
    store.holdOn = true
    store.lockOn = true

    // ---- B1 detection
    claude(me, "s1", "waiting", waiting: "permission prompt")
    claude(me, "s2", "busy")
    claude(me, "s3", "idle", name: "named-session")
    claude(dead, "s4", "busy")
    store.reload()
    func status(_ sid: String) -> Status? { store.sessions.first { $0.id == sid }?.status }
    check("B1a waiting -> asks", status("s1") == .asking)
    check("B1b busy -> working", status("s2") == .working)
    check("B1c idle from the start -> ready", status("s3") == .idle)
    check("B1d dead pid -> gone", status("s4") == nil, "\(store.sessions.map(\.id))")
    check("B1e waiting session -> one observed ask", store.asks.count == 1 && store.asks[0].kind == .observed && store.asks[0].body == "Permission prompt",
          "\(store.asks.map { ($0.kind, $0.body) })")
    check("B1f Claude's session name is used", store.sessions.first { $0.id == "s3" }?.name == "named-session")
    claude(me, "s2", "idle"); store.reload()
    check("B1g idle after busy -> your turn", status("s2") == .done)
    claude(me, "s1", "busy"); store.reload()
    check("B1h answered in terminal (waiting -> busy) -> ask gone at once", status("s1") == .working && store.asks.isEmpty)
    let heldID = request("s3", "Bash", ["command": "ls"]); store.reload()
    check("B1i held request -> asks even while Claude is idle/busy", status("s3") == .asking && store.asks.first?.held == true)
    check("B1j held request -> lock on", store.locked && lockEvents.last == true)
    let deadID = request("s3", "Bash", ["command": "pwd"], helper: dead); store.reload()
    check("B1k request with dead helper -> dropped + file deleted", !store.asks.contains { $0.id == deadID } && !fm.fileExists(atPath: requestFile(deadID).path))
    _ = heldID
    clearAll(); store.reload()
    check("B1l nothing held -> lock off", !store.locked && lockEvents.last == false)

    // ---- B1 debounce: a brief "waiting" (Claude handing a request to the hooks) is not a card
    store.waitDebounce = 0.7
    clearAll(); claude(me, "fl", "waiting", waiting: "permission prompt"); store.reload()
    check("B1m brief waiting -> no card yet, shown as working", store.asks.isEmpty && store.sessions.first { $0.id == "fl" }?.status == .working)
    Thread.sleep(forTimeInterval: 0.8); store.reload()
    check("B1n waiting that lasts 0.7 s -> card", store.asks.first?.kind == .observed)
    claude(me, "fl", "busy"); store.reload(); claude(me, "fl", "waiting"); store.reload()
    check("B1o a new wait starts its own debounce", store.asks.isEmpty)
    store.waitDebounce = 0; clearAll(); store.reload()

    // ---- B2 permission answers
    claude(me, "p", "busy")
    func permCase(_ name: String, sugg: Bool = true, _ act: (Store) -> Void, _ expect: ([String: Any]) -> Bool) {
        let id = request("p", "Bash", ["command": "npm run build"], sugg: sugg)
        store.reload(); store.select(id)
        act(store)
        let r = response(id)
        check(name, r.map(expect) ?? false, "\(String(describing: r))")
        store.reload()
    }
    permCase("B2a ⌘↩ -> allow", { $0.choose(0) }) { $0["action"] as? String == "allow" && $0["updatedPermissions"] == nil }
    permCase("B2b ⌘1 -> allow", { $0.choose(1) }) { $0["action"] as? String == "allow" }
    permCase("B2c ⌘2 -> allow + Claude's suggested rule", { $0.choose(2) }) {
        $0["action"] as? String == "allow" && (($0["updatedPermissions"] as? [[String: Any]])?.first?["type"] as? String) == "addRules"
    }
    permCase("B2d ⌘3 + text -> deny with message", { $0.choose(3); $0.draft = "use pnpm"; $0.submitDraft() }) {
        $0["action"] as? String == "deny" && $0["message"] as? String == "use pnpm"
    }
    permCase("B2e no suggestion: ⌘2 is 'No, tell Claude'", sugg: false, { $0.choose(2); $0.draft = "no"; $0.submitDraft() }) {
        $0["action"] as? String == "deny"
    }
    permCase("B2f Esc -> handoff to terminal", { $0.escape() }) { $0["action"] as? String == "handoff" }
    permCase("B2g Esc in text field closes it, second Esc hands off", { $0.choose(3); $0.escape(); $0.escape() }) {
        $0["action"] as? String == "handoff"
    }

    // ---- B2 questions
    let twoQ: [String: Any] = ["questions": [
        ["question": "Pick a color", "multiSelect": false, "options": [["label": "Red"], ["label": "Blue"]]],
        ["question": "Pick fruits", "multiSelect": true, "options": [["label": "Apple"], ["label": "Pear"], ["label": "Plum"]]]]]
    func qCase(_ name: String, _ act: (Store) -> Void, _ expect: [String: String]) {
        let id = request("p", "AskUserQuestion", twoQ)
        store.reload(); store.select(id)
        act(store)
        let r = response(id)
        let answers = (r?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]
        let keptQuestions = ((r?["updatedInput"] as? [String: Any])?["questions"] as? [Any])?.count == 2
        check(name, r?["action"] as? String == "allow" && answers == expect && keptQuestions, "\(String(describing: r))")
        store.reload()
    }
    qCase("B2h single ⌘↩ = first option, multi toggles + ⌘↩", { s in
        s.choose(0)                      // Red
        s.choose(1); s.choose(3)         // Apple + Plum
        s.choose(0)                      // submit
    }, ["Pick a color": "Red", "Pick fruits": "Apple, Plum"])
    qCase("B2i ⌘2 picks Blue; multi toggle on/off", { s in
        s.choose(2)
        s.choose(2); s.choose(2); s.choose(3)   // Pear on, Pear off, Plum on
        s.choose(0)
    }, ["Pick a color": "Blue", "Pick fruits": "Plum"])
    qCase("B2j Other… with free text on both steps", { s in
        s.choose(3); s.draft = "Green"; s.submitDraft()          // color: Other (3rd row)
        s.choose(4); s.draft = "Mango"; s.submitDraft()          // fruits: Other (4th row)
    }, ["Pick a color": "Green", "Pick fruits": "Mango"])
    do {
        let id = request("p", "AskUserQuestion", twoQ); store.reload(); store.select(id)
        store.choose(1)
        store.choose(0)   // multi step with nothing picked: must not submit
        check("B2k multi ⌘↩ with nothing picked does not submit", readJSON(responseFile(id)) == nil && store.step == 1)
        store.escape(); _ = response(id); store.reload()
    }

    // ---- B2 plan: never held (Claude always shows its own plan dialog), so it is an observed card
    clearAll(); claude(me, "pl", "waiting", waiting: "plan approval")
    store.reload()
    check("B2l plan waiting -> observed card, no lock", store.asks.first?.kind == .observed && !store.locked)
    clearAll(); store.reload()

    // ---- B3 queue
    clearAll()
    claude(me, "q1", "busy"); claude(me, "q2", "waiting", waiting: "input needed")
    let t = Date().timeIntervalSince1970
    let r2 = request("q1", "Bash", ["command": "second"], created: t - 5)
    let r1 = request("q1", "Bash", ["command": "first"], created: t - 10)
    claude(me, "q3", "busy")
    let r3 = request("q3", "Bash", ["command": "third"], created: t - 1)
    store.reload(); store.select(nil); store.reload()
    let ids = store.visibleAsks.map(\.id)
    check("B3a 3 held + 1 observed = 4 asks", store.asks.count == 4, "\(store.asks.count)")
    check("B3b held first, oldest first, observed last", ids.prefix(3) == [r1, r2, r3] && store.asks.last?.kind == .observed, "\(store.asks.map(\.body))")
    check("B3c card starts on the oldest", store.current?.id == r1)
    store.cycle(1); check("B3d Tab -> next", store.current?.id == r2)
    store.cycle(-1); store.cycle(-1); check("B3e ⇧Tab wraps to last", store.current?.kind == .observed)
    store.select(r1); store.choose(0); _ = response(r1); store.reload()
    check("B3f answering advances to the next", store.current?.id == r2 && store.asks.count == 3)
    let obs = store.asks.first { $0.kind == .observed }!
    store.later(obs); store.reload()
    check("B3g Later hides an observed ask (still counted on the chip)", !store.visibleAsks.contains { $0.id == obs.id } && store.asks.count == 3)
    store.select(r2); store.escape(); _ = response(r2); store.reload()
    check("B3h Esc on held hands off, not Later", !store.laterIDs.contains(r2))

    // ---- B4 lock
    check("B4a lock stays while a held ask remains", store.locked)
    store.holdOn = false; store.reload()
    check("B4b Answer-from-Nudge off -> held asks handed back + lock off", !store.locked && readJSON(responseFile(r3))?["action"] as? String == "handoff")
    _ = response(r3)
    store.holdOn = true
    clearAll(); claude(me, "l", "busy"); let lr = request("l", "Bash", ["command": "x"]); store.lockOn = false; store.reload()
    check("B4c Lock setting off -> no lock", !store.locked)
    store.lockOn = true; store.reload()
    check("B4d Lock setting on -> lock", store.locked)
    store.select(lr); store.choose(0); _ = response(lr); store.reload()
    check("B4e last answer -> lock off", !store.locked)

    // ---- B5 permission log: decisions, ranges, prune, CSV
    let now = Date().timeIntervalSince1970
    func logReq(_ id: String, _ ago: Double, sid: String = "p1", tool: String = "Bash", helper: Int = me,
                input: String = "{\"command\":\"ls\"}") {
        PermLog.append(["type": "request", "id": id, "t": now - ago, "session_id": sid, "session_name": "proj",
                        "cwd": "/x/proj", "tool": tool, "summary": "ls", "input": input, "helper_pid": helper])
    }
    func logDec(_ id: String, _ ago: Double, _ decision: String, by: String = "nudge") {
        PermLog.append(["type": "decision", "id": id, "t": now - ago, "decision": decision, "by": by])
    }
    try? fm.removeItem(at: Paths.permLog)
    logReq("old", 25 * 3600); logDec("old", 25 * 3600 - 5, "allowed")
    logReq("h23", 23 * 3600); logDec("h23", 23 * 3600 - 4, "allowed")
    logReq("h5", 5 * 3600); logDec("h5", 5 * 3600 - 2, "denied")
    logReq("m90", 90 * 60, sid: "ran"); logDec("m90", 90 * 60 - 1, "handed_to_terminal", by: "terminal")
    PermLog.append(["type": "ran", "id": "m90", "t": now - 80 * 60])
    logReq("m30", 30 * 60, sid: "idle"); logDec("m30", 30 * 60 - 1, "handed_to_terminal", by: "terminal")
    logReq("m10", 10 * 60, sid: "waiting"); logDec("m10", 10 * 60 - 1, "handed_to_terminal", by: "terminal")
    logReq("m5", 5 * 60, sid: "busy"); logDec("m5", 5 * 60 - 1, "handed_to_terminal", by: "terminal")
    logReq("m2", 2 * 60, helper: dead)
    logReq("m1", 60, tool: "AskUserQuestion")
    let live = ["ran": "busy", "idle": "idle", "waiting": "waiting", "busy": "busy", "p1": "busy"]
    func rows(_ hours: Double) -> [PermRow] { PermLog.rows(since: now - hours * 3600, status: { live[$0] }) }
    let byID = Dictionary(uniqueKeysWithValues: rows(48).map { ($0.id, $0) })
    check("B5a decisions from Nudge kept as logged", byID["h23"]?.decision == "allowed" && byID["h5"]?.decision == "denied")
    check("B5b terminal + ran -> allowed_in_terminal", byID["m90"]?.decision == "allowed_in_terminal" && byID["m90"]?.decidedBy == "terminal")
    check("B5c terminal, session idle -> not_run", byID["m30"]?.decision == "not_run")
    check("B5d terminal, session waiting -> waiting_in_terminal", byID["m10"]?.decision == "waiting_in_terminal")
    check("B5e terminal, session busy -> in_progress", byID["m5"]?.decision == "in_progress")
    check("B5f held by a dead helper -> cancelled; live helper -> pending", byID["m2"]?.decision == "cancelled" && byID["m1"]?.decision == "pending_in_nudge")
    check("B5g AskUserQuestion -> kind question", byID["m1"]?.kind == "question")
    let counts = [1, 2, 6, 12, 24].map { rows(Double($0)).count }
    check("B5h counts for 1/2/6/12/24 h", counts == [5, 6, 7, 7, 8], "\(counts)")
    check("B5i rows oldest first", rows(24).map(\.id) == ["h23", "h5", "m90", "m30", "m10", "m5", "m2", "m1"], "\(rows(24).map(\.id))")
    PermLog.prune(now: now)
    let left = Set(PermLog.events().compactMap { $0["id"] as? String })
    check("B5j prune drops requests older than 24 h with their events", !left.contains("old") && left.contains("h23"), "\(left)")

    let model = ExportModel(status: { live[$0] })
    model.refresh()
    model.preset = 6; check("B5k export model preset 6 h -> 7", model.selected.count == 7, "\(model.selected.count)")
    model.preset = nil; model.custom = 2; check("B5l custom 2 h -> 6", model.selected.count == 6, "\(model.selected.count)")
    model.custom = 30; check("B5m custom clamps to 24", model.custom == 24 && model.selected.count == 8)
    model.custom = 0; check("B5n custom clamps to 1", model.custom == 1 && model.selected.count == 5)

    var tricky = PermRow(id: "c", requested: now)
    tricky.summary = "echo \"a, b\"\nnext"
    tricky.decided = now + 2.5
    tricky.autoMode = "quick"; tricky.autoDelay = 0.307
    let csv = PermCSV.make([tricky])
    /// Minimal RFC 4180 reader for the round trip.
    func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false
        var it = Array(text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text)[...]
        while let c = it.popFirst() {
            if quoted {
                if c == "\"" { if it.first == "\"" { field.append("\""); it.removeFirst() } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" { quoted = true }
            else if c == "," { row.append(field); field = "" }
            else if c == "\r\n" || c == "\n" { row.append(field); rows.append(row); row = []; field = "" }
            else { field.append(c) }
        }
        return rows
    }
    let parsed = parse(csv)
    let col = { (name: String) in PermCSV.columns.firstIndex(of: name)! }
    check("B5o CSV has BOM + header", csv.hasPrefix("\u{FEFF}requested_at,session_name,"))
    check("B5p CSV round-trips commas, quotes, newlines", parsed.count == 2 && parsed[1][col("summary")] == tricky.summary, "\(parsed)")
    check("B5q wait_seconds", parsed.count == 2 && parsed[1][col("wait_seconds")] == "2.5")
    check("B5r auto_mode + auto_delay_seconds columns", parsed.count == 2 && parsed[1][col("auto_mode")] == "quick"
          && parsed[1][col("auto_delay_seconds")] == "0.307", "\(parsed)")
    // Rows from the log: mode as stamped, and inferred for logs written before modes existed.
    for (id, stamp, delay) in [("am1", "normal", 9.0), ("am2", "", 0.3), ("am3", "", 7.0), ("am4", "quick", 0.2)] {
        var req: [String: Any] = ["type": "request", "id": id, "t": now, "session_id": "s", "tool": "Bash"]
        if !stamp.isEmpty { req["auto_mode"] = stamp }
        PermLog.append(req)
        PermLog.append(["type": "decision", "id": id, "t": now + delay, "by": "nudge_auto", "decision": "auto_allowed", "auto_delay": delay])
    }
    PermLog.append(["type": "request", "id": "am5", "t": now, "session_id": "s", "tool": "Bash", "auto_mode": "normal"])
    PermLog.append(["type": "decision", "id": "am5", "t": now + 3, "by": "nudge", "decision": "denied"])
    let am = Dictionary(uniqueKeysWithValues: PermLog.rows(since: 0, status: { _ in nil }).map { ($0.id, $0) })
    check("B5s auto modes from the log (stamped, inferred, manual while on)",
          am["am1"]?.autoMode == "normal" && am["am2"]?.autoMode == "quick" && am["am3"]?.autoMode == "normal"
          && am["am4"]?.autoMode == "quick" && am["am4"]?.autoDelay == 0.2 && am["am5"]?.autoMode == "normal" && am["am5"]?.autoDelay == nil,
          "\(am.mapValues { "\($0.autoMode) \(String(describing: $0.autoDelay))" })")

    // ---- B6 auto-approval (authentication is the window's job; startAuto is called directly)
    clearAll(); store.holdOn = true; store.lockOn = true
    claude(me, "a", "busy")
    let ago = { (s: Double) in Date().timeIntervalSince1970 - s }
    store.startAuto(hours: 30, questions: false)
    check("B6a capped at 24 h", abs((store.autoUntil?.timeIntervalSinceNow ?? 0) - 24 * 3600) < 5)
    let t0 = ago(0)
    let fresh = request("a", "Bash", ["command": "make"], created: t0); store.reload()
    let due = store.autoDue[fresh]
    check("B6b due 1–15 s after it was asked", due.map { (1...15).contains($0.delay) && $0.delay == $0.delay.rounded() && abs($0.at.timeIntervalSince1970 - (t0 + $0.delay)) < 0.01 } == true,
          "\(String(describing: due))")
    check("B6c not answered before it's due", readJSON(responseFile(fresh)) == nil)
    check("B6d an auto-handled ask doesn't lock the screen", !store.locked)
    _ = response(fresh)

    store.stopAuto(); store.startAuto(hours: 6, questions: false, now: Date(timeIntervalSince1970: ago(300)))
    let late = request("a", "Bash", ["command": "late"], created: ago(200), sugg: true); store.reload()
    let lr2 = response(late)
    check("B6e due -> allowed, marked auto, no rules added",
          lr2?["action"] as? String == "allow" && lr2?["auto"] as? Bool == true && lr2?["updatedPermissions"] == nil, "\(String(describing: lr2))")
    let q = request("a", "AskUserQuestion", ["questions": [["question": "Color?", "options": [["label": "Red"], ["label": "Blue"]]]]], created: ago(200))
    store.reload()
    check("B6f questions left for you by default (and they lock)", readJSON(responseFile(q)) == nil && store.locked)
    store.startAuto(hours: 6, questions: true, now: Date(timeIntervalSince1970: ago(300))); store.reload()
    let qr = response(q)
    check("B6g questions on -> first option sent", ((qr?["updatedInput"] as? [String: Any])?["answers"] as? [String: String]) == ["Color?": "Red"],
          "\(String(describing: qr))")
    let man = request("a", "Bash", ["command": "manual"], created: ago(0)); store.reload()
    store.select(man); store.choose(2); store.draft = "not now"; store.submitDraft(); store.reload()
    check("B6h your deny before it's due wins", response(man)?["action"] as? String == "deny")

    store.stopAuto(); store.startAuto(hours: 6, questions: false, now: Date(timeIntervalSince1970: ago(6 * 3600 + 1))); store.reload()
    check("B6i expiry turns it off", store.autoUntil == nil && !store.autoOn)
    store.startAuto(hours: 1, questions: false); store.holdOn = false; store.reload()
    check("B6j turning off Answer from Nudge stops it", store.autoUntil == nil)
    store.holdOn = true
    UserDefaults.standard.set(ago(-25 * 3600), forKey: "autoUntil")
    check("B6k resume ignores an end time > 24 h away", Store().autoUntil == nil)
    UserDefaults.standard.set(ago(-3600), forKey: "autoUntil")
    let resumed = Store()
    check("B6l resume within 6 h", resumed.autoOn)
    resumed.stopAuto()
    check("B6m stop clears the saved end time", UserDefaults.standard.object(forKey: "autoUntil") == nil)
    store.startAuto(hours: 1, questions: false, awake: true)
    check("B6n awake option is held with auto-approval and cleared after", store.autoAwake)
    store.stopAuto()
    check("B6o awake option ends with auto-approval", !store.autoAwake)

    // Quick mode: answered after 0.15–0.6 s, never instantly, always under 1 s.
    store.startAuto(hours: 1, questions: false, quick: true)
    check("B6p quick flag held", store.autoQuick)
    let qt = Date().timeIntervalSince1970
    let quick = request("a", "Bash", ["command": "quick"], created: qt); store.reload()
    let qd = store.autoDue[quick]
    check("B6q quick due 0.15–0.6 s after it was asked", qd.map { Store.quickDelay.contains($0.delay) } == true, "\(String(describing: qd))")
    check("B6r quick: not answered instantly", readJSON(responseFile(quick)) == nil)
    let qst = ChipState(store)
    renderChip(store, "approving")
    check("B6u quick: no card, not counted as an ask, no lock", store.current == nil && store.openAsks.isEmpty && !store.locked)
    check("B6v quick: chip says APPROVING in orange orbit", qst.kind == .approving && qst.base == "APPROVING" && qst.icons.contains(.quick) && !qst.icons.contains(.auto) && !(qst.word ?? "").contains("AUTO"), "\(qst.kind) \(String(describing: qst.word))")
    var answeredAt: Double?
    while Date().timeIntervalSince1970 - qt < 1.5 && answeredAt == nil {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        if readJSON(responseFile(quick)) != nil { answeredAt = Date().timeIntervalSince1970 }
    }
    let took = (answeredAt ?? .infinity) - qt
    let qresp = response(quick)
    check("B6s quick answered in 0.15–1 s, marked auto", took >= 0.15 && took < 1 && qresp?["auto"] as? Bool == true, "took \(took)s \(String(describing: qresp))")
    store.reload()
    check("B6w APPROVING held briefly after the answer", store.approving)
    RunLoop.main.run(until: Date(timeIntervalSince1970: qt + Store.approvingMin + 0.3)); store.reload()
    let after = ChipState(store)
    renderChip(store, "working")
    check("B6x then back to WORKING", !store.approving && after.kind == .working, "\(after.kind) \(String(describing: after.word))")
    let mq = request("a", "AskUserQuestion", ["questions": [["question": "Pick?", "options": [["label": "A"]]]]], created: ago(0)); store.reload()
    check("B6y quick without questions: questions still open a card", store.current?.id == mq && ChipState(store).word?.hasPrefix("ASKS") == true)
    _ = response(mq)
    check("B6t1 quick writes auto-mode for the helper", currentAutoMode() == "quick")
    store.stopAuto()
    check("B6t quick cleared on stop", !store.autoQuick && UserDefaults.standard.object(forKey: "autoQuick") == nil)
    check("B6t2 stop -> auto-mode off", currentAutoMode() == "off")
    store.startAuto(hours: 1, questions: false, awake: true); store.reload()
    let normal = ChipState(store)
    check("B6z normal auto: check icon, no AUTO word, awake eye first when held",
          normal.icons.last == .auto && !normal.icons.contains(.quick) && normal.icons.contains(.awake) == store.keepingAwake
          && (normal.icons.first == .awake) == store.keepingAwake && !(normal.word ?? "").contains("AUTO"), "\(normal.icons) \(String(describing: normal.word))")
    renderChip(store, "working-normal")
    store.stopAuto(); store.reload()
    check("B6z2 no auto: no auto icon", !ChipState(store).icons.contains(.auto))

    // ---- B7 nudge:// links
    let P = { (u: String) in NudgeCommand.parse(URL(string: u)!) }
    check("B7a awake on/off, auto off", P("nudge://awake/on") == .awake(true) && P("nudge://awake/off") == .awake(false) && P("nudge://auto/off") == .autoOff)
    check("B7b auto on defaults", P("nudge://auto/on") == .autoOn(hours: 2, quick: false, questions: false, awake: true), "\(String(describing: P("nudge://auto/on")))")
    check("B7c auto on quick 24 h with options", P("nudge://auto/on?mode=quick&hours=24&questions=1&awake=0") == .autoOn(hours: 24, quick: true, questions: true, awake: false))
    check("B7d hours clamp + snap (99->24, 3->4, 0->1)",
          P("nudge://auto/on?hours=99") == .autoOn(hours: 24, quick: false, questions: false, awake: true)
          && P("nudge://auto/on?hours=3") == .autoOn(hours: 4, quick: false, questions: false, awake: true)
          && P("nudge://auto/on?hours=0") == .autoOn(hours: 1, quick: false, questions: false, awake: true))
    check("B7e unknown links ignored", P("nudge://auto/maybe") == nil && P("nudge://rm/rf") == nil && P("https://auto/on") == nil)
    store.awakeOn = true
    store.run(.awake(false)); let wasOff = !store.awakeOn
    store.run(.awake(true))
    check("B7f awake link flips Stay awake", wasOff && store.awakeOn)
    store.startAuto(hours: 1, questions: false); store.run(.autoOff)
    check("B7g auto off link stops auto-approval", !store.autoOn)
    check("B7h auto on link alone never turns it on (needs Touch ID)", {
        // Only the parse is exercised here: run(.autoOn) would bring up the real confirmation sheet.
        if case .autoOn = P("nudge://auto/on?mode=quick")! { return !store.autoOn } else { return false }
    }())

    // ---- B8 self-update
    check("B8a update.sh output parsed", Updater.parse("noise\nREADY abc1234\n") == .ready("abc1234")
          && Updater.parse("UPTODATE d5d3019") == .upToDate("d5d3019") && Updater.parse("SKIP uncommitted changes") == .skipped("uncommitted changes")
          && Updater.parse("FAIL Suite B failed at x") == .failed("Suite B failed at x") && Updater.parse("") == .failed("no answer from update.sh"))
    check("B8b a test/build copy never updates itself", !Updater().enabled)

    // ---- B9 Claude settings: consent, edge cases, removal sticks
    let settings = URL(fileURLWithPath: root + "/claude/settings.json")
    func settingsObj() -> [String: Any] { readJSON(settings) ?? [:] }
    func ours(_ o: [String: Any]) -> Int {
        ((o["hooks"] as? [String: Any]) ?? [:]).values.flatMap { ($0 as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { HookInstaller.isOurs($0["command"]) }.count
    }
    UserDefaults.standard.removeObject(forKey: "hooksOptOut"); UserDefaults.standard.removeObject(forKey: "welcomeDone")
    check("B9a no settings yet -> ask first (Welcome), nothing written", HookInstaller.launchAction() == .welcome && !fm.fileExists(atPath: settings.path))
    check("B9a2 nothing to back up yet", HookInstaller.install() == nil && !fm.fileExists(atPath: root + "/claude/settings.json.before-nudge"))
    HookInstaller.uninstall(); writeJSON(["model": "sonnet"], to: settings)
    check("B9b install keeps your settings", HookInstaller.install() == nil && ours(settingsObj()) == HookInstaller.entries.count)
    check("B9c installed -> refresh on launch", HookInstaller.launchAction() == .refresh)
    HookInstaller.install()
    check("B9d install is idempotent", ours(settingsObj()) == HookInstaller.entries.count)
    // Your own hook sharing a group with ours, plus unrelated keys.
    var o = settingsObj()
    var hooks = o["hooks"] as! [String: Any]
    var pre = hooks["PreToolUse"] as! [[String: Any]]
    var g = pre[0]; g["hooks"] = (g["hooks"] as! [[String: Any]]) + [["type": "command", "command": "my-linter"]]
    pre[0] = g; hooks["PreToolUse"] = pre; o["hooks"] = hooks; o["model"] = "opus"
    writeJSON(o, to: settings)
    check("B9e remove keeps your hook in a shared group and other keys", HookInstaller.uninstall() == nil && ours(settingsObj()) == 0
          && settingsObj()["model"] as? String == "opus"
          && (try? String(contentsOf: settings, encoding: .utf8))?.contains("my-linter") == true)
    check("B9f removal sticks across launches", HookInstaller.launchAction() == .none)
    check("B9g backup is the file before Nudge", (try? String(contentsOfFile: root + "/claude/settings.json.before-nudge", encoding: .utf8)).map { !$0.contains("hook.sh") && $0.contains("sonnet") } == true)
    try? "{ // comment\n \"a\": 1 }".write(to: settings, atomically: true, encoding: .utf8)
    let bad = HookInstaller.install()
    check("B9h unparseable settings untouched, problem reported", bad != nil && (try? String(contentsOf: settings, encoding: .utf8))?.hasPrefix("{ // comment") == true)
    writeJSON(["hooks": ["PreToolUse": "nope"]], to: settings)
    check("B9i odd hooks shape untouched, problem reported", HookInstaller.install() != nil && (settingsObj()["hooks"] as? [String: Any])?["PreToolUse"] as? String == "nope")
    try? fm.removeItem(at: settings)
    let real = URL(fileURLWithPath: root + "/claude/dotfiles-settings.json")
    writeJSON(["theme": "dark"], to: real)
    try? fm.createSymbolicLink(at: settings, withDestinationURL: real)
    HookInstaller.install()
    check("B9j symlinked settings: link kept, real file edited",
          (try? fm.destinationOfSymbolicLink(atPath: settings.path)) != nil && ours(readJSON(real) ?? [:]) == HookInstaller.entries.count)
    try? fm.removeItem(at: settings); try? fm.removeItem(at: real)
    UserDefaults.standard.removeObject(forKey: "hooksOptOut"); UserDefaults.standard.removeObject(forKey: "welcomeDone")

    // ---- B10 held requests: no status file, and answers after the helper gave up
    clearAll()
    let orphan = request("no-status-file", "Bash", ["command": "make"])
    store.reload()
    check("B10a held request without a Claude status file still shows a card", store.asks.contains { $0.id == orphan })
    if store.asks.contains(where: { $0.id == orphan }) {
        store.select(orphan)
        try? fm.removeItem(at: requestFile(orphan))       // the helper timed out meanwhile
        store.choose(0)
        check("B10b answer to a request the helper gave up on writes nothing", !fm.fileExists(atPath: responseFile(orphan).path))
    } else { check("B10b answer to a request the helper gave up on writes nothing", false) }
    writeJSON(["action": "allow"], to: responseFile("stale"))
    try? fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -120)], ofItemAtPath: responseFile("stale").path)
    PermLog.prune()
    check("B10c stale answers swept", !fm.fileExists(atPath: responseFile("stale").path))
    clearAll(); store.reload()

    // ---- B11 release updates
    check("B11a versions compare numerically", Updater.isNewer("1.10.0", than: "1.9.3") && !Updater.isNewer("1.0", than: "1.0.0") && !Updater.isNewer("0.9", than: "1.0"))
    let relJSON = #"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"assets":[{"name":"Nudge-1.2.0.dmg","browser_download_url":"https://x/d"},{"name":"Nudge-1.2.0.zip","browser_download_url":"https://x/z"},{"name":"SHA256SUMS","browser_download_url":"https://x/s"}]}"#
    let rel = Updater.parseRelease(Data(relJSON.utf8))
    check("B11b latest release parsed", rel?.version == "1.2.0" && rel?.zip.absoluteString == "https://x/z" && rel?.sums.absoluteString == "https://x/s")
    check("B11c drafts and prereleases ignored", Updater.parseRelease(Data(relJSON.replacingOccurrences(of: #""prerelease":false"#, with: #""prerelease":true"#).utf8)) == nil)
    check("B11d checksum line found", Updater.expectedHash("abc  Nudge-1.2.0.dmg\nDEF  Nudge-1.2.0.zip\n", for: "Nudge-1.2.0.zip") == "def")
    check("B11e an ad-hoc build has no team, so it can't pass the team check", Updater.teamID(of: URL(fileURLWithPath: "/bin/ls")) == nil
          && !Updater.verify(URL(fileURLWithPath: "/System/Applications/Calculator.app"), team: "ABCDE12345"))

    // ---- B12 attach script quoting
    check("B12 shell quoting", shellQuote("a\"$(x)'b") == "'a\"$(x)'\\''b'")

    // ---- B13 first run: bottom-right, Hello, then Welcome; login item; Welcome icons
    let d = UserDefaults.standard
    for k in ["anchorX", "anchorY", "pinRight", "pinBottom", "x", "y"] { d.removeObject(forKey: k) }
    let first = Store(); first.loadAnchor()
    let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
    check("B13a first spot is bottom-right, card opens above", first.pinRight && first.pinBottom
          && first.anchor.x == vis.maxX - 12 && first.anchor.y == vis.minY + 12, "\(first.anchor)")
    d.removeObject(forKey: "helloDone"); d.removeObject(forKey: "welcomeDone"); d.removeObject(forKey: "hooksOptOut")
    try? fm.removeItem(at: settings)
    check("B13b fresh install greets", Store.greets(HookInstaller.launchAction()))
    check("B13c set up before: no hello", !Store.greets(.refresh) && !Store.greets(.none))
    clearAll()
    var welcomed = 0
    store.onHelloDone = { welcomed += 1 }
    store.startAuto(hours: 1, questions: true, quick: true)
    store.showHello()
    store.reload(); store.reload()
    check("B13d hello shows as the current ask and survives polling",
          store.current?.kind == .hello && store.asks.filter { $0.kind == .hello }.count == 1)
    check("B13e hello is never auto-answered", store.asks.first.map { !store.autoHandles($0) && !store.quiet($0) } == true)
    check("B13f pill says HELLO", ChipState(store).kind == .hello && ChipState(store).word == "HELLO")
    store.openCurrent()
    check("B13g ⌘O does nothing to hello", store.helloPending && welcomed == 0)
    store.choose(0)
    let respFiles = (try? fm.contentsOfDirectory(atPath: root + "/responses")) ?? []
    check("B13h ⌘↩ yes: hello gone, remembered, Welcome next, nothing written",
          !store.helloPending && !store.asks.contains { $0.kind == .hello } && d.bool(forKey: "helloDone")
          && welcomed == 1 && respFiles.isEmpty, "\(respFiles)")
    check("B13i greeted once only", !Store.greets(.welcome))
    store.reload()
    check("B13j stays gone after polling", !store.asks.contains { $0.kind == .hello })
    store.stopAuto()
    d.removeObject(forKey: "helloDone")
    store.showHello(); store.escape()
    check("B13k esc also finishes hello", !store.helloPending && d.bool(forKey: "helloDone"))
    d.removeObject(forKey: "helloDone"); d.removeObject(forKey: "welcomeDone")

    d.removeObject(forKey: "loginOptOut")
    check("B13l login item registers from /Applications", LoginItem.shouldRegister(bundlePath: "/Applications/Nudge.app"))
    check("B13m not from a build folder or DMG", !LoginItem.shouldRegister(bundlePath: "/Volumes/Nudge/Nudge.app"))
    LoginItem.optedOut = true
    check("B13n turning it off sticks", !LoginItem.shouldRegister(bundlePath: "/Applications/Nudge.app"))
    d.removeObject(forKey: "loginOptOut")

    let mA = MatrixFrames.bolt.still, mB = ["......."] + MatrixFrames.check.still
    let m = MatrixFrames.morph(mA, mB, steps: 5)
    func diff(_ x: [String], _ y: [String]) -> Int { zip(x, y).map { zip($0, $1).filter { $0 != $1 }.count }.reduce(0, +) }
    let total = diff(mA, mB)
    check("B13o morph ends on the target, in even steps", m.count == 5 && m.last == mB
          && zip([mA] + m, m).allSatisfy { diff($0, $1) <= (total + 4) / 5 && diff($0, $1) > 0 })
    func even(_ f: MatrixFrames) -> Bool {
        let w = f.still.first?.count ?? 0
        return (f.frames + [f.still]).allSatisfy { g in g.count == f.still.count && g.allSatisfy { $0.count == w } }
    }
    check("B13p eye, auto and bubble grids are rectangular and sized like their stills",
          even(.eyeLook) && even(.autoMorph) && even(.bubble) && MatrixFrames.eyeLook.frames.contains(MatrixFrames.eyeClosed))

    try? fm.removeItem(atPath: root)
    print("\nSuite B: \(passed)/\(passed + failed) passed")
    exit(failed == 0 ? 0 : 1)
}}
