import AppKit
import CryptoKit
import Security

/// Keeps the installed Nudge up to date, in one of two ways:
///
/// - **Release** (the DMG from GitHub Releases): reads the latest release, downloads its zip,
///   checks the SHA-256 against the release's SHA256SUMS, and installs it only if it is signed by
///   the same Developer ID team as the running app and passes Gatekeeper (notarized).
/// - **Git** (built from a source checkout by build.sh, which records NudgeSourceDir): runs
///   `update.sh check` in that folder — pull origin/main if the folder is clean, build, run both
///   test suites — and installs only on "READY". Off by default: it runs whatever lands on main.
///
/// Either way an update installs only once no question is being held, so a relaunch never drops one.
/// Only the copy in /Applications updates itself.
final class Updater {
    enum State: Equatable {
        case idle, checking, upToDate(String), ready(String), skipped(String), failed(String)
    }
    enum Mode: Equatable { case git, release, none }

    static let startupDelay: TimeInterval = 20
    static let repo = (Bundle.main.object(forInfoDictionaryKey: "NudgeRepo") as? String) ?? "ulvosama/nudge"
    static var repoPage: URL { URL(string: "https://github.com/\(repo)")! }

    private(set) var state: State = .idle { didSet { onChange?() } }
    var onChange: (() -> Void)?
    private var running = false

    let sourceDir: String?
    let commit: String?
    let version: String
    let enabled: Bool
    let mode: Mode
    /// The unpacked, verified release waiting to be installed (release mode).
    private var staged: URL?

    init(bundle: Bundle = .main) {
        sourceDir = bundle.object(forInfoDictionaryKey: "NudgeSourceDir") as? String
        commit = bundle.object(forInfoDictionaryKey: "NudgeCommit") as? String
        version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        mode = Self.mode(sourceDir: sourceDir, bundle: bundle)
        enabled = mode != .none && bundle.bundlePath.hasPrefix("/Applications/")
            && ProcessInfo.processInfo.environment["NUDGE_HOME"] == nil
    }

    static func defaultMode() -> Mode { mode(sourceDir: Bundle.main.object(forInfoDictionaryKey: "NudgeSourceDir") as? String, bundle: .main) }

    private static func mode(sourceDir: String?, bundle: Bundle) -> Mode {
        if let d = sourceDir, FileManager.default.isExecutableFile(atPath: (d as NSString).appendingPathComponent("update.sh")) {
            return .git
        }
        return teamID(of: bundle.bundleURL) != nil ? .release : .none
    }

    var script: String? {
        guard let d = sourceDir else { return nil }
        let s = (d as NSString).appendingPathComponent("update.sh")
        return FileManager.default.isExecutableFile(atPath: s) ? s : nil
    }

    /// One menu line describing the state.
    var summary: String {
        let v = "Nudge \(version)" + (mode == .git ? " · \(commit ?? "?")" : "")
        switch state {
        case .idle: return v
        case .checking: return "\(v) · checking for updates…"
        case .upToDate: return "\(v) · up to date"
        case .ready(let h): return "Update \(h) ready · installs when no question is waiting"
        case .skipped(let why): return "\(v) · \(why)"
        case .failed(let why): return "\(v) · update not installed: \(why)"
        }
    }

    func check() {
        guard enabled, !running else { return }
        running = true
        state = .checking
        let mode = self.mode, installed = commit ?? "", version = self.version
        DispatchQueue.global(qos: .utility).async {
            var staged: URL?
            let state: State
            if mode == .git, let script = self.script {
                let (out, _) = Self.run(script, ["check", installed], timeout: 900)
                state = Self.parse(out)
                Self.log("check \(installed) -> \(out.trimmingCharacters(in: .whitespacesAndNewlines))")
            } else {
                (state, staged) = Self.checkRelease(current: version)
                Self.log("release check \(version) -> \(state)")
            }
            DispatchQueue.main.async {
                self.running = false
                self.staged = staged
                self.state = state
            }
        }
    }

    /// Start the installer (it waits for this process to exit), then quit.
    func install(beforeQuit: () -> Void) {
        guard case .ready(let h) = state else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        if mode == .git, let script {
            p.arguments = [script, "install", String(getpid())]
        } else if let staged, let team = Self.teamID(of: Bundle.main.bundleURL) {
            let dest = Bundle.main.bundleURL
            guard FileManager.default.isWritableFile(atPath: dest.deletingLastPathComponent().path) else {
                state = .failed("no permission to replace \(dest.path); install the update by hand")
                return
            }
            p.arguments = ["-c", Self.swapScript, "nudge-update", String(getpid()), staged.path, dest.path,
                           team, Bundle.main.bundleIdentifier ?? ""]
        } else { return }
        Self.log("install \(h)")
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { state = .failed("couldn't start installer"); return }
        beforeQuit()
        NSApp.terminate(nil)
    }

    /// $1 pid to wait for, $2 staged app, $3 installed app, $4 team id, $5 bundle id.
    /// The staged copy is copied next to the installed one and verified **again** there (it may have
    /// sat in a temp folder for hours), then swapped in; on any failure the old app is relaunched.
    static let swapScript = #"""
    for _ in $(seq 1 150); do kill -0 "$1" 2>/dev/null || break; sleep 0.2; done
    new="$3.new-$$"; old="$3.old-$$"
    rm -rf "$new"
    req="=anchor apple generic and identifier \"$5\" and certificate leaf[subject.OU] = \"$4\""
    if ditto --noextattr --noqtn "$2" "$new" && codesign --verify --deep --strict -R "$req" "$new" && mv "$3" "$old"; then
      if mv "$new" "$3"; then rm -rf "$old"; else mv "$old" "$3"; fi
    fi
    rm -rf "$new" "$2"
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$3"
    open "$3"
    """#

    // MARK: Release mode

    /// "1.2.0" vs "1.10.0": numeric, field by field.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    struct Release { let version: String; let zip: URL; let sums: URL }

    /// The GitHub "latest release" JSON → version and the two assets we need.
    static func parseRelease(_ data: Data) -> Release? {
        guard let o = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let tag = o["tag_name"] as? String, o["draft"] as? Bool != true, o["prerelease"] as? Bool != true,
              let assets = o["assets"] as? [[String: Any]] else { return nil }
        func asset(_ match: (String) -> Bool) -> URL? {
            assets.first { match($0["name"] as? String ?? "") }
                .flatMap { $0["browser_download_url"] as? String }.flatMap(URL.init(string:))
        }
        guard let zip = asset({ $0.hasPrefix("Nudge") && $0.hasSuffix(".zip") }),
              let sums = asset({ $0 == "SHA256SUMS" }) else { return nil }
        return Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, zip: zip, sums: sums)
    }

    /// The expected hash for `name` in a SHA256SUMS file ("<hex>  <name>" per line).
    static func expectedHash(_ sums: String, for name: String) -> String? {
        for line in sums.split(separator: "\n") {
            let parts = line.split(separator: " ", omittingEmptySubsequences: true)
            if parts.count == 2, parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "*")) == name {
                return parts[0].lowercased()
            }
        }
        return nil
    }

    private static func checkRelease(current: String) -> (State, URL?) {
        guard let myTeam = teamID(of: Bundle.main.bundleURL) else { return (.skipped("not a signed release build"), nil) }
        let api = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
        guard let data = fetch(api) else { return (.skipped("couldn't reach GitHub"), nil) }
        guard let rel = parseRelease(data) else { return (.skipped("no release found"), nil) }
        guard isNewer(rel.version, than: current) else { return (.upToDate(rel.version), nil) }

        guard let zipData = fetch(rel.zip, timeout: 300), let sumsData = fetch(rel.sums),
              let want = expectedHash(String(decoding: sumsData, as: UTF8.self), for: rel.zip.lastPathComponent)
        else { return (.failed("download failed"), nil) }
        let got = SHA256.hash(data: zipData).map { String(format: "%02x", $0) }.joined()
        guard got == want else { return (.failed("checksum mismatch"), nil) }

        // A fresh private folder (mkdtemp, 0700); the swap script verifies its copy again anyway.
        var tmpl = Array((NSTemporaryDirectory() + "nudge-update-XXXXXX").utf8CString)
        guard let made = mkdtemp(&tmpl) else { return (.failed("couldn't stage"), nil) }
        let dir = URL(fileURLWithPath: String(cString: made))
        let zip = dir.appendingPathComponent("Nudge.zip")
        guard (try? zipData.write(to: zip)) != nil,
              run("/usr/bin/ditto", ["-x", "-k", "--noextattr", "--noqtn", zip.path, dir.path], timeout: 120).1 == 0 else {
            return (.failed("couldn't unpack"), nil)
        }
        let app = dir.appendingPathComponent("Nudge.app")
        guard verify(app, team: myTeam) else { return (.failed("signature check failed"), nil) }
        // The app inside must itself be newer: no replaying an older signed build under a new tag.
        guard let staged = Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              isNewer(staged, than: current) else { return (.failed("release version mismatch"), nil) }
        guard run("/usr/sbin/spctl", ["-a", "-t", "exec", app.path], timeout: 60).1 == 0 else {
            return (.failed("not notarized"), nil)
        }
        return (.ready(rel.version), app)
    }

    /// Valid, untampered, this app (bundle id), and signed with an Apple-issued certificate for `team`.
    static func verify(_ app: URL, team: String, identifier: String = Bundle.main.bundleIdentifier ?? "com.omar.nudge") -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        let text = "anchor apple generic and identifier \"\(identifier)\" and certificate leaf[subject.OU] = \"\(team)\"" as CFString
        guard SecRequirementCreateWithString(text, [], &req) == errSecSuccess else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }

    /// The Developer ID team of a signed bundle; nil for ad-hoc builds.
    static func teamID(of url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any] else { return nil }
        return dict[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func fetch(_ url: URL, timeout: TimeInterval = 30) -> Data? {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Nudge-updater", forHTTPHeaderField: "User-Agent")
        let sem = DispatchSemaphore(value: 0)
        var out: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { out = data }
            sem.signal()
        }.resume()
        sem.wait()
        return out
    }

    // MARK: Git mode

    static func parse(_ out: String) -> State {
        let line = out.split(separator: "\n").last.map(String.init) ?? ""
        let word = line.prefix { $0 != " " }
        let rest = String(line.dropFirst(word.count)).trimmingCharacters(in: .whitespaces)
        switch word {
        case "READY": return .ready(rest)
        case "UPTODATE": return .upToDate(rest)
        case "SKIP": return .skipped(rest)
        case "FAIL": return .failed(rest)
        default: return .failed(line.isEmpty ? "no answer from update.sh" : line)
        }
    }

    private static func run(_ script: String, _ args: [String], timeout: TimeInterval) -> (String, Int32) {
        let p = Process()
        if script.hasSuffix(".sh") {
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = [script] + args
        } else {
            p.executableURL = URL(fileURLWithPath: script)
            p.arguments = args
        }
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return ("FAIL couldn't run \(script)", 1) }
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        return (String(decoding: data, as: UTF8.self), p.terminationStatus)
    }

    /// ~/.nudge/update.log, newest last, kept to the last 200 lines.
    static func log(_ line: String) {
        let url = Paths.root.appendingPathComponent("update.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        let old = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let lines = (old.split(separator: "\n").map(String.init) + ["\(stamp) \(line)"]).suffix(200)
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
