import AppKit
import XPC
import os

// Unsandboxed XPC service embedded in the preview appex; only reachable by that appex (launchd scopes bundled services to their container).
private let log = Logger(subsystem: logSubsystem, category: "writer")
private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
private let maxWriteBytes = 64 << 20
private let writeGate = WriteGate()

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
            log.error("refused write to \(path, privacy: .private)")
            return reply("refused: not an existing markdown file")
        }
        guard writeGate.begin() else { return reply("write failed (the writer is quitting); file left as it was") }
        defer { writeGate.end() }
        let err = compareAndWrite(data, path: path, expecting: base)
        if let err { log.error("write \(path, privacy: .private): \(err, privacy: .private)") } else { log.info("wrote \(data.count) bytes to \(path, privacy: .private)") }
        reply(err)
    }

    func open(_ url: URL, reply: @escaping (Bool) -> Void) { open(url, appBundleID: nil, reply: reply) }

    func open(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void) { open(url, appBundleID: appBundleID, archives: false, reply: reply) }

    func openFileOnScreen(_ url: URL, reply: @escaping (Bool) -> Void) {
        guard url.isFileURL else { return reply(false) }
        open(url, appBundleID: nil, archives: true, reply: reply)
    }

    private func open(_ url: URL, appBundleID: String?, archives: Bool, reply: @escaping (Bool) -> Void) {
        if let why = LinkPolicy.refusal(url, allowArchives: archives) {
            log.error("refused open \(url.absoluteString, privacy: .private): \(why, privacy: .public)")
            return reply(false)
        }
        guard url.isFileURL else {
            let ok = NSWorkspace.shared.open(url)
            log.info("open \(url.absoluteString, privacy: .private) -> \(ok)")
            return reply(ok)
        }
        guard let opener = LinkPolicy.opener(for: url, allowArchives: archives) else {
            log.error("refused open \(url.path, privacy: .private): no default app")
            return reply(false)
        }
        let target = opener.file
        var app = opener.app
        // The caller names the app, but only the editor the user chose in the settings is honoured.
        if let id = appBundleID, id == SettingsFile.load().editorBundleID, let editor = LinkPolicy.application(id), LinkPolicy.isTextEditor(editor) {
            app = editor
        }
        NSWorkspace.shared.open([target], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("open \(target.absoluteString, privacy: .private) with \(app.lastPathComponent, privacy: .public) -> \(err == nil)")
            reply(err == nil)
        }
    }

    /// The chosen editor's bundle ID, when the caller names it: only the one in settings.json is honoured.
    private func chosenEditor(_ id: String?) -> String? {
        guard let id, id == SettingsFile.load().editorBundleID else { return nil }
        return id
    }

    func openText(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void) {
        guard url.isFileURL, let o = LinkPolicy.textOpener(for: url, editor: chosenEditor(appBundleID)) else {
            log.error("refused openText \(url.path, privacy: .private)")
            return reply(false)
        }
        NSWorkspace.shared.open([o.file], withApplicationAt: o.app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("openText \(o.file.path, privacy: .private) with \(o.app.lastPathComponent, privacy: .public) editor=\(o.editor) -> \(err == nil)")
            reply(err == nil)
        }
    }

    func textOpener(_ url: URL, appBundleID: String?, reply: @escaping (String?, Bool) -> Void) {
        guard url.isFileURL, let o = LinkPolicy.textOpener(for: url, editor: chosenEditor(appBundleID)) else { return reply(nil, false) }
        reply(FileManager.default.displayName(atPath: o.app.path).replacingOccurrences(of: ".app", with: ""), o.editor)
    }

    /// Selects the file in Finder and nothing else: it must never open or launch what it is given.
    func reveal(_ url: URL, reply: @escaping (Bool) -> Void) {
        var st = stat()
        guard url.isFileURL, url.path.hasPrefix("/"), lstat(url.path, &st) == 0 else {
            log.error("refused reveal \(url.absoluteString, privacy: .private)")
            return reply(false)
        }
        NSWorkspace.shared.activateFileViewerSelecting([url.standardizedFileURL])
        log.info("reveal \(url.path, privacy: .private)")
        reply(true)
    }

    func defaultApp(_ url: URL, reply: @escaping (String?) -> Void) {
        guard url.isFileURL, LinkPolicy.refusal(url, allowArchives: true) == nil, let app = LinkPolicy.opener(for: url, allowArchives: true)?.app else { return reply(nil) }
        reply(FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: ""))
    }

    /// Lists an archive with a sandboxed bsdtar (ArchiveListing): only an archive, by name and by the exact type LinkPolicy lets
    /// the viewer open, so the extension cannot point libarchive at anything else. One listing at a time; the reply comes
    /// within a fixed time even if bsdtar never ends.
    func listArchive(_ path: String, reply: @escaping (Data?) -> Void) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard path.hasPrefix("/"), ArchiveListing.extensions.contains(url.pathExtension.lowercased()),
              LinkPolicy.fileRefusal(url, allowArchives: true) == nil, LinkPolicy.fileRefusal(url) != nil else {
            log.error("refused listArchive \(path, privacy: .private)")
            return reply(nil)
        }
        let lock = NSLock()
        var replied = false
        let once = { (d: Data?) in
            lock.lock(); defer { lock.unlock() }
            if !replied { replied = true; reply(d) }
        }
        // Listings wait their turn; one whose reply already timed out is not started.
        Self.listQueue.async {
            lock.lock(); let late = replied; lock.unlock()
            if !late { once(ArchiveListing.list(url.path)) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + ArchiveListing.timeout + 4) { once(nil) }
    }
    private static let listQueue = DispatchQueue(label: "md.spacebar.list-archive", qos: .userInitiated)

    func ensureSupportDir(reply: @escaping (Bool) -> Void) {
        let err = SettingsFile.ensure()
        if let err { log.error("support folder: \(String(describing: err), privacy: .public)") }
        reply(err == nil)
    }

    func updateSettings(_ patch: Data, reply: @escaping (Bool) -> Void) {
        if patch.count <= 4096, let keys = (try? JSONSerialization.jsonObject(with: patch)) as? [String: Any] {
            let dropped = Set(keys.keys).subtracting(Settings.panelKeys)
            if !dropped.isEmpty { log.error("settings patch: dropped keys \(dropped.sorted().joined(separator: ","), privacy: .public)") }
        }
        switch SettingsFile.updateFromPanel(patch) {
        case nil:
            log.error("refused settings patch: not a small JSON object")
            reply(false)
        case .success(let s):
            log.info("settings updated theme=\(s.theme, privacy: .public) fontSize=\(s.fontSize) width=\(s.width, privacy: .public) sidebarCollapsed=\(s.sidebarCollapsed)")
            reply(true)
        case .failure(let f):
            log.error("settings update failed: \(String(describing: f), privacy: .public)")
            reply(false)
        }
    }

    func openSettings(_ tab: String, reply: @escaping (Bool) -> Void) {
        guard let url = SettingsTab.url(tab) else { return reply(false) }
        // The app that contains this service, not whichever app claims the scheme.
        guard let app = containingApp() else {
            log.error("open settings: containing app not found")
            return reply(false)
        }
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("open settings \(tab, privacy: .public) -> \(err == nil)")
            reply(err == nil)
        }
    }

    func updateOffer(reply: @escaping (Data?) -> Void) {
        guard SettingsFile.load().checkUpdates, updatesAllowed else { return reply(nil) }
        let answer = { (latest: String?) in
            reply(Updates.offer(current: self.currentVersion, latest: latest, started: Updates.readCache()?.started, finished: Updates.readStatus(),
                                place: self.misplaced(), running: Updates.isRunning(log: self.updateLog)).json)
        }
        let cached = Updates.readCache()
        if let c = cached, (0..<Updates.interval).contains(Date().timeIntervalSince1970 - c.checked) { return answer(c.latest) }
        var req = URLRequest(url: Updates.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("spacebar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let found = (resp as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(Updates.parseLatest) : nil
            // A failed check still counts as a check, so an offline Mac does not ask on every preview.
            var c = Updates.readCache() ?? Updates.Cache(checked: 0, latest: nil)
            c.checked = Date().timeIntervalSince1970
            c.latest = found ?? c.latest
            Updates.writeCache(c)
            log.info("update check -> \(found ?? "none", privacy: .public)\(err == nil ? "" : " (failed)", privacy: .public)")
            answer(c.latest)
        }.resume()
    }

    func copyInstallCommand(reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            reply(NSPasteboard.general.setString(Updates.installCommand, forType: .string))
        }
    }

    func installUpdate(_ version: String, reply: @escaping (String?) -> Void) {
        if let why = Updates.installRefusal(version, current: currentVersion, enabled: SettingsFile.load().checkUpdates && updatesAllowed) {
            log.error("refused update to \(version, privacy: .private): \(why, privacy: .public)")
            return reply(why)
        }
        guard let app = containingApp() else { return reply("the spacebar app was not found") }
        // The installer only ever replaces ~/Applications/spacebar.app; from anywhere else it would add a second copy.
        guard misplaced() == nil else { return reply("spacebar is not in ~/Applications") }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
                   "SPACEBAR_UPDATE_STATUS": Updates.statusURL.path]
        // Recorded before the start, so an installer that fails at once still ends after it.
        let before = Updates.readCache()
        var c = before ?? Updates.Cache(checked: 0, latest: nil)
        c.started = Updates.Started(version: version, at: Date().timeIntervalSince1970)
        Updates.writeCache(c)
        let run = Updates.runDetached(script: app.appendingPathComponent("Contents/Resources/install.sh"), arguments: Updates.installerArguments(version),
                                      log: updateLog, environment: env) { code in
            Updates.writeStatus(Updates.Finished(version: version, exitStatus: code, finishedAt: Date().timeIntervalSince1970))
            log.info("update to \(version, privacy: .public) ended with \(code)")
        }
        switch run {
        case .success(let pid):
            log.info("update to \(version, privacy: .public) started (pid \(pid))")
            reply(nil)
        case .failure(let e):
            if var c = Updates.readCache() { c.started = before?.started; Updates.writeCache(c) }
            log.error("update to \(version, privacy: .public): \(e.message, privacy: .public)")
            reply(e.message)
        }
    }

    private var updateLog: URL { URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs/spacebar-update.log") }

    private var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    /// A development build checks only while the test flag file exists.
    private var updatesAllowed: Bool {
        Updates.checks(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                       testFlag: FileManager.default.fileExists(atPath: Updates.testFlagURL.path))
    }

    /// Where this copy of spacebar is, for the popover, when it is not ~/Applications/spacebar.app; nil when it is.
    private func misplaced() -> String? {
        let home = NSHomeDirectory()
        guard let app = containingApp()?.resolvingSymlinksInPath().path else { return "an unknown folder" }
        if app == URL(fileURLWithPath: home).appendingPathComponent("Applications/spacebar.app").resolvingSymlinksInPath().path { return nil }
        return app.hasPrefix(home + "/") ? "~" + app.dropFirst(home.count) : app
    }

    /// The app that contains this service.
    private func containingApp() -> URL? {
        var app = Bundle.main.bundleURL
        while app.pathExtension != "app", app.pathComponents.count > 1 { app.deleteLastPathComponent() }
        return app.pathExtension == "app" && Bundle(url: app)?.bundleIdentifier == "md.spacebar" ? app : nil
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
                FilterSession.current?.end("replaced", notify: true)
                return reply(false)
            }
            old?.end("replaced", notify: true, hide: false)
            FilterSession.current?.end("replaced", notify: true, hide: false)
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

    func beginFilter(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) {
        beginKeys(session, text: text, list: false, clickX: clickX, clickY: clickY, width: fieldWidth, height: fieldHeight, reply: reply)
    }

    func beginListKeys(_ session: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, reply: @escaping (Bool) -> Void) {
        beginKeys(session, text: "", list: true, clickX: clickX, clickY: clickY, width: rowWidth, height: rowHeight, reply: reply)
    }

    private func beginKeys(_ session: Int, text: String, list: Bool, clickX: Double, clickY: Double, width fieldWidth: Double, height fieldHeight: Double,
                           reply: @escaping (Bool) -> Void) {
        let host = connection?.remoteObjectProxyWithErrorHandler { err in
            log.error("filter host gone: \(err.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { FilterSession.end(owner: self, "host-gone") }
        } as? SpacebarEditHostProtocol
        startAppKit()
        DispatchQueue.main.async {
            guard let host else {
                EditSession.current?.end("replaced", notify: true)
                FilterSession.current?.end("replaced", notify: true)
                return reply(false)
            }
            EditSession.current?.end("replaced", notify: true, hide: false)
            FilterSession.current?.end("replaced", notify: true, hide: false)
            let mouse = NSEvent.mouseLocation
            let frame = NSRect(x: mouse.x - clickX, y: mouse.y + clickY - fieldHeight, width: max(fieldWidth, 40), height: max(fieldHeight, 16))
            let s = FilterSession(owner: self, id: session, text: list ? "" : FilterKeys.clean(text), list: list, frame: frame, host: host)
            FilterSession.current = s
            reply(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard FilterSession.current === s else { return }
                if !EditSurface.shared.panel.isKeyWindow { s.end("not-key", notify: true) }
            }
        }
    }

    func endFilter(_ session: Int) {
        DispatchQueue.main.async { FilterSession.end(owner: self, session: session, "host") }
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
        textView.onFilterKey = nil
        textView.listKeys = false
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

/// The sidebar's filter field while it holds the keyboard: the edit panel and text view, with the text streamed to the host and
/// the list keys forwarded. A list session (a click on a row) has no text: it forwards the list keys only, and Esc or Space
/// ends it. It has no path to any file.
final class FilterSession: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static var current: FilterSession?
    let id: Int
    let list: Bool
    weak var owner: Writer?
    private let surface = EditSurface.shared
    private var textView: EditTextView { surface.textView }
    private let host: SpacebarEditHostProtocol
    private var sendQueued = false
    private var ended = false

    static func end(owner: Writer, session: Int? = nil, _ reason: String) {
        guard let s = current, s.owner === owner, session == nil || session == s.id else { return }
        s.end(reason, notify: true)
    }

    init(owner: Writer, id: Int, text: String, list: Bool = false, frame: NSRect, host: SpacebarEditHostProtocol) {
        self.owner = owner
        self.id = id
        self.list = list
        self.host = host
        super.init()
        let panel = surface.panel
        panel.setFrame(frame, display: false)
        textView.frame = NSRect(origin: .zero, size: frame.size)
        textView.delegate = nil
        textView.dropHeld()
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.undoManager?.removeAllActions()
        textView.session = id
        textView.firstKeyLogged = true
        textView.onMergeBackward = nil
        textView.onSplit = nil
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.escape() }
        textView.onHoldTimeout = {}
        textView.listKeys = list
        textView.onFilterKey = { [weak self] key, isRepeat in
            guard let self, !self.ended else { return }
            if !self.list { self.flush() }
            self.host.filterKey(self.id, key: key, isRepeat: isRepeat)
        }
        panel.delegate = self
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(textView)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(appActivated), name: NSWorkspace.didActivateApplicationNotification, object: nil)
    }

    @objc private func appActivated(_ n: Notification) { end("app-activated", notify: true) }

    private func escape() {
        if list || FilterKeys.escapeEnds(text: textView.string) { return end("escape", notify: true) }
        textView.string = ""
        textView.undoManager?.removeAllActions()
        flush()
    }

    func textDidChange(_ notification: Notification) {
        guard !ended, !list, !sendQueued else { return }
        sendQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.ended else { return }
            self.sendQueued = false
            self.flush()
        }
    }

    /// Sends the text, first making the field one clean line if a paste brought in more.
    private func flush() {
        let clean = FilterKeys.clean(textView.string)
        if clean != textView.string { textView.string = clean }
        host.filterChanged(id, text: clean)
    }

    func windowDidResignKey(_ notification: Notification) { end("blur", notify: true) }

    /// `hide: false` keeps the panel key for a session that replaces this one at once.
    func end(_ reason: String, notify: Bool, hide: Bool = true) {
        guard !ended else { return }
        if sendQueued { flush() }
        ended = true
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        log.info("filter end: \(reason, privacy: .public)")
        if surface.panel.delegate === self { surface.panel.delegate = nil }
        if textView.delegate === self {
            textView.delegate = nil
            textView.onEscape = {}
            textView.onFilterKey = nil
            textView.listKeys = false
        }
        if hide { surface.panel.orderOut(nil) }
        if notify { host.filterEnded(id, reason: reason) }
        if FilterSession.current === self { FilterSession.current = nil }
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
            DispatchQueue.main.async {
                EditSession.end(owner: writer, "disconnected")
                FilterSession.end(owner: writer, "disconnected")
            }
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

if let f = SettingsFile.migrate() { log.error("settings.json not migrated: \(String(describing: f), privacy: .public)") }
if SettingsFile.migrateLegacySupportDir() { log.info("moved support folder \(SettingsFile.legacyFolderName, privacy: .public) to \(SettingsFile.folderName, privacy: .public)") }

let termSource = writeGate.handleSIGTERM()
let delegate = Delegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()
