import AppKit
import ServiceManagement

/// The Space helper's launchd agent (Contents/Library/LaunchAgents/md.spacebar.helper.plist), registered by this app.
enum HelperAgent {
    static var service: SMAppService { SMAppService.agent(plistName: HelperIDs.agentPlist) }

    /// `--reregister` and `--helper-status`, for install.sh; nil when neither was asked for.
    static func commandLine(_ args: [String]) -> Int32? {
        if args.contains("--helper-status") {
            print("agent: \(describe(service.status))")
            if let s = ask(timeout: 3) { print("helper: pid \(s.pid) trusted=\(s.trusted) tap=\(s.tap) viewer=\(s.viewer)") } else { print("helper: not answering") }
            return 0
        }
        if args.contains("--reregister") { return reregister() }
        return nil
    }

    /// After spacebar.app is replaced in place, launchd refuses the new helper (a launch-constraint violation) while
    /// SMAppService still says enabled. Unregistering, waiting for launchd to let go, and registering again fixes it; sooner
    /// than about 20 s after the replacement it did not take, so this retries for up to about 3 minutes.
    static func reregister() -> Int32 {
        let wantHelper = SettingsFile.load().spaceHelper
        for attempt in 1...6 {
            try? service.unregister()
            sleep(attempt == 1 ? 20 : 10)
            do { try service.register() } catch { print("register: \(error.localizedDescription)") }
            let st = service.status
            print("attempt \(attempt): \(describe(st))")
            if st == .requiresApproval { return 2 }
            // With the setting off the helper exits at once, so being registered is all there is to check.
            guard st == .enabled else { continue }
            if !wantHelper || ask(timeout: 10) != nil { return 0 }
        }
        return 1
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

    /// The helper's status, when it answers within `timeout` seconds.
    static func ask(timeout: TimeInterval) -> HelperStatus? {
        call(timeout: timeout) { proxy, reply in proxy.status { reply(try? JSONDecoder().decode(HelperStatus.self, from: $0)) } } ?? nil
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
