import Cocoa
import QuickLookUI
import UniformTypeIdentifiers
import WebKit
import os

let log = Logger(subsystem: logSubsystem, category: "preview")

private func processAgeMs() -> String {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
    sysctl(&mib, 4, &info, &size, nil, 0)
    let t = info.kp_proc.p_un.__p_starttime
    return String(format: "%.1f", (Date().timeIntervalSince1970 - (Double(t.tv_sec) + Double(t.tv_usec) / 1e6)) * 1000)
}
private let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]

private func ms(_ since: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(since) * 1000) }
/// NSEvent timestamps and systemUptime share the boot-time clock, so the writer's key time can be compared here.
private func uptimeMs(since t: Double) -> String { String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - t) * 1000) }

/// Receives the edit buffer from the writer's key-capturing panel.
final class EditHost: NSObject, SpacebarEditHostProtocol {
    private weak var controller: PreviewViewController?
    init(controller: PreviewViewController) { self.controller = controller }
    func editChanged(_ session: Int, text: String, selectionStart: Int, selectionLength: Int, keyTime: Double) {
        DispatchQueue.main.async { self.controller?.editChanged(session, text: text, selStart: selectionStart, selLen: selectionLength, keyTime: keyTime) }
    }
    func editEnded(_ session: Int, reason: String) {
        DispatchQueue.main.async { self.controller?.editEnded(session, reason: reason) }
    }
    func editMergeBackward(_ session: Int) {
        DispatchQueue.main.async { self.controller?.mergeRequested(session) }
    }
    func editSplit(_ session: Int, before: String, after: String, tail: String) {
        DispatchQueue.main.async { self.controller?.splitRequested(session, before: before, after: after, tail: tail) }
    }
}

/// While an edit holds the keyboard the preview's window is not key, and WKWebView takes the first click into a non-key
/// window only as window activation. Every click here edits, selects or follows a link, so it must land on the first try.
final class PreviewWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// One WKWebView per extension process, reused across previews so only the first preview pays WebKit start-up.
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = WebHost()
    let web: WKWebView
    private(set) var ready = false
    private var onReady: [() -> Void] = []
    weak var controller: PreviewViewController?
    let created = Date()
    let remoteImages: RemoteImageGate

    override init() {
        let config = WKWebViewConfiguration()
        let scheme = SchemeHandler(webRoot: Bundle.main.resourceURL!.appendingPathComponent("web"))
        scheme.onRefused = { log.error("\($0, privacy: .private)") }
        config.setURLSchemeHandler(scheme, forURLScheme: "spacebar")
        web = PreviewWebView(frame: .zero, configuration: config)
        remoteImages = RemoteImageGate(config.userContentController)
        super.init()
        remoteImages.onError = { log.error("\($0, privacy: .public)") }
        config.userContentController.add(self, name: "sb")
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        let store = SettingsStore.shared
        applyNative(store.settings)
        store.observe { [weak self] s in self?.settingsChanged(s) }
        web.load(URLRequest(url: URL(string: "spacebar://bundle/index.html")!))
    }

    private var webRoot: URL { Bundle.main.resourceURL!.appendingPathComponent("web") }

    /// What must be in place before the page next loads: the document-start script that themes the first paint, the light or
    /// dark override, and the remote-image block.
    private func applyNative(_ s: Settings) {
        let ucc = web.configuration.userContentController
        ucc.removeAllUserScripts()
        ucc.addUserScript(PageSettings.userScript(SettingsStore.shared.payload, webRoot: webRoot))
        web.appearance = s.appearance == "light" ? NSAppearance(named: .aqua) : s.appearance == "dark" ? NSAppearance(named: .darkAqua) : nil
        remoteImages.update(remoteImages: s.remoteImages)
    }

    private func settingsChanged(_ s: Settings) {
        applyNative(s)
        guard ready else { return }
        let json = PageSettings.json(SettingsStore.shared.payload)
        web.evaluateJavaScript("sb.applySettings && sb.applySettings(\(json)); 0") { _, err in
            if let err { log.error("applySettings failed: \(String(describing: err), privacy: .public)") }
        }
        controller?.settingsChanged(s)
    }

    func resendSettings() { settingsChanged(SettingsStore.shared.settings) }

    /// Runs `f` once the page is loaded and the remote-image block is in place.
    func whenReady(_ f: @escaping () -> Void) { ready ? remoteImages.whenInPlace(f) : onReady.append { self.remoteImages.whenInPlace(f) } }

    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame, origin.protocol == "spacebar", origin.host == "bundle" else {
            return log.error("dropped message from \(origin.protocol, privacy: .public)://\(origin.host, privacy: .public)")
        }
        guard let body = message.body as? [String: Any], body.count <= 24, let type = body["type"] as? String, type.utf8.count <= 32 else {
            return log.error("dropped malformed message")
        }
        if type == "ready" {
            log.info("web ready in \(ms(self.created), privacy: .public)ms after WKWebView init")
            ready = true
            onReady.forEach { $0() }
            onReady = []
            return
        }
        controller?.handle(type, body)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Only the shell page loads; links are clicks the page reports, and the document may not open frames.
        let isShell = action.request.url?.absoluteString == "spacebar://bundle/index.html" && action.targetFrame?.isMainFrame == true
        decisionHandler(isShell ? .allow : .cancel)
    }

    private var crashes = 0

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        crashes += 1
        log.error("web content process terminated (\(self.crashes))")
        ready = false
        guard crashes < 3 else { return }
        webView.load(URLRequest(url: URL(string: "spacebar://bundle/index.html")!))
    }
}

/// Typed, size-checked access to a message from the page. The page renders an untrusted document, so every field is
/// checked here: a wrong type or an out-of-range value reads as missing.
struct PageMessage {
    static let maxText = 4 << 20
    let body: [String: Any]

    func int(_ k: String, _ range: ClosedRange<Int> = 0...10_000_000) -> Int? {
        guard let n = body[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), let i = body[k] as? Int, range.contains(i) else { return nil }
        return i
    }
    func double(_ k: String) -> Double? {
        guard let n = body[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    func bool(_ k: String) -> Bool? {
        guard let n = body[k] as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    func string(_ k: String, max: Int = PageMessage.maxText) -> String? {
        guard let v = body[k] as? String, v.utf8.count <= max else { return nil }
        return v
    }
}

/// Watches a path across atomic saves: on delete/rename the fd is re-opened on whatever now lives at the path.
final class FileWatcher {
    private let path: String
    private let onChange: () -> Void
    private var source: DispatchSourceFileSystemObject?

    init(path: String, onChange: @escaping () -> Void) {
        self.path = path
        self.onChange = onChange
        arm(attempt: 0)
    }

    deinit { source?.cancel() }

    private func arm(attempt: Int) {
        let fd = open(path, O_EVTONLY | O_NONBLOCK)
        guard fd >= 0 else {
            if attempt < 40 { DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { [weak self] in self?.arm(attempt: attempt + 1) } }
            else { log.error("watch: cannot open \(self.path, privacy: .private) errno=\(errno)") }
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            let ev = src.data
            if ev.contains(.delete) || ev.contains(.rename) {
                src.cancel()
                self.source = nil
                self.arm(attempt: 0)
            }
            self.onChange()
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
        if attempt > 0 { onChange() }
    }
}

@objc(PreviewViewController)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let host = WebHost.shared
    private var fileURL: URL?
    private var folder: [[String: String]]?
    /// The folder of the item Quick Look asked for (the folder itself in folder mode), symlinks resolved. Markdown links open in
    /// the panel, where they can be edited, only inside it; others open in the default app like any other document.
    private var rootDir = ""
    private var watcher: FileWatcher?
    /// Latest document the preview intends to be on disk (includes queued edits).
    private var docText: String?
    /// Last content confirmed on disk, in its on-disk line endings; every write must name it as its base.
    private var diskText: String?
    /// "\r\n" for a file whose every line ends in CRLF. docText and the page always use "\n"; writes convert back.
    private var lineEnding = "\n"
    private func onDisk(_ text: String) -> String { lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding) }
    private var prepareStart = Date()
    private var completion: ((Error?) -> Void)?
    private var reloadPending = false
    private var changeSeen = Date()
    /// The block being edited: writer session id, the page's click sequence number, and its line range in docText.
    private var edit: (id: Int, seq: Int, start: Int, lines: Int)?
    /// The session a click just replaced: keys typed into it before the writer switched arrive late and are still applied.
    private var retired: [(id: Int, seq: Int, start: Int, lines: Int)] = []

    /// Moves every retired range that starts at or below `line` by `delta` lines.
    private func shiftRetired(from line: Int, by delta: Int) {
        retired = retired.map { $0.start >= line ? ($0.id, $0.seq, $0.start + delta, $0.lines) : $0 }
    }
    /// Bumped by every edit message sent to the page. Line-count changes are logged against it so a click's line numbers,
    /// computed on the page at version v, can be carried forward through the splices the page had not seen yet.
    private var docVersion = 0
    private var splices: [(ver: Int, at: Int, delta: Int)] = []
    private var splicesForgotten = 0

    /// Carries a line number the page computed at version `ver` forward to docText; nil when the splices it needs are forgotten.
    private func mapLine(_ line: Int, from ver: Int?) -> Int? {
        guard let ver, ver < docVersion else { return line }
        guard ver >= splicesForgotten else { return nil }
        var mapped = line
        for sp in splices where sp.ver > ver && mapped >= sp.at { mapped += sp.delta }
        return mapped
    }

    private func nextVersion(splicingAt at: Int = 0, delta: Int = 0) -> Int {
        docVersion += 1
        if delta != 0 { splices.append((docVersion, at, delta)); if splices.count > 64 { splicesForgotten = splices.removeFirst().ver } }
        return docVersion
    }
    private var editCounter = 0
    private var writing = false
    private var queuedSave: (url: URL, text: String, keyTime: Double?)?
    /// Set after a write failed part-way and could not be undone: the exact bytes it left on disk (the torn file need not be
    /// valid UTF-8), snapshotted once per such failure and used as the base of every retry, so a save by anyone else in the
    /// meantime still turns the retry into a conflict. Until a retry succeeds docText is the only good copy in memory, so
    /// reloads and switching files are held.
    private var tornBase: Data?
    private var torn = false
    private var tornStatus = ""
    /// Torn, no recovery copy, and someone else has since written the file: no more writes; the text stays on screen.
    private var tornHalted = false

    override func loadView() {
        host.web.removeFromSuperview()
        host.web.autoresizingMask = [.width, .height]
        #if PROBE
        let container = Probe.makeRoot(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        Probe.install()
        #else
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        #endif
        host.web.frame = container.bounds
        container.addSubview(host.web)
        view = container
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        disableHostDoubleClick()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        disableHostDoubleClick()
        #if PROBE
        Probe.windowAttached(view)
        #endif
    }

    /// Quick Look's service view controller hangs a two-click NSClickGestureRecognizer on an ancestor of this view. On a
    /// double-click it asks the host to open the file in its default app, and while it waits to see whether a click becomes a
    /// double-click it withholds the primary mouse events, so every click reached the web view one double-click interval late.
    /// Clicks in this preview mean edit, select or follow a link, so the recognizer is switched off.
    private func disableHostDoubleClick() {
        #if PROBE
        if Probe.has("nofix") { return }
        #endif
        var v: NSView? = view
        while let cur = v {
            for g in cur.gestureRecognizers {
                guard let click = g as? NSClickGestureRecognizer, click.numberOfClicksRequired >= 2, click.isEnabled else { continue }
                click.isEnabled = false
                log.info("disabled host double-click recognizer on \(NSStringFromClass(type(of: cur)), privacy: .public) (delayed primary clicks: \(click.delaysPrimaryMouseButtonEvents))")
            }
            v = cur.superview
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        stopEdit(notifyWriter: true)
        host.remoteImages.reset()
    }

    deinit {
        if let id = edit?.id { (helperConnection?.remoteObjectProxy as? SpacebarWriterProtocol)?.endEdit(id) }
        helperConnection?.invalidate()
        log.info("controller deinit")
    }

    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        prepareStart = Date()
        SettingsStore.shared.checkNow(reason: "prepare")
        let warm = host.ready
        log.info("prepare \(url.path, privacy: .private) warm=\(warm) processAge=\(processAgeMs(), privacy: .public)ms wall=\(Date().timeIntervalSince1970, privacy: .public)")
        _ = url.startAccessingSecurityScopedResource()
        host.controller = self
        completion = handler

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let resolved = url.resolvingSymlinksInPath()
        rootDir = isDir.boolValue ? resolved.path : resolved.deletingLastPathComponent().path
        if isDir.boolValue {
            let s = SettingsStore.shared.settings
            // Folder previews are opt-in; declining hands the folder back to Quick Look's own preview.
            guard s.folderMode else { return decline(handler, "folder previews are off") }
            let entries = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            let modified = { (u: URL) in (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast }
            let mds = entries.filter { markdownExtensions.contains($0.pathExtension.lowercased()) && Self.unreadable($0) == nil }
                .sorted { s.folderSort == "modified" ? modified($0) > modified($1) : $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            log.info("folder preview: \(entries.count) entries, \(mds.count) markdown")
            guard !mds.isEmpty else { return decline(handler, "no markdown in the folder") }
            folder = mds.map { ["name": $0.lastPathComponent, "path": $0.path] }
            let readme = s.folderReadmeFirst ? mds.first { $0.deletingPathExtension().lastPathComponent.lowercased() == "readme" } : nil
            open(readme ?? mds[0])
        } else {
            open(url)
        }
        // Launch the writer and build its hidden edit panel now, so the first click into a block does not wait for either.
        // Inline editing off: no writer launch until something needs it, but the support folder still gets made.
        if SettingsStore.shared.settings.inlineEditing {
            #if PROBE
            if !Probe.has("noprewarm") { helper { $0.prepare() } }
            #else
            helper { $0.prepare() }
            #endif
        } else if !FileManager.default.fileExists(atPath: SettingsFile.url.path) {
            helper { $0.ensureSupportDir { _ in DispatchQueue.main.async { SettingsStore.shared.checkNow(reason: "created") } } }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.finishPrepare(nil) }
    }

    private func decline(_ handler: (Error?) -> Void, _ why: String) {
        log.info("declined: \(why, privacy: .public)")
        completion = nil
        handler(CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: why]))
    }

    fileprivate func settingsChanged(_ s: Settings) {
        if !s.inlineEditing, edit != nil { stopEdit(notifyWriter: true) }
    }

    private func finishPrepare(_ error: Error?) {
        disableHostDoubleClick()
        guard let c = completion else { return }
        completion = nil
        c(error)
    }

    private static let maxDocumentBytes = 64 << 20

    /// Why `url` cannot be previewed: a document must be a regular file (after symlinks) of bounded size, so a `.md` that is a
    /// FIFO or a link to /dev/zero cannot hang or exhaust the extension.
    private static func unreadable(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "cannot read \(url.lastPathComponent)" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "\(url.lastPathComponent) is not a regular file" }
        return st.st_size <= maxDocumentBytes ? nil : "\(url.lastPathComponent) is too large to preview"
    }

    private func open(_ url: URL) {
        if torn { return status("NOT SAVED: file partly written; retrying before switching") }
        if let why = Self.unreadable(url) { log.error("open: \(why, privacy: .private)"); return status(why) }
        stopEdit(notifyWriter: true)
        queuedSave = nil
        host.remoteImages.reset()
        fileURL = url
        docText = nil
        diskText = nil
        watcher = FileWatcher(path: url.path) { [weak self] in self?.fileChanged() }
        host.whenReady { self.reload(reason: "open") }
    }

    private func fileChanged() {
        changeSeen = Date()
        guard !reloadPending else { return }
        reloadPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            self?.reloadPending = false
            self?.reload(reason: "change")
        }
    }

    private func reload(reason: String) {
        guard let url = fileURL, !writing, !torn else { return }
        if let why = Self.unreadable(url) { log.error("read refused: \(why, privacy: .private)"); return status(why) }
        let raw: String
        do { raw = try String(contentsOf: url, encoding: .utf8) } catch {
            log.error("read failed \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return
        }
        if raw == diskText { return }
        if edit == nil, let d = docText, onDisk(d) != diskText { status("unsaved text replaced by the version on disk") }
        let crlf = raw.contains("\r\n") && !raw.replacingOccurrences(of: "\r\n", with: "").utf8.contains(10)
        lineEnding = crlf ? "\r\n" : "\n"
        let text = crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        // Ranges of ended sessions refer to the old text; their late keys must not land in the new one.
        retired = []
        if edit != nil {
            log.info("file changed on disk during edit; stopping edit")
            stopEdit(notifyWriter: true)
            status("changed on disk: edit stopped")
        }
        docText = text
        diskText = raw
        log.info("read \(text.utf8.count) bytes, last line: \(text.split(separator: "\n").last.map(String.init) ?? "", privacy: .private)")
        push(text: text, path: url.path, reason: reason)
    }

    private func push(text: String, path: String, reason: String, keyTime: Double? = nil) {
        var comps = URLComponents()
        comps.scheme = "spacebar"
        comps.host = "file"
        comps.path = (path as NSString).deletingLastPathComponent + "/"
        var payload: [String: Any] = ["text": text, "path": path, "base": comps.url!.absoluteString,
                                      "name": (path as NSString).lastPathComponent, "reason": reason]
        if let folder { payload["files"] = folder }
        if let keyTime { payload["keyTime"] = keyTime }
        if host.remoteImages.allowedPath == path { payload[RemoteImageGate.payloadKey] = true }
        payload["ver"] = docVersion
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        host.remoteImages.whenInPlace { [host] in
            host.web.evaluateJavaScript("sb.render(\(json)); 0") { _, err in
                if let err { log.error("render eval failed: \(String(describing: err), privacy: .public)") }
            }
        }
    }

    func handle(_ type: String, _ body: [String: Any]) {
        let m = PageMessage(body: body)
        switch type {
        case "painted":
            // Show the panel as soon as text/math/code are in; mermaid diagrams fill in afterwards.
            if completion != nil {
                log.info("painted[\(m.string("reason", max: 32) ?? "", privacy: .public)] \(ms(self.prepareStart), privacy: .public)ms after prepare wall=\(Date().timeIntervalSince1970, privacy: .public)")
            }
            finishPrepare(nil)
        case "rendered":
            let parse = m.double("parseMs") ?? 0, total = m.double("totalMs") ?? 0
            let reason = m.string("reason", max: 32) ?? ""
            if reason == "edit", let kt = m.double("keyTime") {
                log.info("keystroke->saved->rendered \(uptimeMs(since: kt), privacy: .public)ms")
            } else if reason == "change" {
                log.info("live reload rendered \(ms(self.changeSeen), privacy: .public)ms after fs event (js total \(total, format: .fixed(precision: 1))ms) wall=\(Date().timeIntervalSince1970, privacy: .public)")
            } else {
                log.info("rendered[\(reason, privacy: .public)] \(ms(self.prepareStart), privacy: .public)ms after prepare (js parse \(parse, format: .fixed(precision: 1))ms total \(total, format: .fixed(precision: 1))ms) wall=\(Date().timeIntervalSince1970, privacy: .public)")
            }
            finishPrepare(nil)
        case "link":
            guard let href = m.string("href", max: LinkPolicy.maxURLBytes), let url = URL(string: href) else { return refuse("link", "bad href") }
            followLink(url)
        case "open":
            // Only a file the folder sidebar listed.
            guard let p = m.string("path", max: 4096), folder?.contains(where: { $0["path"] == p }) == true else { return refuse("open", "not in the folder list") }
            open(URL(fileURLWithPath: p))
        case "setting":
            // The Aa popover: cosmetic keys only (Settings.panelKeys), checked here and again by the writer.
            guard let key = m.string("key", max: 32), Settings.panelKeys.contains(key), let raw = body["value"],
                  let value = Settings.sanitize(key, raw), let patch = try? JSONSerialization.data(withJSONObject: [key: value]) else {
                return refuse("setting", "key not allowed or bad value")
            }
            log.info("setting \(key, privacy: .public) from the panel")
            helper {
                $0.updateSettings(patch) { ok in
                    DispatchQueue.main.async {
                        if !ok { self.status("settings.json could not be updated"); self.host.resendSettings() }
                        SettingsStore.shared.checkNow(reason: "panel")
                    }
                }
            }
        case "openSettings":
            let tab = m.string("tab", max: 16) ?? "appearance"
            guard SettingsTab.all.contains(tab) else { return refuse("openSettings", "unknown tab") }
            helper { $0.openSettings(tab) { ok in if !ok { DispatchQueue.main.async { self.status("could not open settings") } } } }
        case "toggle":
            guard SettingsStore.shared.settings.taskToggles else { return refuse("toggle", "task toggles are off") }
            guard isCurrent(m), let line = m.int("line"), let checked = m.bool("checked"), let text = m.string("text", max: 1 << 16) else {
                return refuse("toggle", "bad request or not the previewed file")
            }
            guard let mapped = mapLine(line, from: m.int("ver")) else { return status("not toggled: document changed") }
            toggleTask(line: mapped, text: text, checked: checked)
        case "editBlock":
            guard SettingsStore.shared.settings.inlineEditing, isCurrent(m) else {
                refuse("editBlock", "not the previewed file")
                if let seq = m.int("seq") { js("sb.editEnd", ["seq": seq]) }
                return
            }
            beginEdit(m)
        case "caretPainted":
            log.info("lat[\(self.edit?.id ?? -1)] caret-painted \(upMs(epochMs: m.double("t") ?? 0), format: .fixed(precision: 1))")
        case "editSelect":
            guard let e = edit, m.int("seq") == e.seq, let start = m.int("start"), let len = m.int("length") else { return }
            helper { $0.setSelection(e.id, start: start, length: len) }
        case "mergePrev":
            mergeBackward(m)
        case "editCancel":
            if let e = edit, m.int("seq") == e.seq { stopEdit(notifyWriter: true) }
        case "editStop":
            guard let e = edit, m.int("seq") == e.seq else { return }
            stopEdit(notifyWriter: true, keepRetired: true)
            // Keys the writer flushes as it ends still land; the block is dropped if it ends up empty (editEnded).
            retired.append(e)
            if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "editEnd") }
        case "editPainted":
            if let kt = m.double("keyTime") { log.info("keystroke->painted \(uptimeMs(since: kt), privacy: .public)ms") }
        case "edit":
            if let fileURL { openExternally(fileURL) }
        case "loadRemoteImages":
            // A blocked image's placeholder: this document's remote images, for this preview only. The setting is not touched.
            guard let p = m.string("path", max: 4096), host.remoteImages.allowOnce(p, current: fileURL?.path) else {
                return refuse("loadRemoteImages", "remote images are on or not the previewed file")
            }
            log.info("remote images loaded once for the previewed file")
            if let e = edit { stopEdit(notifyWriter: true, keepRetired: true); retired.append(e) }
            if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "remoteImages") }
        case "log":
            log.info("js: \(String((body["msg"] as? String ?? "").prefix(2000)), privacy: .private)")
        default: break
        }
    }

    /// Edits name the file the page rendered; one for any other file (a stale page, a folder switch) is refused.
    private func isCurrent(_ m: PageMessage) -> Bool {
        guard let fileURL, let p = m.string("path", max: 4096) else { return false }
        return p == fileURL.path
    }

    private func refuse(_ what: String, _ why: String) {
        log.error("refused \(what, privacy: .public): \(why, privacy: .private)")
    }

    private func followLink(_ url: URL) {
        let target: URL
        switch url.scheme?.lowercased() {
        case "spacebar" where url.host == "file":
            target = URL(fileURLWithPath: url.path).standardizedFileURL
            let inside = (target.resolvingSymlinksInPath().path + "/").hasPrefix(rootDir + "/")
            if markdownExtensions.contains(target.pathExtension.lowercased()), inside, Self.unreadable(target) == nil,
               SettingsStore.shared.settings.mdLinks == "preview" {
                log.info("link -> in-panel \(target.path, privacy: .private)")
                open(target)
                return
            }
        case "http", "https":
            target = url
        default:
            return refuse("link", "scheme \(url.scheme ?? "none")")
        }
        if let why = LinkPolicy.refusal(target) { return refuse("link", "\(why): \(target.absoluteString)") }
        openExternally(target)
    }

    /// NSWorkspace.open is a silent no-op inside the sandboxed QL extension, so opening goes through the helper.
    private func openExternally(_ url: URL) {
        log.info("link -> helper open \(url.absoluteString, privacy: .private)")
        // A file (the document, or a Markdown link when links open in the editor) goes to the chosen editor; the writer
        // honours the ID only when it matches settings.json itself.
        let editor = url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased()) ? SettingsStore.shared.settings.editorBundleID : nil
        helper {
            $0.open(url, appBundleID: editor) { ok in
                log.info("link -> helper open returned \(ok)")
                if !ok { DispatchQueue.main.async { self.status("not opened: \(url.lastPathComponent)") } }
            }
        }
    }

    private var helperConnection: NSXPCConnection?

    private func helper(onError: (() -> Void)? = nil, _ body: (SpacebarWriterProtocol) -> Void) {
        let conn = helperConnection ?? NSXPCConnection(serviceName: writerServiceName)
        if helperConnection == nil {
            conn.remoteObjectInterface = NSXPCInterface(with: SpacebarWriterProtocol.self)
            conn.exportedInterface = NSXPCInterface(with: SpacebarEditHostProtocol.self)
            conn.exportedObject = EditHost(controller: self)
            // A writer crash drops its panel; the edit and any pending write must not stay open waiting for replies.
            conn.interruptionHandler = { [weak self] in DispatchQueue.main.async { self?.writerLost() } }
            conn.invalidationHandler = { [weak self] in DispatchQueue.main.async { self?.writerLost(); self?.helperConnection = nil } }
            conn.resume()
            helperConnection = conn
        }
        let proxy = conn.remoteObjectProxyWithErrorHandler { [weak self] err in
            log.error("xpc error: \(err.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { self?.status("helper unavailable"); onError?() }
        } as? SpacebarWriterProtocol
        if let proxy { body(proxy) }
    }

    private func writerLost() {
        stopEdit(notifyWriter: false)
        if writing { writing = false; queuedSave = nil; status("save failed: edit again to retry") }
        if torn, let url = fileURL { retryTorn(url) }
    }

    private func retryTorn(_ url: URL) {
        stickyStatus(tornStatus.isEmpty ? "NOT SAVED: file partly written, no recovery copy; copy your text before closing"
                                        : "NOT SAVED: file partly written; retrying. Text kept in \(tornStatus) (temporary folders are cleared)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.torn, !self.tornHalted, !self.writing, self.fileURL == url, let t = self.docText else { return }
            self.save(t)
        }
    }

    /// `expected` is the task line as the page saw it; if docText has moved on, the nearest identical line is toggled instead.
    private func toggleTask(line clicked: Int, text expected: String?, checked: Bool) {
        guard let text = docText else { return }
        var lines = text.components(separatedBy: "\n")
        var line = clicked
        if let expected, line >= lines.count || lines[line] != expected {
            guard let at = locate([expected], in: lines, near: clicked) else { log.error("toggle: task line not found"); return }
            line = at
        }
        // Only a task item's own marker, never another bracket on the line.
        guard line < lines.count, let item = lines[line].range(of: #"^[ \t]*(?:>[ \t]?)*(?:[-*+]|\d{1,9}[.)])[ \t]+\[[ xX]\]"#, options: .regularExpression)
        else { return log.error("toggle: line \(line) is not a task item") }
        let r = lines[line].index(item.upperBound, offsetBy: -3)..<item.upperBound
        lines[line].replaceSubrange(r, with: checked ? "[x]" : "[ ]")
        save(lines.joined(separator: "\n"))
    }

    /// Writes go through the unsandboxed writer one at a time. Each names the content it expects on disk (the result of the
    /// previous confirmed write), so an external change is never overwritten; a queued save replaces an older queued one.
    private func save(_ text: String, keyTime: Double? = nil) {
        guard let url = fileURL else { return }
        docText = text
        if writing { queuedSave = (url, text, keyTime); return }
        send(url, text, keyTime)
    }

    private func send(_ url: URL, _ text: String, _ keyTime: Double?) {
        guard !tornHalted else { return stickyStatus("file changed on disk; your unsaved text is only in this preview: copy it now") }
        if torn && tornBase == nil { tornBase = FileManager.default.contents(atPath: url.path) }
        guard let base = torn ? tornBase : diskText.map({ Data($0.utf8) }) else {
            if torn { retryTorn(url) }
            return
        }
        writing = true
        helper(onError: { [weak self] in self?.saved(url, text, keyTime: keyTime, error: "xpc") }) {
            $0.write(Data(self.onDisk(text).utf8), toPath: url.path, expecting: base) { err in
                DispatchQueue.main.async { self.saved(url, text, keyTime: keyTime, error: err) }
            }
        }
    }

    private func saved(_ url: URL, _ text: String, keyTime: Double?, error: String?) {
        guard writing else { return }
        writing = false
        guard url == fileURL else { queuedSave = nil; return }
        if let error, error == "conflict", torn, tornStatus.isEmpty {
            // Someone else wrote the file after it was torn and no recovery copy exists: stop writing but keep the text on screen.
            log.error("save failed: conflict after a partial write, no recovery copy")
            tornHalted = true
            queuedSave = nil
            stopEdit(notifyWriter: true)
            stickyStatus("file changed on disk; your unsaved text is only in this preview: copy it now")
            return
        }
        if let error, error == "conflict", torn {
            // Someone else wrote the file after it was torn: their save wins; the unsaved text is in the recovery copy.
            torn = false
            tornBase = nil
            log.error("save failed: conflict after a partial write")
            queuedSave = nil
            stopEdit(notifyWriter: true)
            stickyStatus("changed on disk; your unsaved text is in \(tornStatus)")
            tornStatus = ""
            docText = nil
            diskText = nil
            reload(reason: "conflict")
            return
        }
        if let error, error == "conflict" {
            log.error("save failed: conflict")
            queuedSave = nil
            stopEdit(notifyWriter: true)
            status("changed on disk: not saved")
            docText = nil
            diskText = nil
            reload(reason: "conflict")
            return
        }
        if let error {
            // Not a conflict (disk full, I/O error, helper lost): keep the unsaved text on screen and in docText so the next edit
            // retries it. When the writer could not put the old content back, the partial file becomes the base to overwrite.
            log.error("save failed: \(error, privacy: .private)")
            queuedSave = nil
            stopEdit(notifyWriter: true)
            if error.contains("partly written") {
                torn = true
                tornBase = FileManager.default.contents(atPath: url.path)
                tornStatus = error.range(of: "text kept in ").map { String(error[$0.upperBound...]) } ?? ""
            }
            if torn {
                retryTorn(url)
            } else {
                status("save failed: edit again to retry")
            }
            return
        }
        diskText = onDisk(text)
        if torn { torn = false; tornBase = nil; stickyStatus(""); status(tornStatus.isEmpty ? "saved" : "saved; \(tornStatus) can be deleted"); tornStatus = "" }
        if let q = queuedSave {
            queuedSave = nil
            if q.url == url { send(q.url, q.text, q.keyTime) }
            return
        }
        push(text: text, path: url.path, reason: edit != nil ? "edit" : "save", keyTime: keyTime)
        // Catch an external change that landed while writes were in flight (watcher reloads are skipped during a write).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reload(reason: "change") }
    }

    // MARK: inline editing

    /// Where `block` sits in `lines`: at `start` when the page's view matches docText, otherwise the nearest exact match (the
    /// page can trail docText by in-flight edit messages).
    private func locate(_ block: [String], in lines: [String], near start: Int) -> Int? {
        let n = block.count
        guard n > 0, n <= lines.count else { return nil }
        let matches = { (i: Int) in lines[i..<(i + n)].elementsEqual(block) }
        if start >= 0, start + n <= lines.count, matches(start) { return start }
        return (0...(lines.count - n)).filter(matches).min { abs($0 - start) < abs($1 - start) }
    }

    /// Clicks are accepted while writes are in flight: docText already holds every queued edit, and saves stay serialized.
    private func beginEdit(_ m: PageMessage) {
        guard let seq = m.int("seq") else { return }
        // The writer keeps its panel key when a new session replaces the old one, so only a failed begin ends the old one there.
        let previous = edit
        stopEdit(notifyWriter: false, keepRetired: true)
        if let previous { retired.append(previous) }
        let fail = { (why: String) in
            log.error("editBlock: \(why, privacy: .public)")
            // Keys already typed into the previous block (and flushed as the writer ends it) still land.
            if let p = previous { self.helper { $0.endEdit(p.id) } }
            self.js("sb.editEnd", ["seq": seq])
        }
        guard let text = docText, let start = m.int("start"), let end = m.int("end"), let block = m.string("text"),
              let caret = m.int("caret"), start < end, caret <= (block as NSString).length else { return fail("bad request or no document") }
        let lines = text.components(separatedBy: "\n")
        let blockLines = block.components(separatedBy: "\n")
        guard let mapped = mapLine(start, from: m.int("ver")) else { return fail("click too far behind the document") }
        guard let at = locate(blockLines, in: lines, near: mapped) else { return fail("block not found in the document") }
        editCounter += 1
        let id = editCounter
        edit = (id, seq, at, blockLines.count)
        log.info("editBlock \(id) lines \(at)..<\(at + blockLines.count) caret \(caret)\(at == mapped ? "" : " (page said \(start))", privacy: .public)\(self.writing ? " during a write" : "", privacy: .public)")
        if at != mapped { js("sb.editMoved", ["seq": seq, "doc": text, "start": at, "ver": nextVersion()]) }
        let d = { (k: String) in m.double(k) ?? 0 }
        log.info("lat[\(id)] js-click \(upMs(epochMs: d("tClick")), format: .fixed(precision: 1)) js-mapped \(upMs(epochMs: d("tMapped")), format: .fixed(precision: 1)) xpc-call \(upMs(), format: .fixed(precision: 1))")
        helper(onError: { [weak self] in if self?.edit?.id == id { self?.stopEdit(notifyWriter: false) } }) {
            $0.beginEdit(id, text: block, caret: caret, clickX: d("clickX"), clickY: d("clickY"), blockWidth: d("width"), blockHeight: d("height")) { ok in
                DispatchQueue.main.async {
                    guard self.edit?.id == id else { return }
                    log.info("lat[\(id)] ack \(upMs(), format: .fixed(precision: 1))")
                    if !ok { self.stopEdit(notifyWriter: false); self.status("inline editing unavailable") }
                }
            }
        }
    }

    fileprivate func editChanged(_ id: Int, text raw: String, selStart: Int, selLen: Int, keyTime: Double) {
        guard let text = docText else { return }
        let block = lineEnding == "\n" ? raw : raw.replacingOccurrences(of: "\r\n", with: "\n")
        var lines = text.components(separatedBy: "\n")
        let newLines = block.components(separatedBy: "\n")
        if let e = edit, e.id == id {
            guard e.start + e.lines <= lines.count else { stopEdit(notifyWriter: true); return }
            let ver = nextVersion(splicingAt: e.start + e.lines, delta: newLines.count - e.lines)
            js("sb.editUpdate", ["seq": e.seq, "text": block, "selStart": selStart, "selLen": selLen, "keyTime": keyTime, "ver": ver,
                                     "at": e.start, "old": e.lines])
            lines.replaceSubrange(e.start..<(e.start + e.lines), with: newLines)
            edit = (id, e.seq, e.start, newLines.count)
            shiftRetired(from: e.start + e.lines, by: newLines.count - e.lines)
        } else if let i = retired.firstIndex(where: { $0.id == id }) {
            let r = retired[i], e = edit
            guard r.start + r.lines <= lines.count, e.map({ r.start + r.lines <= $0.start || $0.start + $0.lines <= r.start }) ?? true else {
                retired.remove(at: i)
                return
            }
            let ver = nextVersion(splicingAt: r.start + r.lines, delta: newLines.count - r.lines)
            js("sb.editUpdate", ["seq": r.seq, "text": block, "selStart": selStart, "selLen": selLen, "keyTime": keyTime, "ver": ver,
                                     "at": r.start, "old": r.lines])
            lines.replaceSubrange(r.start..<(r.start + r.lines), with: newLines)
            shiftRetired(from: r.start + r.lines, by: newLines.count - r.lines)
            retired[i] = (r.id, r.seq, r.start, newLines.count)
            if let e, e.start >= r.start + r.lines { edit = (e.id, e.seq, e.start + newLines.count - r.lines, e.lines) }
        } else {
            return
        }
        let updated = lines.joined(separator: "\n")
        if updated != text { save(updated, keyTime: keyTime) }
    }

    /// The writer reports every session end after flushing its last text, so no more keys can arrive for `id`: an edit left
    /// with an empty block (Enter then click away, or all text deleted) takes its block out rather than leaving blank lines.
    fileprivate func editEnded(_ id: Int, reason: String) {
        if let i = retired.firstIndex(where: { $0.id == id }) {
            let r = retired.remove(at: i)
            dropIfEmpty(start: r.start, lines: r.lines)
            return
        }
        guard let e = edit, e.id == id else { return }
        log.info("edit \(id) ended: \(reason, privacy: .public)")
        stopEdit(notifyWriter: false)
        dropIfEmpty(start: e.start, lines: e.lines)
        if reason == "not-key" { status("inline editing unavailable") }
        // Re-sync the page with docText, the authority, in case the two drifted while it owned the view.
        if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "editEnd") }
    }

    /// Backspace at the start of the block: the page names the block above (it owns the block structure), then mergeBackward joins them.
    fileprivate func mergeRequested(_ id: Int) {
        guard let e = edit, e.id == id else { return }
        js("sb.prevBlock", ["seq": e.seq])
    }

    private static let joinableTags: Set<String> = ["P", "H1", "H2", "H3", "H4", "H5", "H6", "UL", "OL", "BLOCKQUOTE"]

    /// Joins the edited block's first line onto the last line of the block above; blank lines between them are dropped. The
    /// writer holds keys typed meanwhile and replays them onto the merged text when resetEdit arrives.
    private func mergeBackward(_ m: PageMessage) {
        guard let e = edit, m.int("seq") == e.seq else { return }
        let release = { self.helper { $0.resetEdit(e.id, text: nil, caret: 0) } }
        guard let text = docText, let ps = m.int("start"), let pe = m.int("end"), let tag = m.string("tag", max: 16),
              Self.joinableTags.contains(tag), Self.joinableTags.contains(m.string("curTag", max: 16) ?? ""), ps < pe, pe <= e.start else { return release() }
        var lines = text.components(separatedBy: "\n")
        guard e.start + e.lines <= lines.count, lines[pe..<e.start].allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return release() }
        var prev = Array(lines[ps..<pe])
        while prev.count > 1, prev.last!.trimmingCharacters(in: .whitespaces).isEmpty { prev.removeLast() }
        let cur = Array(lines[e.start..<(e.start + e.lines)])
        let caret = (prev.joined(separator: "\n") as NSString).length
        var merged = prev
        merged[merged.count - 1] += cur[0]
        merged += cur.dropFirst()
        lines.replaceSubrange(ps..<(e.start + e.lines), with: merged)
        let updated = lines.joined(separator: "\n")
        let block = merged.joined(separator: "\n")
        edit = (e.id, e.seq, ps, merged.count)
        retired.removeAll { $0.start < e.start + e.lines && $0.start + $0.lines > ps }
        shiftRetired(from: e.start + e.lines, by: merged.count - (e.start + e.lines - ps))
        log.info("edit \(e.id) merged into lines \(ps)..<\(ps + merged.count)")
        let ver = nextVersion(splicingAt: e.start + e.lines, delta: merged.count - (e.start + e.lines - ps))
        js("sb.editReset", ["seq": e.seq, "doc": updated, "start": ps, "text": block, "caret": caret, "tag": tag, "ver": ver,
                                "at": ps, "old": e.start + e.lines - ps])
        helper { $0.resetEdit(e.id, text: block, caret: caret) }
        save(updated)
    }

    private static func blank(_ s: String) -> Bool { s.trimmingCharacters(in: .whitespaces).isEmpty }

    /// Enter: the edited block keeps `before`, `after` becomes a new paragraph right below it that the edit moves into, and
    /// `tail` (list items below an emptied one) follows as its own block. The writer holds keys typed meanwhile and replays
    /// them onto `after` when resetEdit arrives.
    fileprivate func splitRequested(_ id: Int, before rawBefore: String, after rawAfter: String, tail rawTail: String) {
        let trim = { (s: String) in
            (self.lineEnding == "\n" ? s : s.replacingOccurrences(of: "\r\n", with: "\n")).trimmingCharacters(in: CharacterSet(charactersIn: "\n"))
        }
        let before = trim(rawBefore), after = trim(rawAfter), tail = trim(rawTail)
        guard let e = edit, e.id == id, let text = docText else { return helper { $0.resetEdit(id, text: nil, caret: -1) } }
        var lines = text.components(separatedBy: "\n")
        guard e.start + e.lines <= lines.count,
              !(before.isEmpty && after.isEmpty && tail.isEmpty && lines[e.start..<(e.start + e.lines)].allSatisfy(Self.blank)) else {
            return helper { $0.resetEdit(id, text: nil, caret: -1) }
        }
        let end = e.start + e.lines
        let nextBlank = end >= lines.count || Self.blank(lines[end])
        var repl: [String]
        let newStart: Int
        let block: String
        if before.isEmpty && after.isEmpty && tail.isEmpty {
            // Enter on a list's only, empty item: it becomes an empty paragraph.
            repl = [""]
            newStart = e.start
            block = ""
        } else if before.isEmpty {
            // Enter at the very start opens an empty paragraph above and moves the edit into it.
            let prevBlank = e.start == 0 || Self.blank(lines[e.start - 1])
            repl = (prevBlank ? [] : [""]) + ["", ""] + after.components(separatedBy: "\n")
            newStart = e.start + (prevBlank ? 0 : 1)
            block = ""
        } else {
            let b = before.components(separatedBy: "\n")
            repl = b + [""] + after.components(separatedBy: "\n")
            if !tail.isEmpty { repl += [""] + tail.components(separatedBy: "\n") }
            if !nextBlank { repl.append("") }
            newStart = e.start + b.count + 1
            block = after
        }
        let newLines = block.components(separatedBy: "\n").count
        lines.replaceSubrange(e.start..<end, with: repl)
        let updated = lines.joined(separator: "\n")
        let delta = repl.count - e.lines
        edit = (e.id, e.seq, newStart, newLines)
        shiftRetired(from: end, by: delta)
        log.info("edit \(e.id) split: lines \(newStart)..<\(newStart + newLines)")
        let ver = nextVersion(splicingAt: end, delta: delta)
        js("sb.editReset", ["seq": e.seq, "doc": updated, "start": newStart, "text": block, "caret": 0, "tag": "P", "ver": ver,
                                "at": e.start, "old": e.lines, "repl": repl])
        helper { $0.resetEdit(e.id, text: block, caret: 0) }
        save(updated)
    }

    /// Removes lines [start, start+lines) when they are all blank, plus one blank line so the blocks around them keep a
    /// single separator (none at the start or end of the file).
    private func dropIfEmpty(start: Int, lines count: Int) {
        guard !torn, !tornHalted, let text = docText else { return }
        var lines = text.components(separatedBy: "\n")
        guard count > 0, start + count <= lines.count, lines[start..<(start + count)].allSatisfy(Self.blank) else { return }
        lines.removeSubrange(start..<(start + count))
        var at = start, removed = count
        if start < lines.count, Self.blank(lines[start]), start == 0 || Self.blank(lines[start - 1]) {
            lines.remove(at: start)
            removed += 1
        } else if start == lines.count, start > 0, Self.blank(lines[start - 1]) {
            lines.remove(at: start - 1)
            at -= 1
            removed += 1
        }
        log.info("dropped \(removed) blank lines at \(at)")
        if let e = edit, e.start >= at + removed { edit = (e.id, e.seq, e.start - removed, e.lines) }
        retired.removeAll { $0.start >= at && $0.start < at + removed }
        shiftRetired(from: at + removed, by: -removed)
        let ver = nextVersion(splicingAt: at + removed, delta: -removed)
        js("sb.spliceLines", ["at": at, "old": removed, "lines": [String](), "ver": ver])
        save(lines.joined(separator: "\n"))
    }

    /// `keepRetired` keeps ended sessions whose last keys may still arrive; otherwise the document is being replaced.
    private func stopEdit(notifyWriter: Bool, keepRetired: Bool = false) {
        if !keepRetired { retired = [] }
        guard let e = edit else { return }
        edit = nil
        if notifyWriter { helper { $0.endEdit(e.id) } }
        js("sb.editEnd", ["seq": e.seq])
    }

    private func js(_ fn: String, _ arg: [String: Any]) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: arg), encoding: .utf8)!
        host.web.evaluateJavaScript("\(fn)(\(json)); 0") { _, err in
            if let err { log.error("\(fn, privacy: .public) failed: \(String(describing: err), privacy: .public)") }
        }
    }

    private func status(_ s: String, sticky: Bool = false) {
        let arg = String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!
        host.web.evaluateJavaScript("sb.status(\(arg)[0], \(sticky))", completionHandler: nil)
    }

    private func stickyStatus(_ s: String) { status(s, sticky: true) }
}
