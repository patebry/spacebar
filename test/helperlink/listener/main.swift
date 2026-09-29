// The helper's listener gate (Helper/Link.swift) on a test Mach name: the same requirement, built from this binary's own
// signature, and the same role check. Started by test/helperlink/run.sh as a temporary launchd job.
import Foundation

final class Stub: NSObject, SpacebarHelperProtocol {
    let role: Link.Role
    init(role: Link.Role) { self.role = role }
    func hello(reply: @escaping (Bool) -> Void) { reply(role == .viewer) }
    func panelState(_ open: Bool, requestID: Int, windowNumber: Int) {}
    func declined(_ requestID: Int) {}
    func status(reply: @escaping (Data) -> Void) {
        let s = HelperStatus(pid: getpid(), version: role == .viewer ? "viewer" : "app", enabled: true, trusted: false, tap: false, viewer: false, binary: "")
        reply(role == .app ? (try! JSONEncoder().encode(s)) : Data())
    }
    func promptAccessibility(reply: @escaping (Bool) -> Void) { reply(false) }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard Link.accept(c, exported: { role, _ in Stub(role: role) }) != nil else { return false }
        c.resume()
        return true
    }
}

let listener = NSXPCListener(machServiceName: CommandLine.arguments[1])
let delegate = Delegate()
guard Link.gate(listener) else { print("unsigned"); exit(3) }
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
