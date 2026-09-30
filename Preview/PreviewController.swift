import Cocoa
import PDFKit
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
private let markdownExtensions = FolderListing.markdownExtensions

private func ms(_ since: Date) -> String { String(format: "%.1f", Date().timeIntervalSince(since) * 1000) }
/// NSEvent timestamps and systemUptime share the boot-time clock, so the writer's key time can be compared here.
private func uptimeMs(since t: Double) -> String { String(format: "%.1f", (ProcessInfo.processInfo.systemUptime - t) * 1000) }

/// Receives the edit buffer from the writer's key-capturing panel.
final class EditHost: NSObject, SpacebarEditHostProtocol {
    private weak var controller: PreviewController?
    init(controller: PreviewController) { self.controller = controller }
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
    func filterChanged(_ session: Int, text: String) {
        DispatchQueue.main.async { self.controller?.filterChanged(session, text: text) }
    }
    func filterKey(_ session: Int, key: String, isRepeat: Bool) {
        DispatchQueue.main.async { self.controller?.filterKey(session, key: key, isRepeat: isRepeat) }
    }
    func filterEnded(_ session: Int, reason: String) {
        DispatchQueue.main.async { self.controller?.filterEnded(session, reason: reason) }
    }
}

/// One WKWebView per extension process, reused across previews so only the first preview pays WebKit start-up.
final class WebHost: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    static let shared = WebHost()
    /// Who shows the page ("quicklook" or "panel"), for its document-start script; set before `shared` is first used.
    static var pageHost = "quicklook"
    let web: WKWebView
    private(set) var ready = false
    private var onReady: [() -> Void] = []
    weak var controller: PreviewController?
    let created = Date()
    let remoteImages: RemoteImageGate
    let scheme: SchemeHandler

    override init() {
        let config = WKWebViewConfiguration()
        scheme = SchemeHandler(webRoot: Bundle.main.resourceURL!.appendingPathComponent("web"))
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
        ucc.addUserScript(PageSettings.userScript(SettingsStore.shared.payload, webRoot: webRoot, host: Self.pageHost))
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
        // Only the shell page loads; links are clicks the page reports, and nothing may open a frame.
        let main = action.targetFrame?.isMainFrame ?? true
        decisionHandler(ShellPolicy.allows(action.request.url, mainFrame: main) ? .allow : .cancel)
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

/// Who holds the arrow keys for the sidebar's list session, which the page asks for (filterBegin with `list`) once
/// `listSessionWanted` has offered one. Keys and the session's end come back through filterKey and filterEnded.
protocol KeySource: AnyObject {
    /// Holds its sessions itself rather than in the writer's panel, so the writer's own ends (it went away, an edit began) are
    /// not its ends: the controller tells it.
    var local: Bool { get }
    /// The preview is on screen over `root`.
    func listSessionWanted(root: String)
    /// Starts list session `id` over the sidebar row clicked; `failed` runs on the main thread when it cannot start.
    func beginList(_ id: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, failed: @escaping () -> Void)
    /// Ends list session `id`, which the controller has already dropped.
    func end(_ id: Int)
}

/// The list session in the writer's key-capturing panel: the page is asked for one whenever the preview is on screen.
final class WriterKeySource: KeySource {
    private weak var controller: PreviewController?
    init(controller: PreviewController) { self.controller = controller }
    var local: Bool { false }

    func listSessionWanted(root: String) {
        controller?.js("sb.listKeysWanted", ["root": root])
    }

    func beginList(_ id: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, failed: @escaping () -> Void) {
        controller?.helper(onError: failed) {
            $0.beginListKeys(id, clickX: clickX, clickY: clickY, rowWidth: rowWidth, rowHeight: rowHeight) { ok in
                if !ok { DispatchQueue.main.async(execute: failed) }
            }
        }
    }

    func end(_ id: Int) { controller?.helper { $0.endFilter(id) } }
}

/// A session of the writer's key panel (or, a list session, of a local key source) and the keys it may send.
struct KeySession {
    let id: Int
    let seq: Int
    let list: Bool
    let find: Bool
    var keys: Set<String> { find ? FilterKeys.findNames : list ? FilterKeys.listNames.union(FilterKeys.listCommands) : FilterKeys.names }
}

/// The preview, whatever hosts it: `start` shows a file or folder, and the host reports its view appearing and going.
class PreviewController: NSViewController {
    /// The page has painted the first preview since `start`.
    var onReady: (Error?) -> Void = { _ in }
    /// `start` declined the item, for the reason given; onReady is not called for it.
    var onDecline: (String) -> Void = { _ in }
    lazy var keySource: KeySource = WriterKeySource(controller: self)

    private let host = WebHost.shared
    private var fileURL: URL?
    /// The folder of the item Quick Look asked for (the folder itself in folder mode), symlinks resolved. Markdown links open in
    /// the panel, where they can be edited, only inside it; others open in the default app like any other document. The
    /// sidebar lists it, for a single file and a folder alike.
    private var rootDir = ""
    private var watcher: FileWatcher?
    /// What the file on screen is; only Markdown is edited, toggled or opened in the editor.
    private var fileKind: FileKind = .markdown
    /// The size and modification time of the non-Markdown file last shown, so a change on disk that changed nothing is skipped.
    private var shownStamp: String?
    /// Whether the viewer offered "Open with" for the file on screen (FileView may take back what LinkPolicy allowed).
    private var shownCanOpen = false
    /// Whether the file on screen is shown as text (code, JSON, CSV, text): its Open button goes through openText, which may use
    /// the chosen editor.
    private var shownText = false
    static let textViews: Set<String> = ["code", "json", "csv", "text"]
    /// The text of the text view on screen, as it was sent to the page (its first 2 MB when `truncated`), for the Copy button.
    private var shownBody: (text: String, truncated: Bool)?
    /// When a ⌘C was last handed to the page: the only time it may send its selection to be copied.
    private var copyAsked: Date?
    func armCopy() { copyAsked = Date() }
    /// The PDF on screen, drawn natively over the page's PDF area; nil for every other view.
    private var pdfPane: PDFPane?
    /// The HTML file on screen, rendered natively over the same reserved area; nil for every other view.
    private var htmlPane: HTMLPane?
    /// The video or audio file on screen, played natively over the same reserved area; nil for every other view.
    private var mediaPane: MediaPane?
    /// A file Apple's Quick Look previews (Office, iWork, fonts, 3D), in its QLPreviewView over the same reserved area; nil for every other view.
    private var qlPane: QLFallbackPane?
    /// Whether the file on screen is shown by `qlPane`, so the panel reappearing shows it again.
    private var quickLookShown = false
    /// A file Apple's preview showed only as an icon, as it was then (stat stamp): shown as text, or its info card, until it changes.
    private var quickLookFailed: (path: String, stamp: String?)?
    /// The RTF or RTFD document on screen, drawn natively over the same reserved area; nil for every other view.
    private var richPane: RichTextPane?
    /// An image ImageIO decodes (HEIC, TIFF, RAW…), drawn natively over the same reserved area; nil for every other view.
    private var imagePane: ImagePane?
    /// The view the last finished show put up for the file on screen (a fallback's "info" or "text" included); nil while it loads.
    private var shownView: String?
    /// The `pdfGen` of the show still loading, which puts its own view up unless a close has since made it stale.
    private var loadingGen: Int?
    /// Bumped by every render, so a thumbnail made for an info card no longer on screen is dropped.
    private var renderGen = 0
    /// The file a thumbnail is being made for: a file changing on disk re-renders its card without starting another.
    private var thumbPending: String?
    /// The app the viewer's Open button names, once the writer has said.
    private var opener: (path: String, app: String, editor: Bool)?
    /// Bumped by every show and close, so a PDF still opening in the background for an older one is dropped.
    private var pdfGen = 0
    /// Every read of the file on screen, off the main thread: a file iCloud has evicted downloads first, which can take long or
    /// never finish offline. Opening another file drops the read in flight.
    private let loader = FileLoader()
    /// The file on screen shows the info card because it could not be read (Reveal in Finder is allowed for it, Markdown too).
    private var unavailablePath: String?
    /// Why the document's local images did not load, the folders their placeholders may reveal, and the watch that renders the
    /// document again when one appears.
    private lazy var images: ImageCheck = {
        let c = ImageCheck()
        c.onAppeared = { [weak self] in
            guard let self, self.edit == nil, !self.torn, self.fileKind == .markdown, let url = self.fileURL, let text = self.docText,
                  self.images.doc == url.path else { return }
            self.push(text: text, path: url.path, reason: "images")
        }
        return c
    }()
    /// Bumped by every write sent: a read that started before a write may hold the bytes the write replaced.
    private var writeEpoch = 0
    /// The file the load in flight reads, while iCloud downloads it: a change event meanwhile waits for that read instead of
    /// starting another one blocked on the same download.
    private var downloading: (url: URL, load: Int, stamp: String)?

    /// The file's identity and version, from stat (which never downloads).
    private static func stamp(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return "\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)-\(st.st_ino)"
    }

    /// Whether a read of `url` is already waiting on the download of the very version now at the path (a new version
    /// swapped in while evicted is read again).
    private func awaitingDownload(_ url: URL) -> Bool {
        guard let d = downloading, d.url == url, loader.isActive(d.load), FileTypes.isDataless(url.path) else { return false }
        return Self.stamp(url) == d.stamp
    }
    /// A multiple selection's names in the root: the root's listing shows only these.
    private var selectionNames: Set<String>?
    /// The sidebar's folders as last sent, by path; `open` from the page is limited to their files.
    private var listings: [String: FolderListing.Listing] = [:]
    /// Folders the page may ask to list: the root and every folder a listing named. Nothing above the root is ever in it.
    private var knownDirs: Set<String> = []
    private var listGens: [String: Int] = [:]
    /// Folder mode's first open: run by whichever listing lands first, since a newer one (a .DS_Store write) supersedes older ones.
    private var onListed: ((FolderListing.Listing) -> Void)?
    private var listedWith: (sort: String, readmeFirst: Bool, hidden: Bool)?
    /// The root and every folder expanded in the sidebar, each re-listed when it changes.
    private var dirWatches: [String: FolderWatch] = [:]
    private static let maxWatches = 64
    /// Files the page may open that no listing named: the overview's recent files and the targets of the document's wikilinks,
    /// each found by a bounded scan inside the root.
    private var offered: Set<String> = []
    /// The sidebar's Contents search in flight, and the files the page's list of results holds (the last search to report),
    /// which the page may open.
    private var search: (seq: Int, cancel: ContentSearch.Cancel)?
    private var searchHits: (seq: Int, paths: Set<String>) = (0, [])
    /// The folder overview is on screen (no file is).
    private var showingOverview = false
    /// A folder preview has not opened anything yet.
    private var folderPending = false
    private var scanGen = 0
    /// One scan at a time: a request while one runs is kept (the latest) and run when it ends.
    private var scanning = false
    private var rescan: Bool?
    private var rescanTimer = false
    /// The sidebar's folder name was clicked: the overview is wanted even though a file is on screen.
    private var overviewRequested = false
    /// A heading to scroll to once the file at `path` renders (a wikilink's `#heading`).
    private var pendingAnchor: (path: String, anchor: String)?
    /// The wikilink index of the root, shared by the previews of one extension process; rebuilt when stale, used meanwhile.
    private static var linkIndex: LinkIndex?
    private static var indexBuilding: String?
    private var indexStale = false
    /// The links of the last Markdown render, reused while its set of targets is unchanged (every keystroke saves and renders).
    private var linkMemo: (targets: [String], root: String, path: String, links: [String: Any], embeds: [String: Any])?
    private var targetsMemo: (text: String, targets: [String])?
    private var linkGen = 0
    private static var sessions = 0
    private let session: Int = { PreviewController.sessions += 1; return PreviewController.sessions }()
    /// Latest document the preview intends to be on disk (includes queued edits).
    private var docText: String?
    /// Last content confirmed on disk, in its on-disk line endings; every write must name it as its base.
    private var diskText: String? { didSet { syncedText = nil } }
    /// A text known to be diskText as shown (onDisk of it is diskText): docText is compared with it first, since comparing a
    /// large document with its CRLF form, or two copies of it, costs the main thread tens of ms and more.
    private var syncedText: String?
    /// The file on screen when it is text spacebar edits as a whole (not Markdown): how its bytes read and are written back.
    /// docText and diskText then hold the text as edited (LF), and the source gives the bytes.
    private var textSource: EditableText.Source?
    /// The last payload of that file's view, rendered again with docText once an edit ends.
    private var textPayload: [String: Any]?
    /// The sticky status says a save was refused for a character the encoding cannot hold.
    private var encodeRefused = false
    /// Unsaved text the writer will no longer take (it restarted and does not know it was typed): shown until the user leaves,
    /// which is then allowed.
    private var textStranded = false
    /// "\r\n" for a file whose every line ends in CRLF. docText and the page always use "\n"; writes convert back.
    private var lineEnding = "\n" { didSet { syncedText = nil } }
    private func onDisk(_ text: String) -> String { lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding) }
    /// Whether `text` is what is on disk (onDisk(text) == diskText).
    private func matchesDisk(_ text: String) -> Bool {
        // Lengths first only where they are free (native storage): a bridged string counts them by reading it all.
        let n = { (x: String) in x.utf8.withContiguousStorageIfAvailable { $0.count } }
        if let s = syncedText, n(s).flatMap({ a in n(text).map { a == $0 } }) ?? true, s == text { return true }
        return onDisk(text) == diskText
    }
    private var prepareStart = Date()
    /// onReady is owed for the current start.
    private var readyPending = false
    private var reloadPending = false
    private var changeSeen = Date()
    /// The block being edited: writer session id, the page's click sequence number, and its line range in docText.
    private var edit: (id: Int, seq: Int, start: Int, lines: Int)? { didSet { keysMoved() } }
    /// The session a click just replaced: keys typed into it before the writer switched arrive late and are still applied.
    private var retired: [(id: Int, seq: Int, start: Int, lines: Int)] = []
    /// The sidebar filter, the sidebar's list or the find field holding the keyboard: writer session id (from editCounter) and
    /// the page's sequence number.
    private var filter: KeySession? { didSet { keysMoved() } }
    private var writerHasKeys = false
    private var keysCheckQueued = false

    /// Checked once the turn is over: a filter handing over to an edit keeps the keys throughout.
    private func keysMoved() {
        guard !keysCheckQueued else { return }
        keysCheckQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.keysCheckQueued = false
            let held = self.edit != nil || self.filter.map { !self.heldLocally($0) } == true
            guard held != self.writerHasKeys else { return }
            self.writerHasKeys = held
            self.writerKeysChanged(held)
        }
    }

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
    /// What leaves the current document once its edit's last keys and saves have landed.
    private enum Pending {
        case file(URL, anchor: String?)
        case overview(FolderScan.Result, reason: String)
        case update
    }
    private var pending: Pending?
    private var pendingGen = 0

    /// Ends the edit and, while its keys or saves are still landing, holds `action` until they have. Refuses it while text that
    /// failed to save is only on screen: leaving would lose it. True when the action must not run now.
    private func holdUntilSaved(_ action: Pending) -> Bool {
        if let e = edit { stopEdit(notifyWriter: true, keepRetired: true); retired.append(e) }
        guard writing || !retired.isEmpty else {
            dropPending()
            guard hasUnsavedText else { return false }
            log.error("refused to leave the document: unsaved text")
            refuseToLeave(action, "unsaved text")
            return true
        }
        log.info("switch waits for the edit's saves (writing=\(self.writing) retired=\(self.retired.count))")
        if pending == nil { armPending() }
        if case .update = action {} else { dropPending() }
        pending = action
        return true
    }

    /// Text on screen that is not on disk: a save failed, or a write was torn.
    private var hasUnsavedText: Bool { !textStranded && (torn || tornHalted || (docText.map { !matchesDisk($0) } ?? false)) }

    /// The writer refused unsaved text of the text file on screen: it can no longer be saved, so the user is told to copy it and
    /// may leave. True when that is the case.
    private func strandText() -> Bool {
        guard textSource != nil, hasUnsavedText else { return false }
        textStranded = true
        encodeRefused = false
        stickyStatus("NOT SAVED: this text can no longer be saved to the file; copy it now. The file on disk is unchanged.")
        return true
    }

    /// Clears the waiting action; an update it replaces goes back to being offered.
    private func dropPending() {
        if case .update = pending, installable, let v = offeredVersion { js("sb.update", ["state": "available", "version": v]) }
        pending = nil
    }

    private func refuseToLeave(_ action: Pending, _ why: String) {
        if case .update = action, let v = offeredVersion {
            let reason = why == "unsaved text" ? "Not started: unsaved text. Edit again to save it first." : "Not started: \(why)."
            js("sb.update", ["state": "failed", "version": v, "reason": reason, "retry": true])
        } else {
            status("not switched: \(why)")
        }
    }

    private func armPending() {
        pendingGen += 1
        let gen = pendingGen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pending != nil, self.pendingGen == gen else { return }
            // A write in flight is never given up on: its reply, or the writer's loss, decides.
            if self.writing {
                self.status("still saving…")
                return self.armPending()
            }
            // A writer that never reports an edit's end (hung, not crashed) must not keep the panel on this document.
            log.error("switch: writer did not end the edit within 2s")
            self.retired = []
            self.runPending()
        }
    }

    private func runPending() {
        guard !writing, retired.isEmpty, let p = pending else { return }
        pending = nil
        // Text that never reached the disk (a character the file's encoding cannot hold) keeps the panel on this document.
        if case .update = p {} else if hasUnsavedText { return refuseToLeave(p, "unsaved text") }
        switch p {
        case .file(let url, let anchor): open(url, anchor: anchor)
        case .overview(let r, let reason): showOverview(r, reason: reason)
        case .update:
            // The edit and its saves are done by now; anything left unsaved keeps the update from starting.
            if edit == nil, !hasUnsavedText { startUpdate() } else { refuseToLeave(.update, "unsaved text") }
        }
    }

    /// A save failed while something waited on it: the panel stays on this document, with its unsaved text.
    private func cancelPending(_ why: String) {
        guard let p = pending else { return }
        pending = nil
        pendingGen += 1
        refuseToLeave(p, why)
    }
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
        GestureRouter.install()
        host.web.removeFromSuperview()
        host.web.autoresizingMask = [.width, .height]
        let container = makeRoot(frame: NSRect(x: 0, y: 0, width: 900, height: 700))
        host.web.frame = container.bounds
        container.addSubview(host.web)
        view = container
        preferredContentSize = NSSize(width: 900, height: 700)
    }

    /// The view the page is shown in.
    func makeRoot(frame: NSRect) -> NSView { NSView(frame: frame) }

    /// The host is about to show the view again.
    func hostWillAppear() {
        // Shown again without a new prepare: the native view closed when the preview disappeared, so bring it back. Not a view
        // that fell back to text or an info card, and not a load still under way: either would be shown twice.
        if let v = shownView {
            if !hasPane(v) { reshow() }
            return
        }
        if loadingGen == pdfGen { return }
        let closed = (fileKind == .pdf && pdfPane == nil) || (fileKind == .html && htmlPane == nil) || ([.video, .audio].contains(fileKind) && mediaPane == nil)
            // Apple's preview by its type, not only by quickLookShown: a load still running when the panel went is stale, and
            // its completion would leave the page on "Loading…".
            || (fileKind == .other && qlPane == nil && (quickLookShown || fileURL.flatMap { FileTypes.appleQuickLookType($0.path) } != nil))
            || (fileKind == .rtf && richPane == nil)
            || (fileKind == .image && imagePane == nil && fileURL.map { FileTypes.nativeImageExtensions.contains($0.pathExtension.lowercased()) } == true)
        if closed { reshow() }
    }

    private func hasPane(_ view: String) -> Bool {
        switch view {
        case "pdf": return pdfPane != nil
        case "html": return htmlPane != nil
        case "video", "audio": return mediaPane != nil
        case "quicklook": return qlPane != nil
        case "rtf": return richPane != nil
        case "bitmap": return imagePane != nil
        default: return true
        }
    }

    private func reshow() {
        guard let url = fileURL, host.controller === self else { return }
        shownStamp = nil
        host.whenReady { [weak self] in self?.show(url, reason: "open") }
    }

    /// The view is on screen.
    func hostAppeared() {
        appeared = true
        htmlPane?.view.setAllMediaPlaybackSuspended(false)
        host.web.setAllMediaPlaybackSuspended(false)
        wantListKeys()
    }

    /// The host hides the view for a while and will show it again as it is (`hostAppeared`): the keys are let go and media
    /// paused, but the native views stay.
    func hostSuspending() {
        appeared = false
        stopEdit(notifyWriter: true)
        stopFilter(notifyWriter: true)
        mediaPane?.pause()
        htmlPane?.view.setAllMediaPlaybackSuspended(true)
        host.web.setAllMediaPlaybackSuspended(true)
    }

    /// The host is taking the view away.
    func hostDisappearing() {
        appeared = false
        host.scheme.body = nil
        stopEdit(notifyWriter: true)
        stopFilter(notifyWriter: true)
        host.remoteImages.reset()
        closePDF()
    }

    /// Runs whenever the page reports a paint or a render.
    func pageRendered() {}

    /// Whether `start` launches the writer ahead of the first click when inline editing is on.
    var prewarmsWriter: Bool { true }

    /// A list session ended without asking for another: `reason` is the key source's ("escape" gave the keys back to the host).
    /// The page says what the next key does, by its host.
    func listSessionEnded(reason: String) { js("sb.listEnded", ["reason": reason]) }

    /// The writer's key panel took the keyboard for an edit, the filter or the find field, or let it go.
    func writerKeysChanged(_ held: Bool) {}

    /// The htmlScripts setting that applies to `url`, an HTML file about to be shown.
    func htmlScripts(for url: URL) -> String { SettingsStore.shared.settings.htmlScripts }

    /// The web view the page is in.
    var webView: WKWebView { host.web }

    /// ⌘+, ⌘− or ⌘0 (`key` zoomIn, zoomOut, zoomReset) for a native view on screen that zooms; whether it took the key.
    func zoomKey(_ key: String) -> Bool { fileKind == .image && imagePane?.key(key) == true }

    /// Puts the file on screen on the clipboard as a file, as Finder's ⌘C does, for a host whose ⌘C found no text to copy.
    func copyFileOnScreen() {
        guard let url = fileURL else { return }
        NSPasteboard.general.clearContents()
        let ok = NSPasteboard.general.writeObjects([url as NSURL])
        status(ok ? "Copied \(url.lastPathComponent)" : "Could not copy")
    }

    /// The Open button's action for the file on screen, for a host with a key for it (⌘O).
    func openOnScreen() {
        guard let url = fileURL, shownView != "info" || shownCanOpen else { return }
        if fileKind == .markdown { return openExternally(url) }
        handle("openFile", ["path": url.path])
    }

    /// ⌘C with nothing selected, in a host that writes the pasteboard itself: the file and its text as one item, so Finder
    /// pastes the file and an editor the text. False leaves the copy to the writer, as text.
    func copyFileAndText(_ url: URL, _ text: String) -> Bool { false }

    deinit {
        if let id = edit?.id { (helperConnection?.remoteObjectProxy as? SpacebarWriterProtocol)?.endEdit(id) }
        if let f = filter {
            if heldLocally(f) { keySource.end(f.id) } else { (helperConnection?.remoteObjectProxy as? SpacebarWriterProtocol)?.endFilter(f.id) }
        }
        helperConnection?.invalidate()
        log.info("controller deinit")
    }

    /// Shows `url`, a file or a folder; `reason` names what asked, for the settings check. The host holds any access `url` needs.
    func start(url: URL, reason: String) { start(url: url, reason: reason, only: nil) }

    /// Shows the first file of `urls` (Finder's selection) with a sidebar of just the selection: the items in that file's folder.
    func start(selection urls: [URL], reason: String) {
        let parent = { (u: URL) in u.deletingLastPathComponent().resolvingSymlinksInPath().path }
        guard urls.count > 1, let first = urls.first(where: { !$0.hasDirectoryPath && !FolderListing.isDirectory($0.path) }) else {
            return urls.first.map { start(url: $0, reason: reason) } ?? ()
        }
        let names = Set(urls.filter { parent($0) == parent(first) }.map(\.lastPathComponent))
        start(url: first, reason: reason, only: names.count > 1 ? names : nil)
    }

    private func start(url: URL, reason: String, only: Set<String>?) {
        prepareStart = Date()
        SettingsStore.shared.checkNow(reason: reason)
        let warm = host.ready
        log.info("prepare \(url.path, privacy: .private) warm=\(warm) processAge=\(processAgeMs(), privacy: .public)ms wall=\(Date().timeIntervalSince1970, privacy: .public)")
        // The previous preview's native views go now, not whenever Quick Look lets its controller go: a player must fall silent.
        // Its filter session too, and the writer is told: the key panel must not stay over a field no controller owns.
        if host.controller !== self {
            host.controller?.stopNativeViews()
            host.controller?.handOver()
            // The page's update state (a busy flag, a pending re-check) was the last controller's. A page still loading has none.
            if host.ready { js("sb.updateReset", [:]) }
        }
        stopFilter(notifyWriter: true)
        host.controller?.stopSearch()
        stopSearch()
        host.controller = self
        readyPending = true
        // The page outlives the controller that began a filter session; the new preview starts with none. A page still
        // loading has no session, and no `sb` to call.
        if host.ready { js("sb.filterEnd", ["all": true]) }
        // Nor any search: a page still showing results asks again, of this preview.
        if host.ready { js("sb.searchAgain", [:]) }

        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let resolved = only == nil ? url.resolvingSymlinksInPath()
            : URL(fileURLWithPath: url.deletingLastPathComponent().resolvingSymlinksInPath().path).appendingPathComponent(url.lastPathComponent)
        rootDir = isDir.boolValue ? resolved.path : resolved.deletingLastPathComponent().path
        selectionNames = only
        if !isDir.boolValue, only == nil, !FolderRules.isQuarantined(resolved.path) { rootDir = FolderRules.vaultRoot(containing: rootDir) ?? rootDir }
        host.scheme.fileRoot = rootDir
        knownDirs = [rootDir]
        searchHits = (0, [])
        wantListKeys()
        listings = [:]
        offered = []
        showingOverview = false
        folderPending = false
        overviewRequested = false
        rescan = nil
        scanGen += 1
        pendingAnchor = nil
        linkMemo = nil
        targetsMemo = nil
        if isDir.boolValue {
            // Folder previews can be turned off; declining hands the folder back to Quick Look's own preview. Everything else a
            // folder preview declines (packages, volumes, system folders) is known here, before anything starts.
            guard SettingsStore.shared.settings.folderMode else { return decline("folder previews are off") }
            if let why = FolderRules.declineReason(resolved.path) { return decline(why) }
            startFolder()
        } else {
            // The path inside the resolved folder (in a vault, the vault), as the sidebar lists it.
            open(URL(fileURLWithPath: resolved.deletingLastPathComponent().path).appendingPathComponent(resolved.lastPathComponent))
            refreshListing(rootDir)
        }
        watch(rootDir)
        // Launch the writer and build its hidden edit panel now, so the first click into a block does not wait for either.
        // Inline editing off: no writer launch until something needs it, but the support folder still gets made.
        if SettingsStore.shared.settings.inlineEditing {
            if prewarmsWriter { helper { $0.prepare() } }
        } else if !FileManager.default.fileExists(atPath: SettingsFile.url.path) {
            helper { $0.ensureSupportDir { _ in DispatchQueue.main.async { SettingsStore.shared.checkNow(reason: "created") } } }
        }
        // Not while a folder waits for its first listing: the panel would show the previous preview's document.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in if self?.folderPending == false { self?.finishPrepare(nil) } }
    }

    /// A folder preview opens on its README, else its first Markdown file, else the most relevant Markdown a bounded search of
    /// its subfolders finds, else the folder overview. A folder that is slow to read shows the overview's loading state first.
    private func startFolder() {
        folderPending = true
        refreshListing(rootDir, then: { [weak self] l in
            guard let self else { return }
            log.info("folder preview: \(l.entries.count + l.more) items")
            if let first = FolderListing.firstDocument(l) {
                self.folderPending = false
                self.open(URL(fileURLWithPath: first.path))
            } else {
                self.scanFolder(openBest: true)
            }
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.folderPending else { return }
            self.showOverview(FolderScan.Result(root: self.rootDir, complete: false), reason: "loading")
        }
    }

    /// Scans the root off the main thread (FolderScan: bounded in depth, entries and time), then opens the Markdown it found
    /// (`openBest`) or shows the overview.
    private func scanFolder(openBest: Bool) {
        if scanning { rescan = openBest || rescan == true; return }
        scanning = true
        scanGen += 1
        let gen = scanGen, root = rootDir, hidden = SettingsStore.shared.settings.showHiddenFiles
        DispatchQueue.global(qos: .userInitiated).async {
            let r = FolderScan.scan(root, showHidden: hidden)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.scanning = false
                if let again = self.rescan {
                    self.rescan = nil
                    self.scanFolder(openBest: again)
                    return
                }
                self.rescan = nil
                // A file opened since the scan started (open() moves scanGen on) wins over what the scan would show.
                guard gen == self.scanGen, root == self.rootDir, !self.torn,
                      openBest ? self.folderPending : (self.showingOverview || self.overviewRequested) else { return }
                self.overviewRequested = false
                log.info("folder scan: \(r.scanned) entries, \(r.files.count) files, complete=\(r.complete)")
                if openBest, let md = r.bestMarkdown {
                    self.folderPending = false
                    self.offer([md.path])
                    self.open(URL(fileURLWithPath: md.path))
                    return
                }
                self.showOverview(r, reason: openBest ? "open" : "overview")
            }
        }
    }

    private func offer(_ paths: [String]) {
        if offered.count > 4096 { offered = [] }
        offered.formUnion(paths)
    }

    /// The folder overview: nothing else is on screen, so edits, the file watch and the PDF view end.
    private func showOverview(_ r: FolderScan.Result, reason: String) {
        guard !torn else { return }
        if reason == "loading" {
            dropPending()
        } else {
            if holdUntilSaved(.overview(r, reason: reason)) { return }
            folderPending = false
        }
        stopEdit(notifyWriter: true)
        queuedSave = nil
        closePDF()
        host.remoteImages.reset()
        images.reset()
        fileURL = nil
        fileKind = .other
        quickLookShown = false
        watcher = nil
        docText = nil
        diskText = nil
        shownStamp = nil
        shownCanOpen = false
        shownText = false
        shownBody = nil
        showingOverview = true
        loader.cancel()
        unavailablePath = nil
        offer(r.recent.map(\.path))
        host.scheme.body = nil
        let json = String(data: try! JSONSerialization.data(withJSONObject: r.payload(reason: reason)), encoding: .utf8)!
        host.whenReady { [host] in
            host.remoteImages.whenInPlace {
                host.web.evaluateJavaScript("sb.render(\(json)); 0") { _, err in
                    if let err { log.error("overview eval failed: \(String(describing: err), privacy: .public)") }
                }
            }
        }
    }

    private func decline(_ why: String) {
        log.info("declined: \(why, privacy: .public)")
        readyPending = false
        onDecline(why)
    }

    fileprivate func settingsChanged(_ s: Settings) {
        if !s.inlineEditing, edit != nil { stopEdit(notifyWriter: true) }
        if let w = listedWith, w.hidden != s.showHiddenFiles { indexStale = true }
        if let w = listedWith, w != (s.folderSort, s.folderReadmeFirst, s.showHiddenFiles) {
            for dir in Set(listings.keys).union(dirWatches.keys) { refreshListing(dir) }
        }
    }

    /// Watches `dir` (the root, or a folder expanded in the sidebar) and re-lists it when it changes.
    private func watch(_ dir: String) {
        guard dirWatches[dir] == nil, dirWatches.count < Self.maxWatches else { return }
        dirWatches[dir] = FolderWatch(path: dir) { [weak self] in
            guard let self else { return }
            self.indexStale = true
            self.refreshListing(dir)
            if dir == self.rootDir, self.showingOverview, !self.folderPending { self.scheduleRescan() }
        }
    }

    /// The overview follows changes to the root, at most once a second (downloads and .DS_Store writes come in bursts).
    private func scheduleRescan() {
        guard !rescanTimer else { return }
        rescanTimer = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.rescanTimer = false
            if self.showingOverview, !self.folderPending { self.scanFolder(openBest: false) }
        }
    }

    /// Lists `dir` off the main thread, then sends the page the list when it changed. `then` sees the new listing first.
    private func refreshListing(_ dir: String, then: ((FolderListing.Listing) -> Void)? = nil) {
        let gen = (listGens[dir] ?? 0) + 1
        listGens[dir] = gen
        if let then { onListed = then }
        let root = rootDir, s = SettingsStore.shared.settings, pinned = fileURL?.path, only = dir == rootDir ? selectionNames : nil
        listedWith = (s.folderSort, s.folderReadmeFirst, s.showHiddenFiles)
        DispatchQueue.global(qos: .userInitiated).async {
            var l = FolderListing.list(dir, root: root, sort: s.folderSort, readmeFirst: s.folderReadmeFirst, showHidden: s.showHiddenFiles, pinned: pinned)
            if let only { l = FolderListing.only(l, names: only) }
            DispatchQueue.main.async { [weak self] in
                guard let self, gen == self.listGens[dir], root == self.rootDir else { return }
                let changed = l != self.listings[dir]
                self.listings[dir] = l
                for f in l.folders { self.knownDirs.insert(f.path) }
                if dir == root, let f = self.onListed { self.onListed = nil; f(l) }
                if changed { self.sendListing(l) }
            }
        }
    }

    private func sendListing(_ l: FolderListing.Listing) {
        host.whenReady { [weak self] in
            guard let self, self.host.controller === self, self.listings[l.dir] == l else { return }
            var p = l.payload(root: self.rootDir)
            p["session"] = self.session
            self.js("sb.setFiles", p)
        }
    }

    private func finishPrepare(_ error: Error?) {
        pageRendered()
        guard readyPending else { return }
        readyPending = false
        onReady(error)
    }

    /// Why `url` cannot be previewed: a document must be a regular file (after symlinks) of bounded size, so a `.md` that is a
    /// FIFO or a link to /dev/zero cannot hang or exhaust the extension.
    private static func unreadable(_ url: URL) -> String? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return "cannot read \(url.lastPathComponent)" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "\(url.lastPathComponent) is not a regular file" }
        return st.st_size <= FolderListing.maxDocumentBytes ? nil : "\(url.lastPathComponent) is too large to preview"
    }

    private func open(_ url: URL, anchor: String? = nil) {
        if torn { return status("NOT SAVED: file partly written; retrying before switching") }
        var st = stat()
        let found = stat(url.path, &st) == 0
        let kind = found ? FileTypes.kind(name: url.lastPathComponent, isDirectory: st.st_mode & S_IFMT == S_IFDIR, isPackage: st.st_mode & S_IFMT == S_IFDIR,
                                          executable: st.st_mode & 0o111 != 0) : .other
        var refusal: String?
        if !found || (kind == .markdown && Self.unreadable(url) != nil) || (kind != .markdown && st.st_mode & S_IFMT != S_IFREG && st.st_mode & S_IFMT != S_IFDIR) {
            refusal = FileView.openRefusal(url.path)
            log.error("open: \(refusal!, privacy: .private)")
        }
        // The document being edited keeps its last keys: the edit ends, and the switch waits for the writer to flush them and
        // for every save of this document to land.
        if holdUntilSaved(.file(url, anchor: anchor)) { return }
        stopEdit(notifyWriter: true)
        queuedSave = nil
        loader.cancel()
        // The next file's view replaces the player once it is read; it is silent from now.
        mediaPane?.pause()
        unavailablePath = nil
        host.remoteImages.reset()
        images.reset()
        showingOverview = false
        folderPending = false
        overviewRequested = false
        scanGen += 1
        pendingAnchor = anchor.map { (url.path, $0) }
        fileURL = url
        fileKind = kind
        quickLookShown = false
        shownView = nil
        shownStamp = nil
        shownCanOpen = false
        shownText = false
        shownBody = nil
        docText = nil
        diskText = nil
        textSource = nil
        textPayload = nil
        lineEnding = "\n"
        if encodeRefused || textStranded { encodeRefused = false; textStranded = false; stickyStatus("") }
        if let refusal {
            watcher = nil
            return host.whenReady { self.showUnopenable(url, note: refusal) }
        }
        watcher = FileWatcher(path: url.path) { [weak self] in self?.fileChanged() }
        host.whenReady { self.reload(reason: "open") }
    }

    /// The info card for an item that cannot be opened at all (a link that loops or leads nowhere, a FIFO): never a blank panel.
    private func showUnopenable(_ url: URL, note: String) {
        guard fileURL == url else { return }
        stopEdit(notifyWriter: true)
        docText = nil
        diskText = nil
        textSource = nil
        textPayload = nil
        closePDF()
        shownView = "info"
        shownStamp = nil
        shownCanOpen = false
        shownText = false
        shownBody = nil
        unavailablePath = url.path
        render(FileView.unopenable(path: url.path, root: rootDir, note: note))
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
        guard fileKind == .markdown else { return show(url, reason: reason) }
        if let why = Self.unreadable(url) {
            log.error("read refused: \(why, privacy: .private)")
            // A save that replaces the file (rename, then write) leaves it missing for a moment: what is on screen stays.
            return reason == "change" ? status(why) : showUnopenable(url, note: FileView.openRefusal(url.path))
        }
        if reason == "change", awaitingDownload(url) { return }
        let epoch = writeEpoch, cloud = FileTypes.isDataless(url.path)
        // A conflict keeps the rejected text on screen until the file's own text arrives: it may be the only copy left to copy.
        let quiet = reason == "conflict"
        let id = loader.load(timesOut: cloud, { Result { () -> (String, Lines) in let raw = try FileView.readDocument(url); return (raw, Self.lines(raw)) } }) { [weak self] outcome in
            guard let self, self.host.controller === self, self.fileURL == url, self.fileKind == .markdown else { return }
            switch outcome {
            case .timedOut:
                log.error("read timed out \(url.path, privacy: .private)")
                // A document already on screen stays, as it does when a read fails.
                if self.docText == nil, !quiet { self.showUnavailable(url, reason: reason, cloud: cloud) }
            case .done(.failure(let error)):
                log.error("read failed \(url.path, privacy: .private): \(error.localizedDescription, privacy: .private)")
                // A document already on screen stays (a save swapping the file can fail one read); a new one gets the card.
                if self.docText == nil, !quiet { self.showUnavailable(url, reason: reason, cloud: cloud || FileTypes.isDataless(url.path)) }
            case .done(.success(let (raw, lines))):
                // Bytes read before a write started may be what the write replaced: the write's own reload reads again.
                guard !self.writing, !self.torn, epoch == self.writeEpoch else { return }
                self.apply(raw, lines, url: url, reason: reason)
            }
        }
        if cloud, let s = Self.stamp(url) { downloading = (url, id, s) }
        if docText == nil, !quiet { showLoading(url, load: id, cloud: cloud) }
    }

    typealias Lines = (text: String, crlf: Bool, targets: [String]?)
    /// A Markdown file's text with CRLF line ends made LF when every line ends so, in native UTF-8 (PageBody), and its link
    /// targets. Off the main thread: each reads the whole file.
    private static func lines(_ raw: String) -> Lines {
        let crlf = raw.contains("\r\n") && !raw.replacingOccurrences(of: "\r\n", with: "").utf8.contains(10)
        let text = crlf ? TextDecoding.nativeUTF8(raw.replacingOccurrences(of: "\r\n", with: "\n")) : raw
        return (text, crlf, text.contains("[[") ? linkTargets(text) : nil)
    }

    private static func linkTargets(_ text: String) -> [String] { LinkIndex.links(in: text).map { ($0.embed ? "!" : "") + $0.target } }

    /// The link targets of `text`: those the read found off the main thread while it is still the text.
    private func linkTargets(_ text: String) -> [String] {
        if let m = targetsMemo, m.text == text { return m.targets }
        let t = Self.linkTargets(text)
        targetsMemo = (text, t)
        return t
    }

    /// Takes a Markdown read that is still current: `raw` is the file's text as on disk, `lines` its text as shown.
    private func apply(_ raw: String, _ lines: Lines, url: URL, reason: String) {
        if raw == diskText { return }
        if edit == nil, let d = docText, !matchesDisk(d) { status("unsaved text replaced by the version on disk") }
        lineEnding = lines.crlf ? "\r\n" : "\n"
        let text = lines.text
        if let t = lines.targets { targetsMemo = (text, t) }
        // Ranges of ended sessions refer to the old text; their late keys must not land in the new one.
        retired = []
        if edit != nil {
            log.info("file changed on disk during edit; stopping edit")
            stopEdit(notifyWriter: true)
            status("changed on disk: edit stopped")
        }
        docText = text
        diskText = raw
        syncedText = text
        let end = text.lastIndex { $0 != "\n" }.map { text.index(after: $0) } ?? text.startIndex
        let last = text[..<end].lastIndex(of: "\n").map { text[text.index(after: $0)..<end] } ?? text[..<end]
        log.info("read \(text.utf8.count) bytes, last line: \(String(last), privacy: .private)")
        push(text: text, path: url.path, reason: reason)
    }

    /// "Loading…" in place of the file while load `id` runs: at once for a file iCloud must download, else only once a read
    /// is slow, so a local file never flashes it. The previous file's view goes, the native PDF with it.
    private func showLoading(_ url: URL, load id: Int, cloud: Bool) {
        let show = { [weak self] in
            guard let self, self.host.controller === self, self.loader.isActive(id), self.fileURL == url else { return }
            self.pdfPane?.close()
            self.pdfPane = nil
            self.htmlPane?.close()
            self.htmlPane = nil
            self.mediaPane?.close()
            self.mediaPane = nil
            self.qlPane?.close()
            self.qlPane = nil
            self.richPane?.close()
            self.richPane = nil
            self.imagePane?.close()
            self.imagePane = nil
            var p = FileView.base(path: url.path, root: self.rootDir, reason: "open")
            p["view"] = "loading"
            p["cloud"] = cloud
            self.render(p)
        }
        if cloud { show() } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: show) }
    }

    /// The info card for a file that could not be read in time. A later change on disk (the download landing) reads it again.
    private func showUnavailable(_ url: URL, reason: String, cloud: Bool) {
        closePDF()
        shownView = "info"
        shownStamp = nil
        shownCanOpen = false
        shownText = false
        shownBody = nil
        unavailablePath = url.path
        render(FileView.unavailable(path: url.path, kind: fileKind, root: rootDir, reason: reason, cloud: cloud))
    }

    private func render(_ payload: [String: Any]) {
        renderGen += 1
        var payload = payload
        host.scheme.body = PageBody.take(&payload)
        host.scheme.bodyCurrent = { [weak self] path in
            guard let self, self.host.controller === self else { return false }
            return self.fileURL?.path == path
        }
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        host.remoteImages.whenInPlace { [host] in
            host.web.evaluateJavaScript("sb.render(\(json)); 0") { _, err in
                if let err { log.error("render eval failed: \(String(describing: err), privacy: .public)") }
            }
        }
    }

    private func push(text: String, path: String, reason: String, keyTime: Double? = nil) {
        closePDF()
        unavailablePath = nil
        var payload = FileView.base(path: path, root: rootDir, reason: reason)
        payload["text"] = text
        payload["view"] = "markdown"
        if let keyTime { payload["keyTime"] = keyTime }
        if host.remoteImages.allowedPath == path { payload[RemoteImageGate.payloadKey] = true }
        payload["ver"] = docVersion
        if let a = pendingAnchor, a.path == path { payload["anchor"] = a.anchor; pendingAnchor = nil }
        if text.contains("[[") { addLinks(&payload, text: text, path: path) }
        render(payload)
    }

    /// The document's wikilinks and embeds, resolved against the root's index (LinkIndex) off the main thread: resolving stats
    /// and realpaths every target and reads embedded notes, which may be in iCloud and not downloaded. A render uses the last
    /// result for this file (exact while its set of targets is unchanged); a new result that differs renders the file again.
    private func addLinks(_ payload: inout [String: Any], text: String, path: String) {
        let hidden = SettingsStore.shared.settings.showHiddenFiles
        let idx = Self.linkIndex.flatMap { $0.root == rootDir ? $0 : nil }
        if idx == nil || indexStale || Date().timeIntervalSince(idx!.built) > 30 { buildIndex(hidden: hidden) }
        let targets = linkTargets(text)
        payload["linksComplete"] = idx?.complete ?? true
        if let m = linkMemo, m.root == rootDir, m.path == path {
            payload["links"] = m.links
            payload["embeds"] = m.embeds
            payload["linksReady"] = true
            if m.targets == targets { return }
        } else {
            payload["linksReady"] = false
        }
        if let idx { resolveLinks(idx, text: text, path: path, targets: targets) }
    }

    private func resolveLinks(_ idx: LinkIndex, text: String, path: String, targets: [String]) {
        linkGen += 1
        let gen = linkGen, root = rootDir
        DispatchQueue.global(qos: .userInitiated).async {
            let r = idx.payload(text: text, current: path)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.host.controller === self, gen == self.linkGen, root == self.rootDir, self.fileURL?.path == path,
                      self.fileKind == .markdown else { return }
                self.offer(Array(r.paths))
                let old = self.linkMemo
                let same = old.map { $0.path == path && NSDictionary(dictionary: $0.links).isEqual(to: r.links)
                    && NSDictionary(dictionary: $0.embeds).isEqual(to: r.embeds) } ?? false
                self.linkMemo = (targets, root, path, r.links, r.embeds)
                // An edit in progress keeps its view; the next save renders with these.
                guard !same, self.edit == nil, !self.writing, !self.torn, let t = self.docText else { return }
                self.push(text: t, path: path, reason: "links")
            }
        }
    }

    /// Every preview waiting on a build of a root, whichever of them started it (the build is shared).
    private static var indexWaiters: [String: [(LinkIndex) -> Void]] = [:]

    private func buildIndex(hidden: Bool) {
        let root = rootDir
        indexStale = false
        // The document on screen resolved against no index, or an older one: resolve again when it lands (renders only on a change).
        Self.indexWaiters[root, default: []].append { [weak self] idx in
            guard let self, root == self.rootDir, let url = self.fileURL, self.fileKind == .markdown, let text = self.docText,
                  text.contains("[[") else { return }
            self.resolveLinks(idx, text: text, path: url.path, targets: self.linkTargets(text))
        }
        guard Self.indexBuilding != root else { return }
        Self.indexBuilding = root
        DispatchQueue.global(qos: .userInitiated).async {
            let idx = LinkIndex.build(root: root, showHidden: hidden)
            DispatchQueue.main.async {
                if Self.indexBuilding == root { Self.indexBuilding = nil }
                Self.linkIndex = idx
                log.info("link index: \(idx.count) entries, complete=\(idx.complete)")
                let waiters = Self.indexWaiters.removeValue(forKey: root) ?? []
                waiters.forEach { $0(idx) }
            }
        }
    }

    /// Shows a file that is not Markdown, by what it is (FileView): an image or a PDF from the `file` host, text and code read
    /// here (the first 2 MB), anything else as an info card. Nothing here is ever rendered as HTML.
    private func show(_ url: URL, reason: String) {
        var st = stat()
        guard stat(url.path, &st) == 0 else {
            return reason == "change" ? status("cannot read \(url.lastPathComponent)") : showUnopenable(url, note: FileView.openRefusal(url.path))
        }
        let stamp = "\(st.st_size)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)-\(st.st_ino)"
        if reason == "change", stamp == shownStamp || awaitingDownload(url) { return }
        shownStamp = stamp
        pdfGen += 1
        shownView = nil
        loadingGen = pdfGen
        // Read off the main thread: text is read, an image in iCloud is downloaded before the page loads it, and PDFKit may
        // scan a large or damaged file to rebuild it. A newer show or open supersedes this one.
        let gen = pdfGen, kind = fileKind, root = rootDir, canOpen = LinkPolicy.fileRefusal(url, allowArchives: kind == .archive) == nil, epoch = writeEpoch
        let noQuickLook = quickLookFailed.map { $0.path == url.path && $0.stamp == Self.stamp(url) } ?? false
        let cloud = FileTypes.isDataless(url.path)
        // Only a download times out: PDFKit rebuilding a large local PDF may take longer, and is still shown when done.
        let id = loader.load(timesOut: cloud, { () -> (payload: [String: Any], pdf: Result<PDFDocument, PDFPane.LoadError>?,
                                                       rich: Result<NSAttributedString, RichTextPane.LoadError>?, stuck: Bool, edit: EditableText.Opened?) in
            var (p, edit) = FileView.payloadAndText(path: url.path, kind: kind, root: root, reason: reason, canOpen: canOpen, quickLook: !noQuickLook)
            // Native UTF-8 here, so the main thread's render takes its bytes with a copy (PageBody), not a transcoding.
            if let t = p["text"] as? String { p["text"] = TextDecoding.nativeUTF8(t) }
            // Text opens in a text editor even where its default app is refused (a script): the writer names the app.
            if Self.textViews.contains(p["view"] as? String ?? ""), LinkPolicy.editorRefusal(url) == nil { p["canOpen"] = true }
            if p["view"] as? String == "info", url.pathExtension.lowercased() == "dmg" { p["details"] = DiskImage.details(url.path) }
            var pdf: Result<PDFDocument, PDFPane.LoadError>?
            var rich: Result<NSAttributedString, RichTextPane.LoadError>?
            switch p["view"] as? String {
            case "pdf": pdf = PDFPane.open(url)
            case "rtf": rich = RichTextPane.open(url)
            // Decoded by the pane once the page is up; its size, for the caption, is in the file's properties.
            case "bitmap":
                if let s = ImagePane.pixelSize(url) {
                    p["width"] = Int(s.width)
                    p["height"] = Int(s.height)
                } else {
                    p["view"] = "info"
                    p["note"] = "This image can’t be shown here."
                }
            case "image" where cloud: _ = try? SchemeHandler.readImage(url)
            case "html" where cloud: _ = FileTypes.materializing { try? Data(contentsOf: url) }
            // One byte downloads the whole file; AVFoundation, reading it later on its own threads, could not.
            case "video" where cloud, "audio" where cloud, "quicklook" where cloud: _ = FileTypes.materializing { try? FileHandle(forReadingFrom: url).read(upToCount: 1) }
            default: break
            }
            // Only what FileView downloads counts: an evicted archive is its info card without a download.
            let fetched = ["pdf", "image", "bitmap", "html", "video", "audio", "rtf", "quicklook"].contains(p["view"] as? String)
                || ([.code, .json, .csv, .text].contains(kind) && (p["size"] as? Int64 ?? .max) <= FolderListing.maxDocumentBytes)
            if !Self.textViews.contains(p["view"] as? String ?? "") { edit = nil }
            return (p, pdf, rich, cloud && fetched && FileTypes.isDataless(url.path), edit)
        }) { [weak self] outcome in
            guard let self else { return }
            if self.loadingGen == gen { self.loadingGen = nil }
            guard self.host.controller === self, self.fileURL == url, self.fileKind == kind else { return }
            guard case .done(let r) = outcome else {
                log.error("show timed out \(url.path, privacy: .private)")
                return self.showUnavailable(url, reason: reason, cloud: cloud)
            }
            var p = r.payload
            var doc: PDFDocument?
            switch r.pdf {
            case .success(let d)?: doc = d
            case .failure(let e)?:
                p["view"] = "info"
                p["note"] = e == .locked ? "This PDF is password-protected." : "This PDF can’t be shown here."
            case nil: break
            }
            var text: NSAttributedString?
            switch r.rich {
            case .success(let t)?: text = t
            case .failure(let e)?:
                p["view"] = "info"
                p["note"] = e == .tooLarge ? "This document is too large to show here." : "This document can’t be shown here."
            case nil: break
            }
            if r.stuck { return self.showUnavailable(url, reason: reason, cloud: true) }
            guard self.takeText(url, &p, r.edit, epoch: epoch) else { return }
            // The panel closed while a PDF or media opened: it is shown again when the panel reappears (viewWillAppear).
            if p["view"] as? String == "quicklook" { self.quickLookShown = true }
            if doc != nil || text != nil || ["video", "audio", "html", "quicklook", "bitmap"].contains(p["view"] as? String), gen != self.pdfGen { return }
            self.shownCanOpen = p["canOpen"] as? Bool == true
            self.shownText = Self.textViews.contains(p["view"] as? String ?? "")
            self.shownBody = self.shownText ? (p["text"] as? String).map { ($0, p["truncated"] as? Bool == true) } : nil
            self.finishShow(url, p, pdf: doc, rich: text, reason: reason)
            if p["view"] as? String == "info", !cloud, self.thumbPending != url.path { self.addThumbnail(url, icon: kind == .app) }
        }
        if cloud, let s = Self.stamp(url) { downloading = (url, id, s) }
        if reason != "change" { showLoading(url, load: id, cloud: cloud) }
    }

    /// Takes a read of a file shown as text. For the editable text on screen, a read that may predate a write still in flight is
    /// dropped (that write reads again once it lands), and so is one that finds the bytes this preview last saved; anything else
    /// is a change on disk, which ends an edit as it does for Markdown. False: nothing is rendered.
    private func takeText(_ url: URL, _ p: inout [String: Any], _ opened: EditableText.Opened?, epoch: Int) -> Bool {
        let same = textPayload?["path"] as? String == url.path
        if same, writing || torn || epoch != writeEpoch {
            shownView = textPayload?["view"] as? String
            return false
        }
        if same, let o = opened, let src = textSource, let disk = diskText, src.bytes(disk) == o.bytes {
            shownView = textPayload?["view"] as? String
            return false
        }
        if same {
            retired = []
            if edit != nil {
                log.info("file changed on disk during edit; stopping edit")
                stopEdit(notifyWriter: true)
                status("changed on disk: edit stopped")
            } else if hasUnsavedText {
                status("unsaved text replaced by the version on disk")
            }
        }
        if encodeRefused || textStranded { encodeRefused = false; textStranded = false; stickyStatus("") }
        textSource = opened?.source
        docText = opened?.text
        diskText = opened?.text
        lineEnding = "\n"
        syncedText = opened?.text
        if opened != nil { p["ver"] = nextVersion() }
        textPayload = opened == nil ? nil : p
        return true
    }

    /// The editable text file's view again, from docText: after an edit, highlighted and measured anew.
    private func renderText(_ reason: String) {
        guard var p = textPayload, let url = fileURL, p["path"] as? String == url.path, let text = docText else { return }
        p["text"] = text
        p["reason"] = reason
        if let n = textSource?.bytes(text)?.count { p["size"] = n }
        p["ver"] = nextVersion()
        textPayload = p
        render(p)
    }

    private func finishShow(_ url: URL, _ payload: [String: Any], pdf: PDFDocument?, rich: NSAttributedString? = nil, reason: String) {
        unavailablePath = nil
        var p = payload
        if let o = opener, o.path == url.path { p["app"] = o.app; p["editor"] = o.editor }
        let canOpen = p["canOpen"] as? Bool == true
        var view = p["view"] as? String ?? ""
        var noPane = false
        // Its type is checked again here: the file may have been replaced since it was read. QLPreviewView would hand a type
        // spacebar claims back to spacebar.
        if view == "quicklook", FileTypes.appleQuickLookType(url.path) == nil {
            view = "info"; p["view"] = view; noPane = true
        }
        if view == "quicklook", qlPane == nil {
            qlPane = QLFallbackPane()
            if qlPane == nil { view = "info"; p["view"] = view; noPane = true }
        }
        quickLookShown = view == "quicklook"
        shownView = view
        closePDF(keeping: view)
        if let pdf {
            let pane = pdfPane ?? PDFPane()
            pane.onLink = { [weak self] in self?.pdfLink($0) }
            pane.show(pdf, path: url.path, over: host.web)
            pdfPane = pane
        }
        if let rich {
            let pane = richPane ?? RichTextPane()
            pane.onLink = { [weak self] in self?.pdfLink($0) }
            pane.show(rich, path: url.path)
            richPane = pane
        }
        if view == "bitmap" {
            let pane = imagePane ?? ImagePane()
            pane.onZoom = { [weak self] path, zoom in self?.js("sb.imageZoom", ["path": path, "zoom": zoom]) }
            pane.onFailed = { [weak self] in self?.imageFailed($0, p) }
            pane.load(url)
            imagePane = pane
        }
        if view == "video" || view == "audio" {
            let pane = mediaPane ?? MediaPane()
            pane.onFailed = { [weak self] in self?.mediaFailed($0, p) }
            pane.show(url, audio: view == "audio", over: host.web)
            mediaPane = pane
        }
        if view == "html" {
            let scripts = HTMLPane.runsScripts(url, setting: htmlScripts(for: url))
            if htmlPane?.scripts != scripts { htmlPane?.close(); htmlPane = HTMLPane(scripts: scripts) }
            htmlPane?.onLink = { [weak self] in self?.htmlLink($0) }
            htmlPane?.show(url, over: host.web)
        }
        if view == "quicklook", let pane = qlPane {
            pane.onFailed = { [weak self] in self?.quickLookFailed($0) }
            pane.show(url)
        }
        log.info("show \(view, privacy: .public) (\(self.fileKind.rawValue, privacy: .public))")
        render(p)
        if noPane { addThumbnail(url) }
        if view == "archive" { listArchive(url) }
        // The button names the app the writer would open it with; an app, a script or an executable gets Reveal in Finder only.
        if canOpen, reason == "open" {
            let path = url.path, gen = renderGen
            let named = { (name: String?, editor: Bool) in
                DispatchQueue.main.async {
                    guard self.fileURL?.path == path else { return }
                    guard let name else {
                        // Nothing may open it after all (no text editor at hand): Reveal in Finder instead, unless something
                        // newer (a change on disk, another view) has been rendered since, which this payload would undo.
                        guard Self.textViews.contains(view), self.shownCanOpen, self.renderGen == gen else { return }
                        self.shownCanOpen = false
                        var q = p
                        q["canOpen"] = false
                        return self.render(q)
                    }
                    self.opener = (path, name, editor)
                    self.js("sb.setOpener", ["path": path, "app": name, "editor": editor])
                }
            }
            if Self.textViews.contains(view) {
                helper { $0.textOpener(url, appBundleID: SettingsStore.shared.settings.editorBundleID, reply: named) }
            } else {
                helper { $0.defaultApp(url) { name in if let name { named(name, false) } } }
            }
        }
    }

    /// Asks the writer for the archive's contents (the extension cannot run bsdtar) and sends them to the page; an archive it
    /// cannot list turns into its info card.
    private func listArchive(_ url: URL) {
        let path = url.path, gen = renderGen
        let done: (Data?) -> Void = { [weak self] data in
            DispatchQueue.main.async {
                guard let self, self.renderGen == gen, self.fileURL?.path == path else { return }
                if let data, let list = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let entries = list["entries"] as? [[String: Any]] {
                    self.js("sb.setArchive", ["path": path, "entries": entries, "truncated": list["truncated"] as? Bool ?? false])
                } else {
                    self.js("sb.setArchive", ["path": path, "error": "This archive’s contents can’t be listed."])
                    self.addThumbnail(url)
                }
            }
        }
        helper(onError: { done(nil) }) { $0.listArchive(path, reply: done) }
    }

    fileprivate func stopNativeViews() { closePDF() }

    fileprivate func handOver() { stopFilter(notifyWriter: true) }

    /// Takes down the native views of a PDF, an HTML file, media and Apple's previews, all but the one for `keep`, the view about to be shown:
    /// that one is reused, so a PDF keeps its page and media its time when the same file is shown again.
    private func closePDF(keeping keep: String = "") {
        if keep != "pdf" {
            pdfGen += 1
            pdfPane?.close()
            pdfPane = nil
        }
        if keep != "html" {
            htmlPane?.close()
            htmlPane = nil
        }
        if keep != "video" && keep != "audio" {
            mediaPane?.close()
            mediaPane = nil
        }
        if keep != "quicklook" {
            qlPane?.close()
            qlPane = nil
        }
        if keep != "rtf" {
            richPane?.close()
            richPane = nil
        }
        if keep != "bitmap" {
            imagePane?.close()
            imagePane = nil
        }
    }

    /// A file Quick Look showed only as its generic icon (no generator reachable, or one that could not read it): its text when
    /// it is text, else its info card.
    private func quickLookFailed(_ path: String) {
        guard let url = fileURL, url.path == path, qlPane?.path == path else { return }
        closePDF()
        quickLookShown = false
        quickLookFailed = (path, Self.stamp(url))
        shownStamp = nil
        show(url, reason: "open")
    }

    /// An image ImageIO read the size of but cannot decode: its info card, with Apple's thumbnail when there is one.
    private func imageFailed(_ path: String, _ p: [String: Any]) {
        guard let url = fileURL, url.path == path, imagePane?.path == path else { return }
        closePDF()
        shownView = "info"
        var card = p
        card["view"] = "info"
        card["note"] = "This image can’t be shown here."
        if let o = opener, o.path == path { card["app"] = o.app }
        render(card)
        addThumbnail(url)
    }

    /// A file AVFoundation cannot play (not media after all, or a codec it lacks): its info card, as for a PDF PDFKit cannot open.
    private func mediaFailed(_ path: String, _ p: [String: Any]) {
        guard let url = fileURL, url.path == path, mediaPane?.path == path else { return }
        closePDF()
        shownView = "info"
        var card = p
        card["view"] = "info"
        card["note"] = "This file can’t be played here."
        if let o = opener, o.path == path { card["app"] = o.app }
        render(card)
        addThumbnail(url)
    }

    /// Apple's own large thumbnail (a Keynote slide, a document's first page, an app's icon when `icon`) for the info card on
    /// screen, made off the main thread; the card keeps its icon when there is none within 3 seconds.
    private func addThumbnail(_ url: URL, icon: Bool = false) {
        thumbPending = url.path
        DispatchQueue.global(qos: .userInitiated).async {
            let thumb = Thumbnail.dataURL(url, icon: icon)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if self.thumbPending == url.path { self.thumbPending = nil }
                // A change on disk re-renders the card (a new renderGen) while this was made: it still belongs on it.
                guard let thumb, self.host.controller === self, self.fileURL == url else { return }
                self.js("sb.setThumb", ["path": url.path, "thumb": thumb])
            }
        }
    }

    /// A link in the HTML file on screen: a file beside it opens in the panel like a sidebar click, a web link in the browser.
    private func htmlLink(_ url: URL) {
        if url.isFileURL {
            // Held to what the sidebar could list: a plain path inside the root, a regular file, hidden only when hidden files show.
            let target = url.standardizedFileURL
            var st = stat()
            guard FolderListing.isPlainPath(target.path, under: rootDir), FolderListing.isInside(target.path, root: rootDir),
                  stat(target.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                  SettingsStore.shared.settings.showHiddenFiles || !Self.hiddenStep(target.path, under: rootDir) else {
                return refuse("html link", "not a file the sidebar would list")
            }
            return open(target, anchor: nil)
        }
        if let why = PDFPane.linkRefusal(url) { return refuse("html link", why) }
        openExternally(url)
    }

    /// Whether any step of `path` below `root` is hidden (a dot name or the hidden flag).
    static func hiddenStep(_ path: String, under root: String) -> Bool {
        var at = root
        for part in path.dropFirst(root.count).split(separator: "/") {
            at += "/" + part
            var st = stat()
            if lstat(at, &st) != 0 || FolderListing.isHidden(String(part), st) { return true }
        }
        return false
    }

    /// A link inside the PDF on screen: web links only, through the link policy and the writer, like the page's own links.
    private func pdfLink(_ url: URL) {
        if let why = PDFPane.linkRefusal(url) { return refuse("pdf link", why) }
        openExternally(url)
    }

    /// A path the page names, accepted only when it is plain, inside the root (symlinks resolved), and one the sidebar listed.
    private func listedFile(_ m: PageMessage) -> String? {
        guard let p = m.string("path", max: 4096), FolderListing.isPlainPath(p, under: rootDir),
              listings.values.contains(where: { l in l.entries.contains { $0.path == p && !$0.isDirectory } }),
              FolderListing.isInside(p, root: rootDir) else { return nil }
        return p
    }

    /// A path the overview or a wikilink offered: plain, inside the root (symlinks resolved), a regular file.
    private func offeredFile(_ m: PageMessage) -> String? {
        guard let p = m.string("path", max: 4096), offered.contains(p), FolderListing.isPlainPath(p, under: rootDir),
              FolderListing.isInside(p, root: rootDir) else { return nil }
        var st = stat()
        guard stat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return p
    }

    /// A path the Contents search found: plain, inside the root (symlinks resolved), a regular file.
    private func searchedFile(_ m: PageMessage) -> String? {
        guard let p = m.string("path", max: 4096), searchHits.paths.contains(p), FolderListing.isPlainPath(p, under: rootDir),
              FolderListing.isInside(p, root: rootDir) else { return nil }
        var st = stat()
        guard stat(p, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return p
    }

    /// Searches the text of the files the sidebar lists for `query` off the main thread (ContentSearch), streaming what it finds
    /// to the page as `sb.searchResults`. A new search, or `stopSearch`, cancels the one before.
    private func startSearch(_ query: String, seq: Int) {
        stopSearch()
        guard !rootDir.isEmpty else { return js("sb.searchResults", ContentSearch.payload(.init(done: true), seq: seq)) }
        let cancel = ContentSearch.Cancel()
        search = (seq, cancel)
        let root = rootDir, s = SettingsStore.shared.settings, only = selectionNames
        ContentSearch.queue.async {
            ContentSearch.run(query: query, root: root, sort: s.folderSort, readmeFirst: s.folderReadmeFirst, showHidden: s.showHiddenFiles,
                              only: only, cancel: cancel) { p in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.search?.cancel === cancel, !cancel.isCancelled, root == self.rootDir else { return }
                    // The page replaces its list with this search's at its first report.
                    if self.searchHits.seq != seq { self.searchHits = (seq, []) }
                    self.searchHits.paths.formUnion(p.hits.map(\.path))
                    if p.done { self.search = nil }
                    self.js("sb.searchResults", ContentSearch.payload(p, seq: seq))
                }
            }
        }
    }

    fileprivate func stopSearch() {
        search?.cancel.cancel()
        search = nil
    }

    func handle(_ type: String, _ body: [String: Any]) {
        let m = PageMessage(body: body)
        switch type {
        case "painted":
            // Show the panel as soon as text/math/code are in; mermaid diagrams fill in afterwards.
            if readyPending {
                log.info("painted[\(m.string("reason", max: 32) ?? "", privacy: .public)] \(ms(self.prepareStart), privacy: .public)ms after prepare wall=\(Date().timeIntervalSince1970, privacy: .public)")
            }
            finishPrepare(nil)
            checkForUpdate()
            checkSpaceHelper()
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
            // Only a file the sidebar listed, or the overview or a wikilink offered, checked again now: a listed file may since
            // have been replaced by a link out of the root.
            guard let p = listedFile(m) ?? offeredFile(m) ?? searchedFile(m) else { return refuse("open", "not in the folder list") }
            if p == fileURL?.path, let a = m.string("anchor", max: 256) { return js("sb.scrollToHeading", ["heading": a]) }
            open(URL(fileURLWithPath: p), anchor: m.string("anchor", max: 256))
        case "search":
            // The sidebar filter in Contents mode: every keystroke starts a search, cancelling the last.
            guard let seq = m.int("seq") else { return refuse("search", "no sequence number") }
            guard let q = m.string("q", max: ContentSearch.maxQueryBytes) else {
                stopSearch()
                return js("sb.searchResults", ContentSearch.payload(.init(done: true), seq: seq))
            }
            startSearch(q, seq: seq)
        case "searchStop":
            stopSearch()
        case "overview":
            // The sidebar's folder name: the overview of the root.
            guard !torn else { return }
            overviewRequested = true
            scanFolder(openBest: false)
        case "list":
            // A folder expanded in the sidebar: the root or one a listing named, still inside the root once symlinks are resolved.
            guard let p = m.string("path", max: 4096), listings[p] == nil || dirWatches[p] == nil, knownDirs.contains(p), FolderListing.isPlainPath(p, under: rootDir),
                  FolderListing.isInside(p, root: rootDir, allowRoot: true) else { return refuse("list", "not a folder of the tree") }
            watch(p)
            refreshListing(p)
        case "unlist":
            // A folder collapsed in the sidebar: no longer watched. The root always is.
            guard let p = m.string("path", max: 4096), p != rootDir else { return }
            dirWatches.removeValue(forKey: p)
        case "openFile":
            // The viewer's "Open with" button, for the file on screen only; the writer applies LinkPolicy again.
            guard let url = fileURL, m.string("path", max: 4096) == url.path, fileKind != .markdown, shownCanOpen,
                  LinkPolicy.fileRefusal(url, allowArchives: fileKind == .archive) == nil || (shownText && LinkPolicy.editorRefusal(url) == nil) else {
                return refuse("openFile", "not the file on screen or not allowed")
            }
            let done = { (ok: Bool) in if !ok { DispatchQueue.main.async { self.status("not opened: \(url.lastPathComponent)") } } }
            if shownText {
                helper { $0.openText(url, appBundleID: SettingsStore.shared.settings.editorBundleID, reply: done) }
            } else {
                helper { $0.openFileOnScreen(url, reply: done) }
            }
        case "reveal":
            // A broken link does not resolve: its card reveals the link itself, in a folder inside the root.
            guard let url = fileURL, fileKind != .markdown || unavailablePath == url.path, m.string("path", max: 4096) == url.path,
                  FolderListing.isInside(url.path, root: rootDir) || unavailablePath == url.path
                    && FolderListing.isInside((url.path as NSString).deletingLastPathComponent, root: rootDir, allowRoot: true) else {
                return refuse("reveal", "not the file on screen")
            }
            helper { $0.reveal(url) { ok in if !ok { DispatchQueue.main.async { self.status("could not show \(url.lastPathComponent) in Finder") } } } }
        case "setting":
            // The Aa popover and the sidebar button: cosmetic keys only (Settings.panelKeys), checked here and again by the writer.
            guard let key = m.string("key", max: 32), let raw = body["value"], let patch = Settings.panelPatch(key, raw) else {
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
            // A refused toggle is already flipped on the page: the document goes back to it as it is.
            guard !updateBusy else { status("Updating…"); return repushDoc("toggleRefused") }
            guard isCurrent(m), let line = m.int("line"), let checked = m.bool("checked"), let text = m.string("text", max: 1 << 16) else {
                return refuse("toggle", "bad request or not the previewed file")
            }
            guard let mapped = mapLine(line, from: m.int("ver")) else { status("not toggled: document changed"); return repushDoc("toggleRefused") }
            toggleTask(line: mapped, text: text, checked: checked)
        case "editBlock":
            guard SettingsStore.shared.settings.inlineEditing, isCurrent(m) else {
                refuse("editBlock", "not the previewed file")
                if let seq = m.int("seq") { js("sb.editEnd", ["seq": seq]) }
                return
            }
            guard !updateBusy else {
                status("Updating…")
                if let seq = m.int("seq") { js("sb.editEnd", ["seq": seq]) }
                return
            }
            beginEdit(m)
        case "editText":
            // A click on the text of a code, text, JSON or CSV view: the whole file, edited in the same key panel.
            guard SettingsStore.shared.settings.inlineEditing, let url = fileURL, fileKind != .markdown, m.string("path", max: 4096) == url.path,
                  textSource != nil, !torn, !tornHalted else {
                refuse("editText", "not the editable file on screen")
                if let seq = m.int("seq") { js("sb.editEnd", ["seq": seq]) }
                return
            }
            guard !updateBusy else {
                status("Updating…")
                if let seq = m.int("seq") { js("sb.editEnd", ["seq": seq]) }
                return
            }
            beginTextEdit(m)
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
            if textSource != nil { renderText("editEnd") } else if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "editEnd") }
        case "filterBegin":
            // A click in the sidebar's filter field, or (`list`) on a row of the sidebar; an edit is ended by the page (editStop)
            // before it asks.
            guard let seq = m.int("seq"), fileURL != nil || !rootDir.isEmpty, edit == nil else {
                refuse("filterBegin", "no sidebar or an edit is open")
                if let seq = m.int("seq") { js("sb.filterEnd", ["seq": seq]) }
                return
            }
            guard !updateBusy else {
                status("Updating…")
                return js("sb.filterEnd", ["seq": seq])
            }
            let list = m.bool("list") == true, find = !list && m.bool("find") == true
            beginFilter(seq, text: list ? "" : FilterKeys.clean(m.string("text", max: 4 * FilterKeys.maxLength) ?? ""), list: list, find: find, m)
        case "filterStop":
            guard let f = filter, m.int("seq") == f.seq else { return }
            stopFilter(notifyWriter: true)
        case "editPainted":
            if let kt = m.double("keyTime") { log.info("keystroke->painted \(uptimeMs(since: kt), privacy: .public)ms") }
        case "edit":
            // The page names the document it shows: while a new file loads it may still show the previous one.
            if let fileURL, fileKind == .markdown, m.string("path", max: 4096) == fileURL.path { openExternally(fileURL) }
        case "loadRemoteImages":
            // A blocked image's placeholder: this document's remote images, for this preview only. The setting is not touched.
            guard let p = m.string("path", max: 4096), host.remoteImages.allowOnce(p, current: fileURL?.path) else {
                return refuse("loadRemoteImages", "remote images are on or not the previewed file")
            }
            log.info("remote images loaded once for the previewed file")
            if let e = edit { stopEdit(notifyWriter: true, keepRetired: true); retired.append(e) }
            if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "remoteImages") }
        case "imageStatus":
            // The document's images that failed: why, for their placeholders.
            guard let url = fileURL, fileKind == .markdown, m.string("doc", max: 4096) == url.path,
                  let r = images.answer(body["paths"], doc: url.path) else { return refuse("imageStatus", "not the document on screen") }
            js("sb.imageStatus", ["doc": url.path, "images": r])
        case "revealImageFolder":
            // A placeholder's Reveal button: only a folder an answer for this document found.
            guard let url = fileURL, fileKind == .markdown, m.string("doc", max: 4096) == url.path,
                  let dir = images.revealable(m.string("path", max: 4096), doc: url.path) else {
                return refuse("revealImageFolder", "not a folder of this document's images")
            }
            helper { $0.reveal(dir) { ok in if !ok { DispatchQueue.main.async { self.status("could not show \(dir.lastPathComponent) in Finder") } } } }
        case "pdfRect":
            // Where the page reserved the PDF's place, in CSS pixels of the viewport; `hide` while the page has something above it.
            if fileKind == .pdf { pdfPane?.place(message: body, in: host.web) }
            if fileKind == .html { htmlPane?.place(message: body, in: host.web) }
            if [.video, .audio].contains(fileKind) { mediaPane?.place(message: body, in: host.web) }
            qlPane?.place(message: body, in: host.web)
            if fileKind == .rtf { richPane?.place(message: body, in: host.web) }
            if fileKind == .image { imagePane?.place(message: body, in: host.web) }
        case "copy":
            // The Copy button (the file on screen, as shown) or ⌘C (the page's selection, when there is one). Text from the page
            // is taken only just after this controller handed it a ⌘C.
            let failed = { (why: String) in self.refuse("copy", why); self.js("sb.copied", ["ok": false]) }
            guard let url = fileURL, m.string("path", max: 4096) == url.path else { return failed("not the file on screen") }
            let asked = copyAsked.map { -$0.timeIntervalSinceNow < 1 } ?? false
            copyAsked = nil
            let selection = m.string("text")
            guard body["text"] == nil || (selection != nil && asked) else { return failed("selection not asked for, or too large") }
            let whole: (text: String, truncated: Bool)? = fileKind == .markdown || textSource != nil ? docText.map { ($0, false) } : shownBody
            guard let text = selection ?? whole?.text, !text.isEmpty else { return failed("nothing to copy") }
            let cut = selection == nil && whole?.truncated == true
            if selection == nil, asked, m.bool("withFile") == true, copyFileAndText(url, text) {
                return js("sb.copied", ["ok": true, "truncated": cut])
            }
            helper(onError: { failed("writer unavailable") }) {
                $0.copyText(text) { ok in DispatchQueue.main.async { self.js("sb.copied", ["ok": ok, "truncated": cut]) } }
            }
        case "copyInstall":
            helper { $0.copyInstallCommand { ok in DispatchQueue.main.async { self.js("sb.installCopied", ["ok": ok]) } } }
        case "installUpdate":
            guard installable, offeredVersion != nil else {
                // The page went busy on the click; it waits for an answer.
                js("sb.update", ["state": "failed", "version": offeredVersion ?? "", "reason": "Not started: no update is offered.", "retry": false])
                return refuse("installUpdate", "no update offered")
            }
            // The installer quits Quick Look: the edit's last keys and saves land first, and the filter lets go of the keyboard.
            stopFilter(notifyWriter: true)
            if holdUntilSaved(.update) { return }
            startUpdate()
        case "updateCheck":
            recheckUpdate()
        case "releaseNotes":
            guard let v = offeredVersion, let url = URL(string: "https://github.com/patebry/spacebar/releases/tag/v\(v)") else {
                return refuse("releaseNotes", "no update shown")
            }
            helper { $0.open(url) { _ in } }
        case "log":
            log.info("js: \(String((body["msg"] as? String ?? "").prefix(2000)), privacy: .private)")
        default: break
        }
    }

    /// Edits name the file the page rendered; one for any other file (a stale page, a folder switch) is refused.
    private func isCurrent(_ m: PageMessage) -> Bool {
        guard let fileURL, fileKind == .markdown, let p = m.string("path", max: 4096) else { return false }
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
    private var updateAsked = false
    /// The newer release the popover is showing, if any, and whether its Update button may install it.
    private var offeredVersion: String?
    private var installable = false
    /// The version this preview started installing.
    private var updating: String?
    /// No edit starts while an update waits to start or runs: the installer quits the preview.
    private var updateBusy: Bool {
        if updating != nil { return true }
        if case .update = pending { return true }
        return false
    }

    /// Once per preview, after it is on screen: the writer answers from its daily cache, so this rarely touches the network.
    private func checkForUpdate() {
        guard !updateAsked, SettingsStore.shared.settings.checkUpdates,
              let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String else { return }
        updateAsked = true
        helper {
            $0.updateOffer { data in
                guard let data, let offer = Updates.Offer(json: data) else { return }
                DispatchQueue.main.async {
                    switch offer {
                    case .available(let v) where Updates.isNewer(v, than: current):
                        self.offer(v, installable: true, ["state": "available"])
                    case .elsewhere(let v, let place) where Updates.isNewer(v, than: current):
                        self.offer(v, installable: false, ["state": "elsewhere", "place": place])
                    case .failed(let v, let reason) where Updates.isNewer(v, than: current):
                        let a = Updates.advice(for: reason)
                        self.offer(v, installable: false, ["state": "failed", "reason": a.text, "copy": a.copy])
                    default:
                        // None newer, or an update from this Mac still running: nothing to offer.
                        break
                    }
                }
            }
        }
    }

    /// Once per extension process, a quiet line when the Space helper is on in the settings but Space fell back to Quick Look.
    /// Asked of the writer at most every 30 s, and only while the setting is on.
    private static var helperHinted = false
    private static var helperAsked = Date.distantPast
    private func checkSpaceHelper() {
        guard WebHost.pageHost == "quicklook", !Self.helperHinted, SettingsStore.shared.settings.spaceHelper,
              Date().timeIntervalSince(Self.helperAsked) > 30 else { return }
        Self.helperAsked = Date()
        helper {
            $0.spaceHelperPaused { paused in
                DispatchQueue.main.async {
                    guard paused, !Self.helperHinted, self.host.controller === self else { return }
                    // Spent only once the page has put it up: a status already showing keeps it for a later preview.
                    self.host.web.evaluateJavaScript("sb.helperHint()") { shown, _ in
                        if shown as? Bool == true { Self.helperHinted = true }
                    }
                }
            }
        }
    }

    private func offer(_ version: String, installable: Bool, _ state: [String: Any]) {
        offeredVersion = version
        self.installable = installable
        js("sb.update", state.merging(["version": version]) { a, _ in a })
    }

    /// Asks the writer to start the installer for the offered version, never one the page names; once per preview.
    /// The page's "Updating…" has waited long: the writer says whether the installer still runs, failed, or finished.
    private func recheckUpdate() {
        // This controller started no update (the page's state is from another preview, or the click is still held for saves).
        guard let v = updating else {
            if case .update = pending { return }
            return js("sb.updateReset", [:])
        }
        helper(onError: {
            let a = Updates.advice(for: "the helper stopped before it could say how the update went")
            self.js("sb.update", ["state": "failed", "version": v, "reason": a.text, "copy": a.copy])
            self.updating = nil
        }) {
            $0.updateOffer { data in
                DispatchQueue.main.async {
                    // Nil when checks were turned off (or this is a development build): the page must not stay "Updating…".
                    guard let data, let offer = Updates.Offer(json: data) else {
                        self.updating = nil
                        return self.js("sb.update", ["state": "failed", "version": v, "reason": "Update checks are off.", "retry": false])
                    }
                    switch offer {
                    case .inProgress(v): return self.js("sb.update", ["state": "inProgress", "version": v])
                    case .failed(v, let reason):
                        let a = Updates.advice(for: reason)
                        self.js("sb.update", ["state": "failed", "version": v, "reason": a.text, "copy": a.copy])
                    case .none: self.js("sb.update", ["state": "done", "version": v])
                    default:
                        let a = Updates.advice(for: "The installer did not finish. \(Updates.logHint)")
                        self.js("sb.update", ["state": "failed", "version": v, "reason": a.text, "copy": a.copy])
                    }
                    self.updating = nil
                }
            }
        }
    }

    private func startUpdate() {
        guard installable, let v = offeredVersion else { return }
        installable = false
        let failed = { (reason: String) in
            log.error("update: \(reason, privacy: .public)")
            let a = Updates.advice(for: reason)
            self.js("sb.update", ["state": "failed", "version": v, "reason": a.text, "copy": a.copy])
        }
        helper(onError: { failed("the helper stopped before the update started") }) {
            $0.installUpdate(v) { err in
                DispatchQueue.main.async {
                    if let err { return failed(err) }
                    self.updating = v
                    self.status("Updating to \(v)…")
                    self.js("sb.update", ["state": "started", "version": v])
                }
            }
        }
    }

    fileprivate func helper(onError: (() -> Void)? = nil, _ body: (SpacebarWriterProtocol) -> Void) {
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
        stopFilter(notifyWriter: false)
        let lostWrite = writing
        if writing { writing = false; queuedSave = nil; status("save failed: edit again to retry") }
        if torn, let url = fileURL { retryTorn(url) }
        // No more keys will arrive for ended sessions.
        retired = []
        if lostWrite { cancelPending("save failed; edit again to retry") } else { runPending() }
    }

    private func retryTorn(_ url: URL) {
        stickyStatus(tornStatus.isEmpty ? "NOT SAVED: file partly written, no recovery copy; copy your text before closing"
                                        : "NOT SAVED: file partly written; retrying. Text kept in \(tornStatus) (temporary folders are cleared)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.torn, !self.tornHalted, !self.writing, self.fileURL == url, let t = self.docText else { return }
            self.save(t)
        }
    }

    /// Renders the document as native holds it, over a page that changed ahead of a refused request.
    private func repushDoc(_ reason: String) {
        guard fileKind == .markdown, edit == nil, let url = fileURL, let text = docText else { return }
        push(text: text, path: url.path, reason: reason)
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
        guard let base = torn ? tornBase : diskText.flatMap(bytes) else {
            if torn { retryTorn(url) }
            return
        }
        // A character the file's encoding has no form for: nothing is written, and the file is never converted to UTF-8.
        guard let data = bytes(onDisk(text)) else {
            let c = textSource?.unencodable(text).map { "“\($0)”" } ?? "a character"
            encodeRefused = true
            return stickyStatus("NOT SAVED: \(c) can’t be written in \(textSource?.name ?? "this file’s encoding"); remove it to save")
        }
        if encodeRefused { encodeRefused = false; stickyStatus("") }
        writing = true
        writeEpoch += 1
        helper(onError: { [weak self] in self?.saved(url, text, keyTime: keyTime, error: "xpc") }) {
            $0.write(data, toPath: url.path, expecting: base) { err in
                DispatchQueue.main.async { self.saved(url, text, keyTime: keyTime, error: err) }
            }
        }
    }

    /// The bytes on disk for `text`: UTF-8 for Markdown, the file's own encoding and byte order mark for other text.
    private func bytes(_ text: String) -> Data? { textSource.map { $0.bytes(text) } ?? Data(text.utf8) }

    private func saved(_ url: URL, _ text: String, keyTime: Double?, error: String?) {
        guard writing else { return }
        writing = false
        guard url == fileURL else { queuedSave = nil; return runPending() }
        if let error, error == "conflict", torn, tornStatus.isEmpty {
            // Someone else wrote the file after it was torn and no recovery copy exists: stop writing but keep the text on screen.
            log.error("save failed: conflict after a partial write, no recovery copy")
            tornHalted = true
            queuedSave = nil
            stopEdit(notifyWriter: true)
            stickyStatus("file changed on disk; your unsaved text is only in this preview: copy it now")
            cancelPending("save failed")
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
            cancelPending("changed on disk, not saved")
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
            cancelPending("changed on disk, not saved")
            return
        }
        if let error, error.contains("not a text typed"), strandText() {
            queuedSave = nil
            stopEdit(notifyWriter: true)
            runPending()
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
            cancelPending("save failed; edit again to retry")
            return
        }
        diskText = onDisk(text)
        syncedText = text
        if torn { torn = false; tornBase = nil; stickyStatus(""); status(tornStatus.isEmpty ? "saved" : "saved; \(tornStatus) can be deleted"); tornStatus = "" }
        if let q = queuedSave {
            queuedSave = nil
            if q.url == url { send(q.url, q.text, q.keyTime) }
            return
        }
        if textSource == nil { push(text: text, path: url.path, reason: edit != nil ? "edit" : "save", keyTime: keyTime) }
        // Catch an external change that landed while writes were in flight (watcher reloads are skipped during a write).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.reload(reason: "change") }
        runPending()
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
        // The writer ends a filter session as an edit begins; a begin that fails here must end it there too.
        let previousFilter = filter
        stopFilter(notifyWriter: false)
        // The writer keeps its panel key when a new session replaces the old one, so only a failed begin ends the old one there.
        let previous = edit
        stopEdit(notifyWriter: false, keepRetired: true)
        if let previous { retired.append(previous) }
        let fail = { (why: String) in
            log.error("editBlock: \(why, privacy: .public)")
            // Keys already typed into the previous block (and flushed as the writer ends it) still land.
            if let p = previous { self.helper { $0.endEdit(p.id) } }
            if let f = previousFilter, !self.heldLocally(f) { self.endKeys(f) }
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
        if textSource != nil { return textChanged(id, text: raw, selStart: selStart, selLen: selLen, keyTime: keyTime) }
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
        if textSource != nil { return textEditEnded(id, reason: reason) }
        if let i = retired.firstIndex(where: { $0.id == id }) {
            let r = retired.remove(at: i)
            dropIfEmpty(start: r.start, lines: r.lines)
            runPending()
            return
        }
        guard let e = edit, e.id == id else { return runPending() }
        log.info("edit \(id) ended: \(reason, privacy: .public)")
        stopEdit(notifyWriter: false)
        dropIfEmpty(start: e.start, lines: e.lines)
        if reason == "not-key" { status("inline editing unavailable") }
        // Re-sync the page with docText, the authority, in case the two drifted while it owned the view.
        if let url = fileURL, let text = docText { push(text: text, path: url.path, reason: "editEnd") }
        if FilterKeys.relists(afterEnding: reason, list: false) { wantListKeys() }
        if reason == "find" { js("sb.editFind", [:]) }
    }

    // MARK: editing a whole text file

    /// A click on the text of the editable file on screen: the writer's panel takes the keys with the whole text in plain mode.
    /// The page's copy must be docText; a click while the last edit's keys are still landing is refused (they would be lost).
    private func beginTextEdit(_ m: PageMessage) {
        guard let seq = m.int("seq") else { return }
        let previousFilter = filter
        stopFilter(notifyWriter: false)
        let previous = edit
        stopEdit(notifyWriter: false, keepRetired: true)
        if let previous { retired.append(previous) }
        let fail = { (why: String) in
            log.error("editText: \(why, privacy: .public)")
            if let p = previous { self.helper { $0.endEdit(p.id) } }
            if let f = previousFilter, !self.heldLocally(f) { self.endKeys(f) }
            self.js("sb.editEnd", ["seq": seq])
        }
        guard previous == nil, retired.isEmpty else { return fail("the last edit is still landing") }
        guard let url = fileURL, let text = docText, let caret = m.int("caret"), m.int("len") == (text as NSString).length, caret <= (text as NSString).length else {
            return fail("bad request, or the page is behind the text")
        }
        editCounter += 1
        let id = editCounter
        edit = (id, seq, 0, 0)
        log.info("editText \(id) caret \(caret)\(self.writing ? " during a write" : "", privacy: .public)")
        // Only the click's line matters for where the panel sits; a tall view would make a window taller than the screen.
        let clamp = { (k: String, hi: Double) in min(max(m.double(k) ?? 0, 0), hi) }
        let w = clamp("width", Double(host.web.bounds.width)), h = 40.0
        let y = min(clamp("clickY", 1e7), 20)
        helper(onError: { [weak self] in if self?.edit?.id == id { self?.stopEdit(notifyWriter: false) } }) {
            $0.beginTextEdit(id, path: url.path, text: text, caret: caret, clickX: clamp("clickX", w), clickY: y, width: w, height: h) { ok in
                DispatchQueue.main.async {
                    guard self.edit?.id == id else { return }
                    if !ok { self.stopEdit(notifyWriter: false); if !self.strandText() { self.status("inline editing unavailable") } }
                }
            }
        }
    }

    /// The writer's buffer is the whole file: the page is sent only what changed (UTF-16 offsets), and the file is saved.
    private func textChanged(_ id: Int, text: String, selStart: Int, selLen: Int, keyTime: Double) {
        guard let old = docText else { return }
        let seq: Int
        if let e = edit, e.id == id { seq = e.seq } else if let r = retired.first(where: { $0.id == id }) { seq = r.seq } else { return }
        let c = EditableText.change(from: old, to: text)
        js("sb.textUpdate", ["seq": seq, "from": c?.from ?? 0, "to": c?.to ?? 0, "insert": c?.insert ?? "", "selStart": selStart, "selLen": selLen,
                             "keyTime": keyTime])
        if c != nil { save(text, keyTime: keyTime) }
    }

    private func textEditEnded(_ id: Int, reason: String) {
        // An ended session's late keys reached the page with textUpdate, so its end needs no render.
        if let i = retired.firstIndex(where: { $0.id == id }) {
            retired.remove(at: i)
            return runPending()
        }
        guard let e = edit, e.id == id else { return runPending() }
        log.info("edit \(id) ended: \(reason, privacy: .public)")
        stopEdit(notifyWriter: false)
        if reason == "not-key" { status("inline editing unavailable") }
        renderText("editEnd")
        if FilterKeys.relists(afterEnding: reason, list: false) { wantListKeys() }
        if reason == "find" { js("sb.editFind", [:]) }
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

    // MARK: the sidebar filter

    /// On screen: the host showed this preview and has not taken it away.
    private var appeared = false

    /// Asks the page for a list session over the sidebar (it starts one only when the sidebar shows more than one row), so the
    /// arrow keys move through spacebar's list rather than Finder's selection.
    private func wantListKeys() {
        guard appeared, host.controller === self, !rootDir.isEmpty else { return }
        let root = rootDir
        host.whenReady { [weak self] in
            guard let self, self.appeared, self.host.controller === self, self.rootDir == root else { return }
            self.keySource.listSessionWanted(root: root)
        }
    }

    private func beginFilter(_ seq: Int, text: String, list: Bool, find: Bool, _ m: PageMessage) {
        // The writer ends a previous filter session itself, keeping its panel key for this one; a session held elsewhere, or
        // one the writer loses to a session held elsewhere, is ended here.
        if let f = filter {
            js("sb.filterEnd", ["seq": f.seq])
            if heldLocally(f) || (list && keySource.local) { endKeys(f) }
        }
        editCounter += 1
        let id = editCounter
        filter = KeySession(id: id, seq: seq, list: list, find: find)
        // The panel goes over the field (or the row): never wider than the page, nor taller than a line.
        let clamp = { (k: String, hi: Double) in min(max(m.double(k) ?? 0, 0), hi) }
        let w = clamp("width", Double(host.web.bounds.width)), h = clamp("height", 48)
        let failed = { [weak self] in if self?.filter?.id == id { self?.stopFilter(notifyWriter: false) } }
        if list {
            return keySource.beginList(id, clickX: clamp("clickX", w), clickY: clamp("clickY", h), rowWidth: w, rowHeight: h, failed: failed)
        }
        let replied = { (ok: Bool) in DispatchQueue.main.async { if !ok { failed() } } }
        helper(onError: failed) {
            if find {
                $0.beginFind(id, text: text, clickX: clamp("clickX", w), clickY: clamp("clickY", h), fieldWidth: w, fieldHeight: h, reply: replied)
            } else {
                $0.beginFilter(id, text: text, clickX: clamp("clickX", w), clickY: clamp("clickY", h), fieldWidth: w, fieldHeight: h, reply: replied)
            }
        }
    }

    fileprivate func filterChanged(_ id: Int, text: String) {
        guard let f = filter, f.id == id, !f.list else { return }
        js("sb.filterText", ["seq": f.seq, "text": FilterKeys.clean(text)])
    }

    func filterKey(_ id: Int, key: String, isRepeat: Bool) {
        guard let f = filter, f.id == id, f.keys.contains(key) else { return }
        if key == "copy" { armCopy() }
        js("sb.filterKey", ["seq": f.seq, "key": key, "repeat": isRepeat])
    }

    func filterEnded(_ id: Int, reason: String) {
        guard let f = filter, f.id == id else { return }
        log.info("filter \(id) ended: \(reason, privacy: .public)")
        stopFilter(notifyWriter: false, reason: reason)
        if FilterKeys.relists(afterEnding: reason, list: f.list) { wantListKeys() }
        else if f.list { listSessionEnded(reason: reason) }
    }

    /// `notifyWriter` false: the writer already ended its session (or went away). A session held by a local key source is
    /// told regardless.
    private func stopFilter(notifyWriter: Bool, reason: String = "") {
        guard let f = filter else { return }
        filter = nil
        if notifyWriter || heldLocally(f) { endKeys(f) }
        js("sb.filterEnd", ["seq": f.seq, "reason": reason])
    }

    private func heldLocally(_ f: KeySession) -> Bool { f.list && keySource.local }

    /// Tells whoever holds the keys of filter session `f` that it ended.
    private func endKeys(_ f: KeySession) {
        if f.list { keySource.end(f.id) } else { helper { $0.endFilter(f.id) } }
    }

    /// `keepRetired` keeps ended sessions whose last keys may still arrive; otherwise the document is being replaced.
    private func stopEdit(notifyWriter: Bool, keepRetired: Bool = false) {
        if !keepRetired { retired = [] }
        guard let e = edit else { return }
        edit = nil
        if notifyWriter { helper { $0.endEdit(e.id) } }
        js("sb.editEnd", ["seq": e.seq])
    }

    func js(_ fn: String, _ arg: [String: Any]) {
        let json = String(data: try! JSONSerialization.data(withJSONObject: arg), encoding: .utf8)!
        host.web.evaluateJavaScript("\(fn)(\(json)); 0") { _, err in
            if let err { log.error("\(fn, privacy: .public) failed: \(String(describing: err), privacy: .public)") }
        }
    }

    func status(_ s: String, sticky: Bool = false) {
        let arg = String(data: try! JSONSerialization.data(withJSONObject: [s]), encoding: .utf8)!
        host.web.evaluateJavaScript("sb.status(\(arg)[0], \(sticky))", completionHandler: nil)
    }

    private func stickyStatus(_ s: String) { status(s, sticky: true) }
}
