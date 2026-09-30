import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the page's `spacebar:` URLs:
///   spacebar://bundle/…            the web/ folder (the CSP allows scripts from here, so a path must stay inside web/)
///   spacebar://file/<abs path>     read-only, typed by an explicit map (FileTypes.contentTypes): images only (a document's
///                                  relative images, the image viewer). Nothing else is served, so no file can be loaded as a
///                                  page, a script, a style or a frame
///   spacebar://user/custom.css     the user's CSS in the support folder
///   spacebar://user/themes/<f>.css a user theme; only a plain file name inside themes/
///   spacebar://body/<token>        the text of the render in flight, too large to send as a script (PageBody): once, as
///                                  plain text, and only while its file is the one on screen. Nothing is read from disk
/// The app's live preview uses it with `fileHost: false`.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let webRoot: URL
    let supportDir: () -> URL
    let fileHost: Bool
    var onRefused: (String) -> Void = { _ in }
    /// The root of the sidebar's tree.
    var fileRoot: String?
    static let maxUserCSSBytes = 1 << 20
    /// How the `file` host reads a resolved image, off the main thread (tests inject a slow one).
    var readFile: (URL) throws -> Data = SchemeHandler.readImage
    /// A `file` read still running after this fails its task; the read itself finishes on its own and is dropped.
    var readTimeout: TimeInterval = FileLoader.downloadTimeout
    /// The `file` tasks still owed an answer, each with the token of its start. Main thread only: `stop` removes a task, and
    /// nothing is sent to a task that is no longer here.
    private var live: [ObjectIdentifier: Int] = [:]
    private var tokens = 0
    /// Image reads, a few at a time: offline, each read of an evicted image blocks its thread until the download gives up, and
    /// a note full of them must not take every worker thread. A task's timeout starts when its read does, so a local image
    /// queued behind stuck downloads still loads, and a task stopped while queued is never read.
    private static let reads: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        q.qualityOfService = .userInitiated
        return q
    }()

    /// The one text the `body` host may serve, set by each render (nil for one that sends its text inline).
    var body: PageBody?
    /// Whether `path` is still the file on screen: a body for any other file is dropped unserved.
    var bodyCurrent: (String) -> Bool = { _ in false }

    init(webRoot: URL, supportDir: @escaping () -> URL = { SettingsFile.supportDir }, fileHost: Bool = true) {
        self.webRoot = webRoot.standardizedFileURL
        self.supportDir = supportDir
        self.fileHost = fileHost
    }

    /// The file a `user` URL names, or nil when the path is not exactly custom.css or themes/<valid name>. No normalizing is
    /// done first: a path with `..`, `.`, `//`, escapes or anything else simply does not match.
    static func userFile(_ path: String, in dir: URL) -> URL? {
        if path == "/custom.css" { return dir.appendingPathComponent("custom.css") }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        // The name is decoded on its own, after splitting, and validated decoded: an encoded separator stays inside the name
        // and fails validation there.
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "themes", let name = String(parts[2]).removingPercentEncoding,
              Settings.validUserTheme(name) else { return nil }
        return dir.appendingPathComponent("themes").appendingPathComponent(name)
    }

    func resolve(_ url: URL) -> URL? {
        switch url.host {
        case "bundle":
            let f = webRoot.appendingPathComponent(url.path).standardizedFileURL
            return f.path.hasPrefix(webRoot.path + "/") ? f : nil
        case "file" where fileHost:
            // Only what a viewer loads: an image (inside the root, or beside a Markdown document anywhere). A PDF is drawn
            // natively, never loaded by the page. The checked path, symlinks resolved, is what is read.
            let f = URL(fileURLWithPath: url.path).standardizedFileURL
            guard FileTypes.contentType(forPath: f.path).hasPrefix("image/"), let real = FolderListing.realPath(f.path) else { return nil }
            var st = stat()
            guard lstat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= FileTypes.maxImageBytes else { return nil }
            return URL(fileURLWithPath: real)
        case "user":
            // percentEncodedPath: an encoded "%2F" or "%2E%2E" must not decode into a separator or a parent step.
            let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath ?? ""
            guard let f = Self.userFile(raw, in: supportDir()) else { return nil }
            var st = stat()
            // lstat: a symlink is refused, so the name always means a file that really sits in the folder.
            guard lstat(f.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= Self.maxUserCSSBytes else { return nil }
            return f
        default:
            return nil
        }
    }

    /// The Content-Type a resolved file is served with: the user host serves CSS only, the file host goes by FileTypes' map.
    static func contentType(host: String?, file: URL) -> String {
        switch host {
        case "user": return "text/css"
        case "file": return FileTypes.contentType(forPath: file.path)
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? FileTypes.octetStream
        }
    }

    /// An image the `file` host serves, downloaded first when iCloud has evicted it; never more than the image bound.
    static func readImage(_ url: URL) throws -> Data {
        try FileTypes.materializing {
            let h = try FileHandle(forReadingFrom: url)
            defer { try? h.close() }
            let data = try h.read(upToCount: Int(FileTypes.maxImageBytes) + 1) ?? Data()
            guard data.count <= FileTypes.maxImageBytes else { throw URLError(.dataLengthExceedsMaximum) }
            return data
        }
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        if url.host == "body" { return serveBody(task, url: url) }
        guard let fileURL = resolve(url) else {
            onRefused("refused load \(url.absoluteString)")
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        guard url.host == "file" else {
            // The page's own files and the user's CSS: local, small, read here.
            do { respond(task, url: url, file: fileURL, data: try Data(contentsOf: fileURL)) } catch { fail(task, fileURL, error) }
            return
        }
        // An image may be in iCloud and not downloaded: read off the main thread, answered on it unless stopped or timed out.
        tokens += 1
        let id = ObjectIdentifier(task), token = tokens
        live[id] = token
        let finish = { [weak self] (r: Result<Data, Error>) in
            // The closure holds the task, so its identifier cannot be reused by another task meanwhile.
            guard let self, self.live[id] == token else { return }
            self.live[id] = nil
            switch r {
            case .success(let data): self.respond(task, url: url, file: fileURL, data: data)
            case .failure(let error): self.fail(task, fileURL, error)
            }
        }
        let read = readFile, timeout = readTimeout
        Self.reads.addOperation { [weak self] in
            // Main never waits on this queue, so the hop cannot deadlock.
            let wanted = DispatchQueue.main.sync { () -> Bool in
                guard let self, self.live[id] == token else { return false }
                DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { finish(.failure(URLError(.timedOut))) }
                return true
            }
            guard wanted else { return }
            let r = Result { try read(fileURL) }
            DispatchQueue.main.async { finish(r) }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {
        live[ObjectIdentifier(task)] = nil
    }

    private func respond(_ task: WKURLSchemeTask, url: URL, file: URL, data: Data) {
        let mime = Self.contentType(host: url.host, file: url.host == "file" ? URL(fileURLWithPath: url.path) : file)
        // An image (an SVG included) runs no script as <img>; the headers keep a file inert however else it might be loaded.
        var headers = ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store", "X-Content-Type-Options": "nosniff"]
        if url.host == "file" {
            headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
        }
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(data)
        task.didFinish()
    }

    /// The pending body, if `url` names its token exactly and its file is still on screen; taken, so a token is good for one
    /// request. A request for any other URL (a superseded render's) leaves it for the render it belongs to.
    private func serveBody(_ task: WKURLSchemeTask, url: URL) {
        guard let b = body, url.absoluteString == b.url, bodyCurrent(b.path) else {
            onRefused("refused load \(url.absoluteString)")
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        body = nil
        let headers = ["Content-Type": "text/plain; charset=utf-8", "Content-Length": String(b.data.count), "Cache-Control": "no-store",
                       "X-Content-Type-Options": "nosniff", "Content-Security-Policy": "default-src 'none'",
                       "Access-Control-Allow-Origin": PageBody.origin]
        task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
        task.didReceive(b.data)
        task.didFinish()
    }

    private func fail(_ task: WKURLSchemeTask, _ file: URL, _ error: Error) {
        onRefused("read failed \(file.path): \(error.localizedDescription)")
        task.didFailWithError(error)
    }
}

/// A render's text sent apart from its script. JSON-escaping a large text into `sb.render(...)` holds the main thread (tens of
/// ms for a 16 MB table, over 100 for one of accented or CJK text) and copies it several times; as a body it is one copy, and
/// the page reads it with a synchronous request as its render starts, so renders still run one at a time, in order.
struct PageBody {
    static let threshold = 256 << 10
    static let origin = "spacebar://bundle"
    let url: String
    /// The file the text is of: served only while it is on screen.
    let path: String
    let data: Data

    /// Moves `payload`'s text into a body when it is past the threshold; the payload names the body's URL in its place.
    static func take(_ payload: inout [String: Any]) -> PageBody? {
        // Either count is constant-time for the string's own storage (native UTF-8, or a bridged UTF-16 NSString).
        guard let text = payload["text"] as? String, let path = payload["path"] as? String,
              (text.utf8.withContiguousStorageIfAvailable { $0.count } ?? text.utf16.count) > threshold else { return nil }
        // A byte order mark first: the page's decoder takes exactly one off, so a text that starts with U+FEFF keeps it.
        var data = Data([0xEF, 0xBB, 0xBF])
        if text.utf8.withContiguousStorageIfAvailable({ data.append(contentsOf: $0) }) == nil { data.append(contentsOf: text.utf8) }
        let body = PageBody(url: "spacebar://body/" + UUID().uuidString, path: path, data: data)
        payload["text"] = nil
        payload["textURL"] = body.url
        return body
    }
}

/// Why a document's local images did not load, for the page's placeholders. The page asks only about images that failed, and
/// the answer goes to the page alone: nothing is loaded or read. The folders an answer found are the only ones the page may
/// then ask to reveal, and a missing image's nearest folder is watched, so the document renders again once the image appears.
final class ImageCheck {
    static let maxPaths = 64
    /// Paths answered per document: a document naming thousands of images gets placeholders without reasons past this.
    static let maxPerDoc = 256
    static let maxWatches = 16
    static let maxListed = 5000
    private(set) var doc: String?
    private var folders: Set<String> = []
    private var missing: Set<String> = []
    private var answered: Set<String> = []
    /// Each folder's entries by lowercased name, read once per document for the case hint.
    private var listed: [String: [String: String]] = [:]
    private var watches: [String: FolderWatch] = [:]
    /// A missing image of the document is now there.
    var onAppeared: () -> Void = {}

    func reset() {
        doc = nil
        folders = []
        missing = []
        answered = []
        listed = [:]
        watches = [:]
    }

    /// {reason: missing | unreadable | unsupported | tooLarge | notDownloaded | ok, folder: its folder exists, suggest: a name
    /// in that folder differing only in case}. `ok`: readable now, so the page tries it once more.
    static func status(_ path: String, caseMatch match: (String, String) -> String? = { caseMatch($0, in: $1) }) -> [String: Any] {
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        let folder = stat(dir, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        var out: [String: Any] = ["folder": folder]
        if stat(path, &st) != 0 {
            let missing = errno == ENOENT || errno == ENOTDIR
            out["reason"] = missing ? "missing" : "unreadable"
            if missing, folder, let s = match((path as NSString).lastPathComponent, dir) { out["suggest"] = s }
        } else if st.st_mode & S_IFMT != S_IFREG || !FileTypes.contentType(forPath: path).hasPrefix("image/") {
            out["reason"] = "unsupported"
        } else if Int64(st.st_size) > FileTypes.maxImageBytes {
            out["reason"] = "tooLarge"
        } else if st.st_flags & 0x4000_0000 != 0 {
            out["reason"] = "notDownloaded"
        } else {
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }
            out["reason"] = fd >= 0 ? "ok" : "unreadable"
        }
        return out
    }

    /// The entry of `dir` whose name is `name` but for case, if any; at most maxListed entries are looked at.
    static func caseMatch(_ name: String, in dir: String) -> String? {
        caseMatch(name, among: entries(dir))
    }

    static func entries(_ dir: String) -> [String] {
        guard let d = opendir(dir) else { return [] }
        defer { closedir(d) }
        var names: [String] = []
        while names.count < maxListed, let e = readdir(d) {
            names.append(withUnsafePointer(to: e.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } })
        }
        return names
    }

    static func caseMatch(_ name: String, among names: [String]) -> String? {
        let want = name.lowercased()
        return names.first { $0 != name && $0.lowercased() == want }
    }

    /// The statuses of `raw` (the page's list of absolute, plain paths) for `doc`, the document on screen; nil for a bad list.
    func answer(_ raw: Any?, doc: String) -> [String: Any]? {
        guard let list = raw as? [Any], list.count <= Self.maxPaths else { return nil }
        if doc != self.doc { reset(); self.doc = doc }
        var out: [String: Any] = [:]
        for case let p as String in list where p.utf8.count <= 4096 && p.hasPrefix("/")
            && URL(fileURLWithPath: p, isDirectory: false).standardizedFileURL.path == p {
            guard answered.contains(p) || answered.count < Self.maxPerDoc else { break }
            answered.insert(p)
            let s = Self.status(p) { name, dir in
                if self.listed[dir] == nil {
                    self.listed[dir] = Dictionary(Self.entries(dir).map { ($0.lowercased(), $0) }) { a, _ in a }
                }
                return self.listed[dir]?[name.lowercased()].flatMap { $0 == name ? nil : $0 }
            }
            out[p] = s
            let dir = (p as NSString).deletingLastPathComponent
            if s["folder"] as? Bool == true { folders.insert(dir) }
            if s["reason"] as? String == "missing" {
                missing.insert(p)
                watchNearest(dir)
            }
        }
        return out
    }

    /// The folder of `path`, when one of `doc`'s answers found it and it is still a folder.
    func revealable(_ path: String?, doc: String) -> URL? {
        guard doc == self.doc, let path else { return nil }
        let dir = (path as NSString).deletingLastPathComponent
        var st = stat()
        guard folders.contains(dir), stat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        return URL(fileURLWithPath: dir, isDirectory: true)
    }

    /// The deepest existing folder on the way to `dir`: a new entry there may be the image, or a folder on its way to it.
    private func watchNearest(_ dir: String) {
        var d = dir
        var st = stat()
        while d != "/", !(stat(d, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR) { d = (d as NSString).deletingLastPathComponent }
        guard d != "/", watches[d] == nil, watches.count < Self.maxWatches else { return }
        watches[d] = FolderWatch(path: d) { [weak self] in self?.changed() }
    }

    private func changed() {
        var st = stat()
        let appeared = missing.filter { stat($0, &st) == 0 }
        missing.subtract(appeared)
        for p in missing { watchNearest((p as NSString).deletingLastPathComponent) }
        if !appeared.isEmpty { onAppeared() }
    }
}

/// Which navigations the preview's web view allows: the shell page in the main frame, and no subframe at all (the document's
/// frames are sanitized away and blocked by the CSP; a PDF is a native view, not a frame).
enum ShellPolicy {
    static let shell = "spacebar://bundle/index.html"

    static func allows(_ url: URL?, mainFrame: Bool) -> Bool {
        guard let url, mainFrame else { return false }
        return url.absoluteString == shell
    }
}

/// What the page is told about the settings: the settings themselves plus the URLs of the user CSS to load, each versioned by
/// its modification time so an edit to the file reloads it.
enum PageSettings {
    static func payload(_ s: Settings, supportDir dir: URL = SettingsFile.supportDir) -> [String: Any] {
        var p = s.dictionary
        func versioned(_ f: URL, _ path: String) -> Any {
            var st = stat()
            guard stat(f.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return NSNull() }
            return "spacebar://user\(path)?v=\(st.st_mtimespec.tv_sec)\(st.st_mtimespec.tv_nsec)"
        }
        p["customCSSURL"] = s.customCSS ? versioned(dir.appendingPathComponent("custom.css"), "/custom.css") : NSNull()
        p["userThemeURL"] = s.userTheme.map { name in
            versioned(dir.appendingPathComponent("themes").appendingPathComponent(name),
                      "/themes/" + (name.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "._-"))) ?? ""))
        } ?? NSNull()
        return p
    }

    static func json(_ payload: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), encoding: .utf8)!
    }

    static let hosts = ["quicklook", "panel"]

    /// The document-start script: the settings and who shows the page (`hosts`: Quick Look, or the Space helper's panel),
    /// then web/settings.js, which applies them to <html> before first paint.
    static func userScript(_ payload: [String: Any], webRoot: URL, host: String = "quicklook") -> WKUserScript {
        let apply = (try? String(contentsOf: webRoot.appendingPathComponent("settings.js"), encoding: .utf8)) ?? ""
        let h = hosts.contains(host) ? host : "quicklook"
        return WKUserScript(source: "window.__sbInitial = \(json(payload));\nwindow.__sbHost = \"\(h)\";\n\(apply)", injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    /// Blocks every http(s) image; installed when remoteImages is off.
    static let remoteImageRules = #"[{"trigger":{"url-filter":"^https?://","resource-type":["image"]},"action":{"type":"block"}}]"#
}

/// The remote-image block on one web view: a content rule list, in place while remoteImages is off. A blocked image's
/// placeholder offers "Load images from the web", which lifts the block for the one document on screen until the preview
/// shows another document or closes. Nothing here is saved, and the page's CSP is not involved.
final class RemoteImageGate {
    /// The render payload key that tells the page to show this document's remote images.
    static let payloadKey = "remoteImagesOnce"
    private let ucc: WKUserContentController
    private var setting = true
    private(set) var allowedPath: String?
    private var installed = false
    private var compiling = false
    private var waiting: [() -> Void] = []
    private static var rules: WKContentRuleList?
    var onError: (String) -> Void = { _ in }

    init(_ ucc: WKUserContentController) { self.ucc = ucc }

    var blocking: Bool { !setting && allowedPath == nil }

    /// Whether the page may show `path`'s remote images.
    func allows(_ path: String) -> Bool { setting || allowedPath == path }

    func update(remoteImages: Bool) {
        setting = remoteImages
        sync()
    }

    /// The reader's click in a placeholder of the document at `path`, which must be the one on screen. False when refused.
    func allowOnce(_ path: String, current: String?) -> Bool {
        guard !setting, let current, path == current else { return false }
        allowedPath = path
        sync()
        return true
    }

    /// A new preview or another document: the block is back for whatever is rendered next.
    func reset() {
        allowedPath = nil
        sync()
    }

    /// Runs `f` once the rule list matches `blocking`, so no render can fetch remote images before the block is in place.
    func whenInPlace(_ f: @escaping () -> Void) {
        compiling ? waiting.append(f) : f()
    }

    private func sync() {
        guard blocking != installed else { return }
        if !blocking {
            if let r = Self.rules { ucc.remove(r) }
            installed = false
            return
        }
        if let r = Self.rules {
            ucc.add(r)
            installed = true
            return
        }
        guard !compiling else { return }
        compiling = true
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "spacebar-remote-images", encodedContentRuleList: PageSettings.remoteImageRules) { [weak self] list, err in
            guard let self else { return }
            self.compiling = false
            if let list { Self.rules = list } else { self.onError("remote image rules: \(String(describing: err))") }
            if list != nil { self.sync() }
            let w = self.waiting
            self.waiting = []
            w.forEach { $0() }
        }
    }
}
