import AppKit
import ServiceManagement

/// The Space helper's launchd agent (Contents/Library/LaunchAgents/md.spacebar.helper.plist), registered by this app.
enum HelperAgent {
    static var service: SMAppService { SMAppService.agent(plistName: HelperIDs.agentPlist) }

    /// `--reregister` and `--helper-status` for install.sh, and `--agent-status`, `--register-agent` and `--unregister-agent` to
    /// diagnose the agent by hand (and a fresh status query for `reregister`); nil when none was asked for.
    static func commandLine(_ args: [String]) -> Int32? {
        if args.contains("--helper-status") {
            print("agent: \(describe(service.status))")
            if let s = ask(timeout: 3, current: false) {
                print("helper: pid \(s.pid) trusted=\(s.trusted) tap=\(s.tap) viewer=\(s.viewer)\(isCurrent(s) ? "" : " stale (running replaced code)")")
            } else { print("helper: not answering") }
            return 0
        }
        if args.contains("--reregister") { return reregister() }
        if args.contains("--agent-status") { print("agent: \(describe(service.status))"); return 0 }
        if args.contains("--unregister-agent") {
            do { try service.unregister() } catch { print("unregister: \(error.localizedDescription)") }
            print("agent: \(describe(service.status))")
            return 0
        }
        if args.contains("--register-agent") {
            do { try service.register() } catch { print("register: \(error.localizedDescription)") }
            print("agent: \(describe(service.status))")
            return 0
        }
        return nil
    }

    /// After spacebar.app is replaced in place the helper stays down until this runs. Without a Team ID, macOS pins the
    /// agent's launch constraint to the helper's code hash when it is registered, and keeps that record (the Background Task
    /// Management item) across unregister and register. The new binary is refused (Launch Constraint Violation, EX_CONFIG)
    /// until launchd has marked the job "needs LWCR update" after a refused launch, and an SMAppService status query made
    /// once that submission is about 10 s old has had the item rebuilt for the binary now on disk; only then does unregister
    /// and register launch it, in about 14 s in all. The old loop unregistered at exactly 10 s each time, before any query
    /// could do that, which is why it failed for minutes. Retries with backoff for up to `limit` seconds; one run at a time.
    static func reregister(limit: TimeInterval = 600) -> Int32 {
        let lock = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/spacebar-helper.lock")
        try? FileManager.default.createDirectory(at: lock.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o600)
        guard fd >= 0 else { say("another reregister is running"); return 3 }
        defer { close(fd) }
        let start = Date()
        let wantHelper = SettingsFile.load().spaceHelper
        if wantHelper, service.status == .enabled, ask(timeout: 3) != nil { say("helper already answering"); return 0 }
        var delay: TimeInterval = 2
        var attempt = 0
        while true {
            attempt += 1
            // A fresh submission, which also stops a helper still running from the replaced bundle (it answers nobody: its
            // code on disk changed). launchd tries the new binary and, when the old constraint refuses it, marks the job.
            try? service.unregister()
            do { try service.register() } catch { say("register: \(error.localizedDescription)") }
            let submitted = Date()
            let st = service.status
            if st == .requiresApproval { say("attempt \(attempt): requires approval in Login Items"); return 2 }
            // With the setting off the helper exits at once, so being registered is all there is to check.
            if st == .enabled, !wantHelper { say("attempt \(attempt): registered (setting off)"); return 0 }
            var marked = false
            let up = waitUntil(15) {
                if ask(timeout: 1) != nil { return true }
                marked = jobProperties().contains("needs LWCR update")
                return marked
            } && !marked
            if up { say("attempt \(attempt): helper answering after \(Int(Date().timeIntervalSince(start))) s"); return 0 }
            if marked {
                // A status query from a fresh process has the item rebuilt for the binary now on disk, but only once the
                // submission is about 10 s old (measured: earlier queries left the item as it was); the next submission
                // carries the new constraint.
                Thread.sleep(forTimeInterval: max(0, 11 - Date().timeIntervalSince(submitted)))
                run(Bundle.main.executablePath ?? "", ["--agent-status"])
                try? service.unregister()
                do { try service.register() } catch { say("register: \(error.localizedDescription)") }
                if waitUntil(10, { ask(timeout: 1) != nil }) {
                    say("attempt \(attempt): helper answering after \(Int(Date().timeIntervalSince(start))) s")
                    return 0
                }
            }
            let elapsed = Date().timeIntervalSince(start)
            say("attempt \(attempt): not answering after \(Int(elapsed)) s (\(marked ? "was marked" : "not marked"); \(jobState()))")
            guard elapsed + delay < limit else { return 1 }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 60)
        }
    }

    static var target: String { "gui/\(getuid())/\(HelperIDs.helper)" }

    private static func say(_ s: String) {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        print("\(f.string(from: Date())) \(s)")
        fflush(stdout)
    }

    private static func waitUntil(_ seconds: TimeInterval, _ ok: () -> Bool) -> Bool {
        let end = Date(timeIntervalSinceNow: seconds)
        repeat {
            if ok() { return true }
            Thread.sleep(forTimeInterval: 0.5)
        } while Date() < end
        return false
    }

    @discardableResult
    private static func launchctl(_ args: [String]) -> String { run("/bin/launchctl", args) }

    private static func jobProperties() -> String {
        launchctl(["print", target]).split(separator: "\n").first { $0.contains("properties = ") }.map(String.init) ?? ""
    }

    private static func jobState() -> String {
        launchctl(["print", target]).split(separator: "\n").first { $0.contains("job state = ") }
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? "not loaded"
    }

    @discardableResult
    private static func run(_ tool: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Whether this copy has a helper it can talk to: bundled, and signed with a certificate (an ad-hoc build's link refuses all).
    static let available: Bool =
        FileManager.default.fileExists(atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(HelperIDs.helperApp)").path)
            && HelperSigning.helperRequirement() != nil

    static var agent: HelperState.Agent {
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notFound: return .notFound
        default: return .notRegistered
        }
    }

    /// Registers the agent (already registered is fine) and returns what launchd says now. Blocks: call it off the main thread.
    static func register() -> HelperState.Agent {
        do { try service.register() } catch { NSLog("spacebar: helper register: %@", error.localizedDescription) }
        return agent
    }

    static func unregister() {
        do { try service.unregister() } catch { NSLog("spacebar: helper unregister: %@", error.localizedDescription) }
    }

    static func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    static func openAccessibility() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") { NSWorkspace.shared.open(u) }
    }

    static func describe(_ s: SMAppService.Status) -> String {
        switch s {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown (\(s.rawValue))"
        }
    }

    /// The helper's status, when it answers within `timeout` seconds. With `current`, only a helper running this app's copy of
    /// its executable counts: one left running from a replaced bundle is as good as down, and `--reregister` replaces it.
    static func ask(timeout: TimeInterval, current: Bool = true) -> HelperStatus? {
        let s = call(timeout: timeout) { proxy, reply in proxy.status { reply(try? JSONDecoder().decode(HelperStatus.self, from: $0)) } } ?? nil
        guard let s, !current || isCurrent(s) else { return nil }
        return s
    }

    static func isCurrent(_ s: HelperStatus) -> Bool {
        let exe = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(HelperIDs.helperApp)/Contents/MacOS/SpacebarHelper").path
        return !s.binary.isEmpty && s.binary == HelperBinary.stamp(exe)
    }

    /// Asks the helper to show macOS's Accessibility prompt; whether it is trusted now, or nil when it did not answer.
    static func promptAccessibility(timeout: TimeInterval) -> Bool? {
        call(timeout: timeout) { proxy, reply in proxy.promptAccessibility(reply: reply) }
    }

    /// One call to the helper over a connection that requires its signature; blocks for at most `timeout` seconds.
    private static func call<T>(timeout: TimeInterval, _ body: (SpacebarHelperProtocol, @escaping (T) -> Void) -> Void) -> T? {
        guard let req = HelperSigning.helperRequirement() else { return nil }
        let c = NSXPCConnection(machServiceName: HelperIDs.machService, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var out: T?
        guard let proxy = c.remoteObjectProxyWithErrorHandler({ _ in done.signal() }) as? SpacebarHelperProtocol else { return nil }
        body(proxy) { v in
            lock.lock(); out = v; lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return out
    }
}
