// The scenario harness's writer XPC service: the viewer latency stub (test/viewerlatency/writer), but it lists archives as the
// real writer does (ArchiveListing, a sandboxed bsdtar), so an archive shows its entries. Nothing is opened or fetched.
// A text edit (beginTextEdit) of a file named `type-a-b.txt` gets the writer's edit text view in a panel that is never shown:
// it types "a b" in-process, as keys the panel would receive, streams the text back, saves only that file, and 1.5 s later
// ends the edit as Esc does. Every other edit is refused.
import AppKit

/// The one edit this stub takes: the writer's EditTextView, fed in-process key events.
final class Typist: NSObject, NSTextViewDelegate {
    static let fileName = "type-a-b.txt"
    let id: Int, path: String
    private let host: SpacebarEditHostProtocol
    private let panel = EditPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 24), styleMask: [.borderless, .nonactivatingPanel],
                                  backing: .buffered, defer: true)
    private let tv = EditTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 24))
    private var ended = false

    init(id: Int, path: String, text: String, caret: Int, host: SpacebarEditHostProtocol) {
        self.id = id
        self.path = path
        self.host = host
        super.init()
        panel.contentView = tv
        tv.isRichText = false
        tv.setPlain(true)
        tv.string = text
        tv.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        tv.delegate = self
        tv.onEscape = { [weak self] in self?.end("escape") }
    }

    func run() {
        for (i, (ch, code)) in [("a", UInt16(0)), (" ", 49), ("b", 11)].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + 0.15 * Double(i)) { [weak self] in self?.type(ch, code) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.type("\u{1b}", 53) }
    }

    /// As the panel's keyDown hands a key on: Esc to onEscape, the rest to the text system (an unshown panel has no input context).
    private func type(_ chars: String, _ code: UInt16) {
        guard !ended, let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                               isARepeat: false, keyCode: code) else { return }
        if code == 53 { tv.keyDown(with: e) } else { tv.interpretKeyEvents([e]) }
    }

    func textDidChange(_ notification: Notification) {
        let r = tv.selectedRange()
        host.editChanged(id, text: tv.string, selectionStart: r.location, selectionLength: r.length, keyTime: ProcessInfo.processInfo.systemUptime * 1000)
    }

    func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        host.editEnded(id, reason: reason)
    }
}

final class StubWriter: NSObject, SpacebarWriterProtocol, NSXPCListenerDelegate {
    private weak var conn: NSXPCConnection?
    private var typist: Typist?

    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void) {
        DispatchQueue.main.async {
            guard let t = self.typist, t.path == path, (try? Data(contentsOf: URL(fileURLWithPath: path))) == base,
                  (try? data.write(to: URL(fileURLWithPath: path))) != nil else { return reply("refused") }
            reply(nil)
        }
    }
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
    func listArchive(_ path: String, reply: @escaping (Data?) -> Void) { DispatchQueue.global().async { reply(ArchiveListing.list(path)) } }
    func readArchiveEntry(_ path: String, entry: String, reply: @escaping (Data?, String?) -> Void) {
        DispatchQueue.global().async {
            let r = ArchiveEntry.read(path, name: entry, cap: 20 << 20)
            if case .data(let d) = r { reply(d, nil) } else { reply(nil, r.reason) }
        }
    }
    func ensureSupportDir(reply: @escaping (Bool) -> Void) { reply(true) }
    func updateSettings(_ patch: Data, reply: @escaping (Bool) -> Void) { reply(false) }
    func openSettings(_ tab: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func updateOffer(reply: @escaping (Data?) -> Void) { reply(nil) }
    func copyInstallCommand(reply: @escaping (Bool) -> Void) { reply(false) }
    func copyText(_ text: String, reply: @escaping (Bool) -> Void) { reply(false) }
    func installUpdate(_ version: String, reply: @escaping (String?) -> Void) { reply("stub") }
    func prepare() {}
    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func setSelection(_ session: Int, start: Int, length: Int) {}
    func resetEdit(_ session: Int, text: String?, caret: Int) {}
    func endEdit(_ session: Int) { DispatchQueue.main.async { if self.typist?.id == session { self.typist?.end("host") } } }
    func beginFilter(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginListKeys(_ session: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginFind(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) { reply(false) }
    func beginTextEdit(_ session: Int, path: String, text: String, caret: Int, clickX: Double, clickY: Double, width: Double, height: Double,
                       reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard (path as NSString).lastPathComponent == Typist.fileName, let host = self.conn?.remoteObjectProxy as? SpacebarEditHostProtocol else {
                return reply(false)
            }
            self.typist?.end("replaced")
            let t = Typist(id: session, path: path, text: text, caret: caret, host: host)
            self.typist = t
            reply(true)
            t.run()
        }
    }
    func endFilter(_ session: Int) {}

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: SpacebarWriterProtocol.self)
        c.remoteObjectInterface = NSXPCInterface(with: SpacebarEditHostProtocol.self)
        c.exportedObject = self
        conn = c
        c.resume()
        return true
    }
}

_ = NSApplication.shared
let stub = StubWriter()
let listener = NSXPCListener.service()
listener.delegate = stub
listener.resume()
