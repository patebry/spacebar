import Foundation
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
        guard let req = HelperSigning.helperRequirement() else { return nil }
        let c = NSXPCConnection(machServiceName: HelperIDs.machService, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
        c.setCodeSigningRequirement(req)
        c.resume()
        defer { c.invalidate() }
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var out: HelperStatus?
        let proxy = c.remoteObjectProxyWithErrorHandler { _ in done.signal() } as? SpacebarHelperProtocol
        proxy?.status { data in
            lock.lock(); out = try? JSONDecoder().decode(HelperStatus.self, from: data); lock.unlock()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
        lock.lock(); defer { lock.unlock() }
        return out
    }
}
