import AppKit
import XPC
import os

// Unsandboxed XPC service embedded in the preview appex; only reachable by that appex (launchd scopes bundled services to their container).
private let log = Logger(subsystem: logSubsystem, category: "writer")
private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
private let maxWriteBytes = 64 << 20

final class Writer: NSObject, SpacebarWriterProtocol {
    private weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) { self.connection = connection }

    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void) {
        // Both the named path and what it resolves to must be existing markdown files, so a .md symlink cannot aim a write at
        // some other file.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var st = stat()
        guard path.hasPrefix("/"), [URL(fileURLWithPath: path), resolved].allSatisfy({ markdownExtensions.contains($0.pathExtension.lowercased()) }),
              stat(resolved.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, data.count <= maxWriteBytes, base.count <= maxWriteBytes else {
            log.error("refused write to \(path, privacy: .public)")
            return reply("refused: not an existing markdown file")
        }
        let err = compareAndWrite(data, path: path, expecting: base)
        if let err { log.error("write \(path, privacy: .public): \(err, privacy: .public)") } else { log.info("wrote \(data.count) bytes to \(path, privacy: .public)") }
        reply(err)
    }

    func open(_ url: URL, reply: @escaping (Bool) -> Void) { open(url, appBundleID: nil, reply: reply) }

    func open(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void) {
        if let why = LinkPolicy.refusal(url) {
            log.error("refused open \(url.absoluteString, privacy: .public): \(why, privacy: .public)")
            return reply(false)
        }
        guard url.isFileURL else {
            let ok = NSWorkspace.shared.open(url)
            log.info("open \(url.absoluteString, privacy: .public) -> \(ok)")
            return reply(ok)
        }
        guard let opener = LinkPolicy.opener(for: url) else {
            log.error("refused open \(url.path, privacy: .public): no default app")
            return reply(false)
        }
        let target = opener.file
        var app = opener.app
        // The caller names the app, but only the editor the user chose in the settings is honoured.
        if let id = appBundleID, id == SettingsFile.load().editorBundleID, let editor = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            app = editor
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("open \(target.absoluteString, privacy: .public) with \(app.lastPathComponent, privacy: .public) -> \(err == nil)")
            reply(err == nil)
        }
    }

    func ensureSupportDir(reply: @escaping (Bool) -> Void) {
        let err = SettingsFile.ensure()
        if let err { log.error("support folder: \(String(describing: err), privacy: .public)") }
        reply(err == nil)
    }

    func updateSettings(_ patch: Data, reply: @escaping (Bool) -> Void) {
        guard patch.count <= 4096, let obj = (try? JSONSerialization.jsonObject(with: patch)) as? [String: Any] else {
            log.error("refused settings patch: not a small JSON object")
            return reply(false)
        }
        let dropped = Set(obj.keys).subtracting(Settings.panelKeys)
        if !dropped.isEmpty { log.error("settings patch: dropped keys \(dropped.sorted().joined(separator: ","), privacy: .public)") }
        switch SettingsFile.update(obj, allowed: Settings.panelKeys) {
        case .success(let s):
            log.info("settings updated theme=\(s.theme, privacy: .public) fontSize=\(s.fontSize) width=\(s.width, privacy: .public)")
            reply(true)
        case .failure(let f):
            log.error("settings update failed: \(String(describing: f), privacy: .public)")
            reply(false)
        }
    }

    func openSettings(_ tab: String, reply: @escaping (Bool) -> Void) {
        guard let url = SettingsTab.url(tab) else { return reply(false) }
        // The app that contains this service, not whichever app claims the scheme.
        var app = Bundle.main.bundleURL
        while app.pathExtension != "app", app.pathComponents.count > 1 { app.deleteLastPathComponent() }
        guard app.pathExtension == "app", Bundle(url: app)?.bundleIdentifier == "md.spacebar" else {
            log.error("open settings: containing app not found")
            return reply(false)
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("open settings \(tab, privacy: .public) -> \(err == nil)")
            reply(err == nil)
        }
    }

    func prepare() {
        _ = SettingsFile.ensure()
        startAppKit()
        DispatchQueue.main.async { _ = EditSurface.shared }
    }

    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void) {
        log.info("lat[\(session)] writer-recv \(upMs(), format: .fixed(precision: 1))")
        let host = connection?.remoteObjectProxyWithErrorHandler { err in
            log.error("edit host gone: \(err.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { EditSession.end(owner: self, "host-gone") }
        } as? SpacebarEditHostProtocol
        startAppKit()
        DispatchQueue.main.async {
            let old = EditSession.current
            guard let host else {
                old?.end("replaced", notify: true)
                return reply(false)
            }
            old?.end("replaced", notify: true, hide: false)
            let mouse = NSEvent.mouseLocation
            let frame = NSRect(x: mouse.x - clickX, y: mouse.y + clickY - blockHeight, width: max(blockWidth, 40), height: max(blockHeight, 24))
            let s = EditSession(owner: self, id: session, text: text, caret: caret, frame: frame, host: host)
            EditSession.current = s
            log.info("lat[\(session)] panel-shown \(upMs(), format: .fixed(precision: 1))")
            reply(true)
            // Key status can settle after makeKey returns; a panel the window server refused must not leave the preview editing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard EditSession.current === s else { return }
                if !EditSurface.shared.panel.isKeyWindow { s.end("not-key", notify: true) }
            }
        }
    }

    func setSelection(_ session: Int, start: Int, length: Int) {
        // While keys are held for a merge or split the buffer is stale; moving its selection would send it to the host.
        DispatchQueue.main.async {
            guard let s = EditSession.find(owner: self, session: session), !s.holding else { return }
            s.select(start: start, length: length)
        }
    }

    func resetEdit(_ session: Int, text: String?, caret: Int) {
        DispatchQueue.main.async { EditSession.find(owner: self, session: session)?.reset(text: text, caret: caret) }
    }

    func endEdit(_ session: Int) {
        DispatchQueue.main.async { EditSession.end(owner: self, session: session, "host") }
    }
}

/// The one panel and text view, built once (hidden) and reused by every session so an edit does not wait for window creation.
final class EditSurface {
    static let shared = EditSurface()
    let panel: EditPanel
    let textView: EditTextView

    private init() {
        let frame = NSRect(x: 0, y: 0, width: 400, height: 24)
        panel = EditPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        textView = EditTextView(frame: frame)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        textView.drawsBackground = false
        textView.textColor = .clear
        textView.insertionPointColor = .clear
        textView.font = .systemFont(ofSize: 15)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.displaysLinkToolTips = false
        textView.usesFindBar = false
        // The page draws the selection; the panel must never show one (it sits over the preview at pop-up menu level), nor any
        // system text UI anchored to it.
        textView.selectedTextAttributes = [.backgroundColor: NSColor.clear, .foregroundColor: NSColor.clear]
        if #available(macOS 14.0, *) { textView.inlinePredictionType = .no }
        if #available(macOS 15.0, *) {
            textView.writingToolsBehavior = .none
            textView.mathExpressionCompletionType = .no
        }
        panel.contentView = textView
        log.info("edit panel built (hidden)")
    }
}

final class EditSession: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static var current: EditSession?
    let id: Int
    weak var owner: Writer?
    private let surface = EditSurface.shared
    private var textView: EditTextView { surface.textView }
    private let host: SpacebarEditHostProtocol
    private var sendQueued = false
    private var ended = false
    private var keyLogged = false

    static func find(owner: Writer, session: Int) -> EditSession? {
        guard let s = current, s.owner === owner, s.id == session, !s.ended else { return nil }
        return s
    }

    /// Ends the current session only if it belongs to `owner` (one writer serves every preview of the extension process).
    static func end(owner: Writer, session: Int? = nil, _ reason: String) {
        guard let s = current, s.owner === owner, session == nil || session == s.id else { return }
        s.end(reason, notify: true)
    }

    init(owner: Writer, id: Int, text: String, caret: Int, frame: NSRect, host: SpacebarEditHostProtocol) {
        self.owner = owner
        self.id = id
        self.host = host
        super.init()
        let panel = surface.panel
        panel.setFrame(frame, display: false)
        textView.frame = NSRect(origin: .zero, size: frame.size)
        textView.delegate = nil
        textView.dropHeld()
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        textView.undoManager?.removeAllActions()
        textView.session = id
        textView.firstKeyLogged = false
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.end("escape", notify: true) }
        textView.onHoldTimeout = { [weak self] in self?.end("hold-timeout", notify: true) }
        textView.onMergeBackward = { [weak self] in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            self.host.editMergeBackward(self.id)
        }
        textView.onSplit = { [weak self] before, after, tail in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            self.host.editSplit(self.id, before: before, after: after, tail: tail)
        }
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        if panel.isKeyWindow { logKey() }
        // Backstop: the panel never activates spacebar, so any app activation means focus moved elsewhere.
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    private func logKey() {
        guard !keyLogged else { return }
        keyLogged = true
        log.info("lat[\(self.id)] panel-key \(upMs(), format: .fixed(precision: 1))")
    }

    @objc private func appActivated(_ n: Notification) { end("app-activated", notify: true) }

    func select(start: Int, length: Int) {
        let n = (textView.string as NSString).length
        let a = max(0, min(start, n))
        textView.setSelectedRange(NSRange(location: a, length: max(0, min(length, n - a))))
    }

    var holding: Bool { textView.isHolding }

    func reset(text: String?, caret: Int) {
        textView.releaseHeld {
            if let text {
                textView.string = text
                textView.undoManager?.removeAllActions()
            }
            if caret >= 0 { select(start: caret, length: 0) }
        }
    }

    func textDidChange(_ notification: Notification) { queueSend() }
    func textViewDidChangeSelection(_ notification: Notification) { queueSend() }

    private var pendingKeyTime: Double?

    private func queueSend() {
        guard !ended, !textView.isHolding else { return }
        if pendingKeyTime == nil { pendingKeyTime = (textView.replaying ?? NSApp.currentEvent)?.timestamp ?? ProcessInfo.processInfo.systemUptime }
        guard !sendQueued else { return }
        sendQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ended else { return }
            self.sendQueued = false
            self.flush()
        }
    }

    /// Sends the buffer if it changed. During a hold the buffer predates the host's merge or split and is never sent; `force`
    /// is for the send just before the hold's request.
    private func flush(force: Bool = false) {
        guard force || !textView.isHolding, let keyTime = pendingKeyTime else { return }
        pendingKeyTime = nil
        let sel = textView.selectedRange()
        host.editChanged(id, text: textView.string, selectionStart: sel.location, selectionLength: sel.length, keyTime: keyTime)
    }

    func windowDidBecomeKey(_ notification: Notification) { logKey() }

    func windowDidResignKey(_ notification: Notification) { end("blur", notify: true) }

    /// `hide: false` keeps the panel key for a session that replaces this one at once.
    func end(_ reason: String, notify: Bool, hide: Bool = true) {
        guard !ended else { return }
        // Messages on the connection are ordered, so a change still waiting for its main-queue turn lands before the end.
        flush()
        ended = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        log.info("edit end: \(reason, privacy: .public)")
        if surface.panel.delegate === self { surface.panel.delegate = nil }
        if textView.delegate === self {
            textView.delegate = nil
            textView.onEscape = {}
            textView.onMergeBackward = nil
            textView.onSplit = nil
            textView.onHoldTimeout = {}
            textView.dropHeld()
        }
        if hide { surface.panel.orderOut(nil) }
        if notify { host.editEnded(id, reason: reason) }
        if EditSession.current === self { EditSession.current = nil }
    }
}

final class Delegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: SpacebarWriterProtocol.self)
        c.remoteObjectInterface = NSXPCInterface(with: SpacebarEditHostProtocol.self)
        let writer = Writer(connection: c)
        c.exportedObject = writer
        // An open preview keeps the service from idle exit, so the next edit does not pay for a relaunch.
        xpc_transaction_begin()
        c.invalidationHandler = {
            DispatchQueue.main.async { EditSession.end(owner: writer, "disconnected") }
            xpc_transaction_end()
        }
        c.resume()
        return true
    }
}

/// The edit panel needs a running NSApplication, started on first use. NSApp.run is entered from a run-loop callout rather than
/// a main-queue block: inside a main-queue block it would hold the serial main queue forever and starve every later dispatch.
private var appKitStarted = false
private func startAppKit() {
    DispatchQueue.main.async {
        guard !appKitStarted else { return }
        appKitStarted = true
        NSApplication.shared.setActivationPolicy(.accessory)
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) { NSApp.run() }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    }
}

private func processStartUpMs() -> Double {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let t = info.kp_proc.p_un.__p_starttime
    return upMs(epochMs: (Double(t.tv_sec) + Double(t.tv_usec) / 1e6) * 1000)
}
log.info("lat writer-launch \(processStartUpMs(), format: .fixed(precision: 1)) writer-main \(upMs(), format: .fixed(precision: 1))")

if SettingsFile.migrateLegacySupportDir() { log.info("moved support folder \(SettingsFile.legacyFolderName, privacy: .public) to \(SettingsFile.folderName, privacy: .public)") }

let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
