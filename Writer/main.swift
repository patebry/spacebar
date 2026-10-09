import AppKit
import XPC
import os

// Unsandboxed XPC service embedded in the preview appex; only reachable by that appex (launchd scopes bundled services to their container).
private let log = Logger(subsystem: logSubsystem, category: "writer")
private let writeGate = WriteGate()

final class Writer: NSObject, SpacebarWriterProtocol {
    private weak var connection: NSXPCConnection?
    let typed = TypedTexts()

    init(connection: NSXPCConnection) { self.connection = connection }

    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void) {
        // Both the named path and what it resolves to must be of a type spacebar edits, so a .md symlink cannot aim a write at
        // some other file.
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var why = EditableText.writeRefusal(path: path, data: data, base: base)
        if why == nil, !(EditableText.isMarkdown(path) && EditableText.isMarkdown(resolved)), !typed.allows(path: resolved, data: data, base: base) {
            why = "not a text typed in this file's edit"
        }
        if let why {
            log.error("refused write to \(path, privacy: .private): \(why, privacy: .public)")
            return reply("refused: \(why)")
        }
        guard writeGate.begin() else { return reply("write failed (the writer is quitting); file left as it was") }
        defer { writeGate.end() }
        let err = compareAndWrite(data, path: resolved, expecting: base, noFollow: true)
        if !EditableText.isMarkdown(path) {
            typed.wrote(path: resolved, err == nil ? data : nil, torn: err?.contains("partly written") == true ? FileManager.default.contents(atPath: resolved) : nil)
        }
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
            // Text whose default app is spacebar itself: a text editor, as the viewer's Open does for text.
            if let o = LinkPolicy.textOpener(for: url, editor: chosenEditor(appBundleID)) {
                return NSWorkspace.shared.open([o.file], withApplicationAt: o.app, configuration: NSWorkspace.OpenConfiguration()) { _, err in reply(err == nil) }
            }
            log.error("refused open \(url.path, privacy: .private): no default app")
            return reply(false)
        }
        let target = opener.file
        var app = opener.app
        // The caller names the app, but only the editor the user chose in the settings is honoured.
        if let id = appBundleID, id == SettingsFile.load().editorBundleID, let editor = LinkPolicy.application(id), LinkPolicy.isTextEditor(editor) {
            app = editor
        }
        // An image opens in the app chosen in the settings, when Open With offers it (never a browser, office suite or spacebar).
        if let type = LinkPolicy.contentType(target), type.conforms(to: .image), let id = SettingsFile.load().imageAppBundleID,
           let chosen = LinkPolicy.openWithApps(for: target, allowArchives: archives).first(where: { Bundle(url: $0)?.bundleIdentifier == id }) {
            app = chosen
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

    func openWithApps(_ url: URL, reply: @escaping (Data?) -> Void) {
        guard url.isFileURL, LinkPolicy.fileRefusal(url, allowArchives: true) == nil else {
            log.error("refused openWithApps \(url.path, privacy: .private)")
            return reply(nil)
        }
        let lead = LinkPolicy.opener(for: url, allowArchives: true)?.app
        let apps = LinkPolicy.openWithApps(for: url, allowArchives: true).compactMap { app -> [String: String]? in
            guard let id = Bundle(url: app)?.bundleIdentifier else { return nil }
            var entry = ["id": id, "name": FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")]
            if app == lead { entry["default"] = "1" }
            if let icon = Self.iconURL(app) { entry["icon"] = icon }
            return entry
        }
        reply(try? JSONSerialization.data(withJSONObject: apps))
    }

    /// The app's icon as a 32-pixel PNG data URL, for a 16-point menu row.
    private static func iconURL(_ app: URL) -> String? {
        let icon = NSWorkspace.shared.icon(forFile: app.path)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                         isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        icon.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:]).map { "data:image/png;base64," + $0.base64EncodedString() }
    }

    func openWith(_ url: URL, appBundleID: String, reply: @escaping (Bool) -> Void) {
        guard url.isFileURL, LinkPolicy.fileRefusal(url, allowArchives: true) == nil, let o = LinkPolicy.openWith(url, app: appBundleID, allowArchives: true) else {
            log.error("refused openWith \(url.path, privacy: .private) in \(appBundleID, privacy: .private)")
            return reply(false)
        }
        NSWorkspace.shared.open([o.file], withApplicationAt: o.app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            log.info("openWith \(o.file.path, privacy: .private) with \(o.app.lastPathComponent, privacy: .public) -> \(err == nil)")
            reply(err == nil)
        }
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

    /// One file of an archive, under listArchive's checks, streamed by ArchiveEntry into memory: the cap is the writer's own for
    /// the entry's type, not the caller's. Shares listArchive's queue, so one bsdtar runs at a time.
    func readArchiveEntry(_ path: String, entry: String, reply: @escaping (Data?, String?) -> Void) {
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        guard path.hasPrefix("/"), ArchiveListing.extensions.contains(url.pathExtension.lowercased()),
              LinkPolicy.fileRefusal(url, allowArchives: true) == nil, LinkPolicy.fileRefusal(url) != nil,
              let cap = ArchiveEntryView.cap(for: entry), ArchiveEntry.pattern(entry) != nil else {
            log.error("refused readArchiveEntry \(path, privacy: .private)")
            return reply(nil, "unreadable")
        }
        let lock = NSLock()
        var replied = false
        let once = { (d: Data?, why: String?) in
            lock.lock(); defer { lock.unlock() }
            if !replied { replied = true; reply(d, why) }
        }
        Self.listQueue.async {
            lock.lock(); let late = replied; lock.unlock()
            guard !late else { return }
            let outcome = ArchiveEntry.read(url.path, name: entry, cap: cap)
            if case .data(let d) = outcome { return once(d, nil) }
            if case .partial(let d) = outcome { return once(d, "partial") }
            log.info("readArchiveEntry: \(outcome.reason ?? "", privacy: .public)")
            once(nil, outcome.reason)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + ArchiveEntry.timeout + 4) { once(nil, "timedOut") }
    }

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

    func answerScripts(_ value: String, reply: @escaping (Bool) -> Void) {
        switch SettingsFile.answerScripts(value) {
        case nil:
            log.error("refused htmlScripts answer: not asking, or not local/off")
            reply(false)
        case .success:
            log.info("htmlScripts answered \(value, privacy: .public)")
            reply(true)
        case .failure(let f):
            log.error("htmlScripts answer failed: \(String(describing: f), privacy: .public)")
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
            // Where this copy is matters only for a newer release, and finding out walks the bundle's folders.
            let newer = latest.map { Updates.isNewer($0, than: self.currentVersion) } ?? false
            reply(Updates.offer(current: self.currentVersion, latest: latest, started: Updates.readCache()?.started, finished: Updates.readStatus(),
                                place: newer ? self.misplaced() : nil, running: Updates.isRunning(log: self.updateLog)).json)
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

    func spaceHelperState(reply: @escaping (String, String?) -> Void) {
        guard SettingsFile.load().spaceHelper else { return reply("off", nil) }
        guard HelperTap.taking() else { return reply("notRunning", nil) }
        guard SecureInput.ownerPID() != nil else { return reply("on", nil) }
        reply("paused", SecureInput.ownerName())
    }

    func copyText(_ text: String, reply: @escaping (Bool) -> Void) {
        guard text.utf8.count <= EditableText.maxMarkdownBytes else { return reply(false) }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            reply(NSPasteboard.general.setString(text, forType: .string))
        }
    }

    func installUpdate(_ version: String, reply: @escaping (String?) -> Void) {
        if let why = Updates.installRefusal(version, current: currentVersion, enabled: SettingsFile.load().checkUpdates && updatesAllowed) {
            log.error("refused update to \(version, privacy: .private): \(why, privacy: .public)")
            return reply(why)
        }
        guard let app = containingApp() else { return reply("the spacebar app was not found") }
        // The installer replaces only the copy it picks (Updates.managedCopy); from anywhere else it would add a second one.
        guard misplaced() == nil else { return reply("this copy of spacebar is not one the installer can update") }
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

    /// Where this copy of spacebar is, for the popover, when it is not the copy install.sh updates or this account cannot
    /// replace it; nil when it is that copy.
    private func misplaced() -> String? {
        let home = NSHomeDirectory()
        guard let app = containingApp()?.resolvingSymlinksInPath().path else { return "an unknown folder" }
        if let managed = Updates.managedCopy(home: home), app == URL(fileURLWithPath: managed).resolvingSymlinksInPath().path,
           Updates.canUpdate(managed) { return nil }
        return app.hasPrefix(home + "/") ? "~" + app.dropFirst(home.count) : app
    }

    func prepare() {
        _ = SettingsFile.ensure()
        startAppKit()
        DispatchQueue.main.async { _ = EditSurface.shared }
    }

    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void) {
        beginEdit(session, text: text, caret: caret, file: nil, clickX: clickX, clickY: clickY, width: blockWidth, height: blockHeight, reply: reply)
    }

    func beginTextEdit(_ session: Int, path: String, text: String, caret: Int, clickX: Double, clickY: Double, width: Double, height: Double,
                       reply: @escaping (Bool) -> Void) {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard path.hasPrefix("/"), typed.begin(path: resolved, text: text) else {
            log.error("refused text edit of \(path, privacy: .private): not the file's text")
            return reply(false)
        }
        beginEdit(session, text: text, caret: caret, file: resolved, clickX: clickX, clickY: clickY, width: width, height: height, reply: reply)
    }

    /// `file`: a whole text file (plain mode), whose sent texts are recorded for its writes.
    private func beginEdit(_ session: Int, text: String, caret: Int, file: String?, clickX: Double, clickY: Double, width blockWidth: Double,
                           height blockHeight: Double, reply: @escaping (Bool) -> Void) {
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
            let s = EditSession(owner: self, id: session, text: text, caret: caret, file: file, frame: frame, host: host)
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

    func moveEdit(_ session: Int, token: Int, start: Int, length: Int) {
        DispatchQueue.main.async {
            guard EditSession.find(owner: self, session: session) != nil else { return }
            EditSurface.shared.textView.finishMove(token: token, start < 0 ? nil : NSRange(location: start, length: max(0, length)))
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

    func beginFind(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void) {
        beginKeys(session, text: text, list: false, find: true, clickX: clickX, clickY: clickY, width: fieldWidth, height: fieldHeight, reply: reply)
    }

    private func beginKeys(_ session: Int, text: String, list: Bool, find: Bool = false, clickX: Double, clickY: Double, width fieldWidth: Double,
                           height fieldHeight: Double, reply: @escaping (Bool) -> Void) {
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
            let s = FilterSession(owner: self, id: session, text: list ? "" : FilterKeys.clean(text), list: list, find: find, frame: frame, host: host)
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

/// The app that contains this service: the outermost spacebar.app, since the viewer's copy sits in an app of its own inside it.
func containingApp() -> URL? {
    var dir = Bundle.main.bundleURL
    var found: URL?
    while dir.pathComponents.count > 1 {
        if dir.pathExtension == "app", Bundle(url: dir)?.bundleIdentifier == "md.spacebar" { found = dir }
        dir.deleteLastPathComponent()
    }
    return found
}

/// Whether the Space helper takes Space: an enabled event tap owned by this app's own spacebar Helper.app, read from the
/// window server's list of taps, so nothing connects to the helper. Secure input is another app's, and is read on its own
/// (SecureInput).
enum HelperTap {
    static func taking() -> Bool {
        var n: UInt32 = 0
        guard CGGetEventTapList(0, nil, &n) == .success, n > 0 else { return false }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(n))
        guard CGGetEventTapList(n, &taps, &n) == .success else { return false }
        guard let helper = containingApp()?.appendingPathComponent("Contents/Helpers/spacebar Helper.app", isDirectory: true)
            .resolvingSymlinksInPath().path else { return false }
        return taps.prefix(Int(n)).contains { $0.enabled && runs(helper, $0.tappingProcess) }
    }

    /// A stale or development copy of the helper runs from another bundle, so only this app's helper counts.
    private static func runs(_ helper: String, _ pid: pid_t) -> Bool {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return URL(fileURLWithPath: String(cString: buf)).resolvingSymlinksInPath().path.hasPrefix(helper + "/Contents/MacOS/")
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
    /// The text file edited as a whole (resolved path), whose every sent buffer is recorded in the owner's TypedTexts.
    private let file: String?

    static func find(owner: Writer, session: Int) -> EditSession? {
        guard let s = current, s.owner === owner, s.id == session, !s.ended else { return nil }
        return s
    }

    /// Ends the current session only if it belongs to `owner` (one writer serves every preview of the extension process).
    static func end(owner: Writer, session: Int? = nil, _ reason: String) {
        guard let s = current, s.owner === owner, session == nil || session == s.id else { return }
        s.end(reason, notify: true)
    }

    init(owner: Writer, id: Int, text: String, caret: Int, file: String? = nil, frame: NSRect, host: SpacebarEditHostProtocol) {
        self.owner = owner
        self.id = id
        self.host = host
        self.file = file
        super.init()
        let plain = file != nil
        let panel = surface.panel
        panel.setFrame(frame, display: false)
        textView.frame = NSRect(origin: .zero, size: frame.size)
        textView.delegate = nil
        textView.dropHeld()
        textView.setPlain(plain)
        textView.string = text
        textView.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        textView.undoManager?.removeAllActions()
        textView.session = id
        textView.firstKeyLogged = false
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.end("escape", notify: true) }
        textView.onHoldTimeout = { [weak self] in self?.end("hold-timeout", notify: true) }
        textView.onFind = { [weak self] in self?.end("find", notify: true) }
        textView.onFilterKey = nil
        textView.listKeys = false
        textView.findKeys = false
        textView.onMergeBackward = plain ? nil : { [weak self] in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            self.host.editMergeBackward(self.id)
        }
        textView.onSplit = plain ? nil : { [weak self] before, after, tail in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            self.host.editSplit(self.id, before: before, after: after, tail: tail)
        }
        textView.onUndoPastStart = { [weak self] redo in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            self.host.editUndo(self.id, redo: redo)
        }
        textView.onVerticalMove = { [weak self] down, extend, token in
            guard let self, !self.ended else { return }
            self.flush(force: true)
            let sel = self.textView.selectedRange()
            self.host.editMove(self.id, token: token, down: down, extend: extend, start: sel.location, length: sel.length)
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
            // A text file's buffer changes only by typing: what it holds may be written to the file.
            if let text, file == nil {
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
        let text = textView.string
        if let file { owner?.typed.sent(path: file, text: text) }
        host.editChanged(id, text: text, selectionStart: sel.location, selectionLength: sel.length, keyTime: keyTime)
    }

    func windowDidBecomeKey(_ notification: Notification) { logKey() }

    func windowDidResignKey(_ notification: Notification) { end("blur", notify: true) }

    /// `hide: false` keeps the panel key for a session that replaces this one at once.
    func end(_ reason: String, notify: Bool, hide: Bool = true) {
        guard !ended else { return }
        // Messages on the connection are ordered, so a change still waiting for its main-queue turn lands before the end.
        flush()
        ended = true
        if let file { owner?.typed.ended(path: file) }
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        log.info("edit end: \(reason, privacy: .public)")
        if surface.panel.delegate === self { surface.panel.delegate = nil }
        if textView.delegate === self {
            textView.delegate = nil
            textView.onEscape = {}
            textView.onFind = nil
            textView.onMergeBackward = nil
            textView.onSplit = nil
            textView.onUndoPastStart = nil
            textView.onVerticalMove = nil
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
/// ends it. A find session is the find field's: its text, and the next and previous keys; Esc ends it. It has no path to any
/// file.
final class FilterSession: NSObject, NSWindowDelegate, NSTextViewDelegate {
    static var current: FilterSession?
    let id: Int
    let list: Bool
    let find: Bool
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

    init(owner: Writer, id: Int, text: String, list: Bool = false, find: Bool = false, frame: NSRect, host: SpacebarEditHostProtocol) {
        self.owner = owner
        self.id = id
        self.list = list
        self.find = find
        self.host = host
        super.init()
        let panel = surface.panel
        panel.setFrame(frame, display: false)
        textView.frame = NSRect(origin: .zero, size: frame.size)
        textView.delegate = nil
        textView.dropHeld()
        textView.setPlain(false)
        textView.string = text
        textView.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
        textView.undoManager?.removeAllActions()
        textView.session = id
        textView.firstKeyLogged = true
        textView.onMergeBackward = nil
        textView.onSplit = nil
        textView.onUndoPastStart = nil
        textView.onVerticalMove = nil
        textView.delegate = self
        textView.onEscape = { [weak self] in self?.escape() }
        textView.onHoldTimeout = {}
        textView.onFind = nil
        textView.listKeys = list
        textView.findKeys = find
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
        if list || find || FilterKeys.escapeEnds(text: textView.string) { return end("escape", notify: true) }
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
            textView.onFind = nil
            textView.onFilterKey = nil
            textView.listKeys = false
            textView.findKeys = false
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
