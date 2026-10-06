// A stand-in for the viewer's writer XPC service: every lookup answers at once and nothing is written, opened or fetched,
// so the harness measures the viewer, not the writer, and touches nothing of the user's.
import Foundation

final class StubWriter: NSObject, SpacebarWriterProtocol, NSXPCListenerDelegate {
    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void) { reply("refused") }
    func open(_ url: URL, reply: @escaping (Bool) -> Void) { reply(false) }
    func open(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void) { reply(false) }
    func openFileOnScreen(_ url: URL, reply: @escaping (Bool) -> Void) { reply(false) }
    func openText(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void) { reply(false) }
    func textOpener(_ url: URL, appBundleID: String?, reply: @escaping (String?, Bool) -> Void) { reply("TextEdit", true) }
    func reveal(_ url: URL, reply: @escaping (Bool) -> Void) { reply(false) }
    func spaceHelperState(reply: @escaping (String, String?) -> Void) { reply("on", nil) }
    func defaultApp(_ url: URL, reply: @escaping (String?) -> Void) { reply("Preview") }
    func openWithApps(_ url: URL, reply: @escaping (Data?) -> Void) { reply(nil) }
    func openWith(_ url: URL, appBundleID: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func listArchive(_ path: String, reply: @escaping (Data?) -> Void) { reply(nil) }
    func readArchiveEntry(_ path: String, entry: String, reply: @escaping (Data?, String?) -> Void) { reply(nil, "unreadable") }
    func ensureSupportDir(reply: @escaping (Bool) -> Void) { reply(true) }
    func updateSettings(_ patch: Data, reply: @escaping (Bool) -> Void) { reply(false) }
    func openSettings(_ tab: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func updateOffer(reply: @escaping (Data?) -> Void) { reply(nil) }
    func copyInstallCommand(reply: @escaping (Bool) -> Void) { reply(false) }
    func copyText(_ text: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func installUpdate(_ version: String, reply: @escaping (String?) -> Void) { reply("stub") }
    func prepare() {}
    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginTextEdit(_ session: Int, path: String, text: String, caret: Int, clickX: Double, clickY: Double, width: Double, height: Double,
                       reply: @escaping (Bool) -> Void) { reply(false) }
    func setSelection(_ session: Int, start: Int, length: Int) {}
    func moveEdit(_ session: Int, token: Int, start: Int, length: Int) {}
    func resetEdit(_ session: Int, text: String?, caret: Int) {}
    func endEdit(_ session: Int) {}
    func beginFilter(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginListKeys(_ session: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginFind(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func endFilter(_ session: Int) {}

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: SpacebarWriterProtocol.self)
        c.exportedObject = self
        c.resume()
        return true
    }
}

let stub = StubWriter()
let listener = NSXPCListener.service()
listener.delegate = stub
listener.resume()
