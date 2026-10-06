import AppKit
import UniformTypeIdentifiers
import WebKit

/// An HTML file on screen, rendered as a page in its own WKWebView laid over the part of the panel the page reserves for it,
/// like PDFPane. It shares nothing with the preview's web view: no message handler, no `spacebar` scheme, no stored data.
///
/// Scripts run only in a file made on this Mac (no quarantine flag) while the htmlScripts setting is "local"; under "ask" such
/// a file is shown as it would be with scripts, but without them, until the preview's bar is answered. A downloaded file, or
/// any file under "off", renders with scripts off and nothing loaded from the web: it is served through OfflineFiles, with
/// every `<link>` made inert (its sibling stylesheets inlined), no frames at all, and a CSP that allows nothing but its own
/// folder. Every navigation away from the file goes to `onLink`, so the pane only ever shows the file it was given.
///
/// A page with scripts is loaded from its file URL with read access to its folder, so its images, stylesheets and scripts
/// beside it load; its scripts still cannot read those files: WebKit gives each file URL an origin of its own, so fetch and
/// XMLHttpRequest of another file fail, a frame of one is cross-origin, and a canvas an image beside it was drawn on is
/// tainted (test/htmlpane).
final class HTMLPane: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    private(set) var path: String?
    private(set) var placed = false
    /// Whether this view runs scripts, and whether it is served without web access (OfflineFiles); fixed when it is made, so a
    /// file needing another mode gets a new pane.
    let scripts: Bool
    var mode: Mode { scripts ? .scripts : offline != nil ? .offline : .asking }
    var onLink: (URL) -> Void = { _ in }
    private var file: URL?
    private static var offlineRules: WKContentRuleList?

    /// Blocks every web load: a downloaded file must not tell a server it was opened. One rule per scheme: WebKit's url-filter
    /// has no disjunction, and a list with one fails to compile.
    static let offlineRuleSource = "[" + ["^https?://", "^wss?://", "^ftp://"].map {
        #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
    }.joined(separator: ",") + "]"

    /// Serves a pane without web access; nil for one with it, which loads the file itself.
    private let offline: OfflineFiles?
    /// Links a page's own script follows without a click are dropped: see LinkClickGate.
    private var gate = LinkClickGate()
    private var monitor: Any?

    convenience init(scripts: Bool) { self.init(scripts ? .scripts : .offline) }

    init(_ mode: Mode) {
        scripts = mode == .scripts
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Content rules block loads but not the connections `<link rel=preconnect>` and friends open, and a data store's
        // proxy settings did not hold them either (tested on macOS 15): the markup itself is served without them.
        offline = mode == .offline ? OfflineFiles() : nil
        if let offline { config.setURLSchemeHandler(offline, forURLScheme: OfflineFiles.scheme) }
        config.defaultWebpagePreferences.allowsContentJavaScript = scripts
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.mediaTypesRequiringUserActionForPlayback = .all
        view = WKWebView(frame: .zero, configuration: config)
        super.init()
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = false
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        if #available(macOS 13.3, *) { view.isInspectable = false }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] e in
            if let self, let w = self.view.window, e.window === w, !self.view.isHidden,
               self.view.bounds.contains(self.view.convert(e.locationInWindow, from: nil)) {
                self.gate.clicked()
            }
            return e
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// Whether `url` came from the web: Gatekeeper's quarantine flag, set by browsers, mail and AirDrop. Only "no such
    /// attribute" counts as made here; any other error (unreadable, gone, a filesystem without extended attributes) counts
    /// as downloaded, so a doubt never turns scripts on.
    static func isDownloaded(_ url: URL) -> Bool {
        if getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 { return true }
        return errno != ENOATTR
    }


    /// Whether a pane for `url` runs scripts under `setting` (Settings.htmlScripts).
    static func runsScripts(_ url: URL, setting: String) -> Bool { setting == "local" && !isDownloaded(url) }

    /// How a pane shows `url` under `setting`: with scripts (and the web), without scripts while the setting asks (still with
    /// the web, as it would look once they run), or offline.
    enum Mode: Equatable { case scripts, asking, offline }
    static func mode(_ url: URL, setting: String) -> Mode {
        if isDownloaded(url) { return .offline }
        return setting == "local" ? .scripts : setting == "ask" ? .asking : .offline
    }

    static let scanBytes = 8 << 20

    /// Whether an HTML file's text has anything that runs as script: a `<script>` element, an `on…` event attribute, or a
    /// `javascript:` URL in an attribute. A cheap look at its first `scanBytes`, not a parse: it decides only whether the
    /// preview offers to run scripts, never whether they run. Something it misses stays off. One pass, never stepping back,
    /// so no file can make it slow.
    static func hasScripts(_ html: String) -> Bool {
        let s = Array(html.utf8), n = s.count
        var i = 0
        func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        func space(_ c: UInt8) -> Bool { c == 32 || (9...13).contains(c) }
        func skipSpace() { while i < n, space(s[i]) { i += 1 } }
        let script = Array("script".utf8), js = Array("javascript:".utf8)
        while i < n {
            guard s[i] == UInt8(ascii: "<") else { i += 1; continue }
            i += 1
            guard i < n, (97...122).contains(lower(s[i])) else { continue }
            let name = i
            while i < n, !space(s[i]), s[i] != UInt8(ascii: ">"), s[i] != UInt8(ascii: "/") { i += 1 }
            if i - name == script.count, zip(s[name..<i], script).allSatisfy({ lower($0) == $1 }) { return true }
            while i < n, s[i] != UInt8(ascii: ">") {
                if space(s[i]) || s[i] == UInt8(ascii: "/") || s[i] == UInt8(ascii: "=") { i += 1; continue }
                let a = i
                while i < n, !space(s[i]), s[i] != UInt8(ascii: "="), s[i] != UInt8(ascii: ">"), s[i] != UInt8(ascii: "/") { i += 1 }
                let event = i - a > 2 && lower(s[a]) == UInt8(ascii: "o") && lower(s[a + 1]) == UInt8(ascii: "n")
                skipSpace()
                guard i < n, s[i] == UInt8(ascii: "=") else { continue }
                if event { return true }
                i += 1
                skipSpace()
                guard i < n else { break }
                var value: [UInt8] = []
                if s[i] == UInt8(ascii: "\"") || s[i] == UInt8(ascii: "'") {
                    let q = s[i]
                    i += 1
                    while i < n, s[i] != q { if value.count < 64 { value.append(s[i]) }; i += 1 }
                    i += 1
                } else {
                    while i < n, !space(s[i]), s[i] != UInt8(ascii: ">") { if value.count < 64 { value.append(s[i]) }; i += 1 }
                }
                // As a browser reads a URL: leading spaces and any tab or newline inside the scheme do not count.
                let v = value.filter { !space($0) }.map(lower)
                if v.starts(with: js) { return true }
            }
        }
        return false
    }

    static func hasScripts(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return false }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? h.read(upToCount: scanBytes) else { return false }
        return hasScripts(OfflineFiles.decode(data))
    }

    /// Shows `url` above `web`. The same file again (a change on disk) reloads it.
    func show(_ url: URL, over web: NSView) {
        guard web.superview != nil else { return }
        // Added to the container only when the page places it (PDFPane.attach), like the other native views.
        path = url.path
        file = url
        offline?.document = url
        let load = { [weak self] in
            guard let self, self.file == url else { return }
            if self.offline != nil { self.view.load(URLRequest(url: OfflineFiles.url(for: url))); return }
            self.view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        if offline == nil { return load() }
        if let r = Self.offlineRules {
            view.configuration.userContentController.add(r)
            return load()
        }
        WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "spacebar-html-offline", encodedContentRuleList: Self.offlineRuleSource) { [weak self] list, err in
            // Without the block nothing is loaded at all: an empty pane beats a downloaded page calling home.
            guard let self, let list else { return log.error("html offline rules: \(String(describing: err), privacy: .public)") }
            Self.offlineRules = list
            self.view.configuration.userContentController.add(list)
            load()
        }
    }

    func place(message b: [String: Any], in web: NSView) {
        func num(_ k: String) -> CGFloat? {
            guard let n = b[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return CGFloat(n.doubleValue)
        }
        let hide = (b["hide"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        guard let p = b["path"] as? String, p == path else { return }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return hide ? conceal() : () }
        let zoom = (web as? WKWebView).map { $0.pageZoom * $0.magnification } ?? 1
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius * zoom
        view.layer?.masksToBounds = radius > 0
        guard let f = PDFPane.frame(css: CGRect(x: x, y: y, width: w, height: h), in: web, zoom: zoom) else { view.isHidden = true; return }
        PDFPane.attach(view, frame: f, over: web)
        placed = true
        view.isHidden = hide
    }

    func conceal() { view.isHidden = true }

    func close() {
        file = nil
        gate = LinkClickGate()
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }

    // MARK: navigation: the file itself, its own anchors, and subresources only

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let raw = action.request.url, let file else {
            // close() blanks the view once its file is gone.
            return decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
        }
        // A served page's URLs stand for the files they name.
        let url = OfflineFiles.fileURL(raw) ?? raw
        let isMain = action.targetFrame?.isMainFrame ?? false
        // Without web access no frame loads at all: a frame's document (data:, srcdoc, an SVG or XHTML file beside it) would be
        // one this pane never rewrote, and <link rel=preconnect> connects whatever CSP and content rules say.
        if !isMain, offline != nil { return decisionHandler(.cancel) }
        if !isMain {
            // Frames inside the page: web content, or files beside it (a pane without web access has its loads blocked).
            let ok = ["http", "https", "about", "data", "blob", OfflineFiles.scheme].contains(raw.scheme?.lowercased() ?? "")
                || (url.isFileURL && (url.standardizedFileURL.path + "/").hasPrefix(file.deletingLastPathComponent().standardizedFileURL.path + "/"))
            return decisionHandler(ok ? .allow : .cancel)
        }
        let isFile = url.isFileURL && url.standardizedFileURL.path == file.standardizedFileURL.path
        if isFile, action.navigationType != .linkActivated || url.fragment != nil {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated { follow(url) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    /// target=_blank and window.open: followed like a link, never as a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url { follow(url) }
        return nil
    }

    /// A link leaves the pane only for a click the user made in it: a script's `a.click()` or `window.open` is not one.
    private func follow(_ url: URL) {
        guard gate.allow() else { return log.info("html: a link without a click was not followed") }
        onLink(url)
    }
}

/// One link per real click in the pane, within a second of it. A scripted page can activate links itself (`a.click()`
/// counts as linkActivated in WebKit); only the user's mouse-up in the pane lets one through.
struct LinkClickGate {
    static let window: TimeInterval = 1
    private var last: Date?

    mutating func clicked(at now: Date = Date()) { last = now }

    mutating func allow(at now: Date = Date()) -> Bool {
        guard let t = last, now.timeIntervalSince(t) >= 0, now.timeIntervalSince(t) <= Self.window else { return false }
        last = nil
        return true
    }
}

/// A downloaded HTML file and what sits beside it, served to its pane under `spacebar-html:`: only regular files inside the
/// file's folder (symbolic links resolved, then checked again); the file itself as the only document, rewritten (`document`);
/// anything else only as a stylesheet, an image or a font; every response under a CSP that allows no script, no frame and
/// nothing from anywhere but that folder. The pane cancels every frame, and the content rules block web loads as well.
final class OfflineFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "spacebar-html"
    static let csp = "default-src 'self' data: blob:; script-src 'none'; style-src 'self' 'unsafe-inline' data:; connect-src 'none'; "
        + "frame-src 'none'; child-src 'none'; object-src 'none'; form-action 'none'; base-uri 'self'"
    static let maxBytes = 64 << 20
    /// The file on screen; its folder is all that is served, and only it is served as a document.
    var document: URL?
    private var stopped = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "md.spacebar.html-offline", qos: .userInitiated)

    /// What a file beside the document may be served as: never a document (HTML, XML, XHTML), so nothing else is ever parsed as
    /// markup. SVG only as an image, which loads nothing.
    static let subresourceTypes: [String: String] = [
        "css": "text/css", "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp",
        "avif": "image/avif", "bmp": "image/bmp", "ico": "image/x-icon", "tif": "image/tiff", "tiff": "image/tiff", "heic": "image/heic",
        "svg": "image/svg+xml", "woff": "font/woff", "woff2": "font/woff2", "ttf": "font/ttf", "otf": "font/otf",
    ]

    static func url(for file: URL) -> URL {
        var c = URLComponents()
        c.scheme = scheme
        c.host = "local"
        c.path = file.path
        return c.url!
    }

    /// The file a served URL names (fragment and query kept), or nil for any other URL.
    static func fileURL(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == scheme, url.host == "local", !url.path.isEmpty,
              var c = URLComponents(url: URL(fileURLWithPath: url.path), resolvingAgainstBaseURL: false) else { return nil }
        c.fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment
        return c.url
    }

    /// `file` resolved, when it is inside `root` (resolved too); nil otherwise.
    static func inside(_ file: URL, root: URL) -> URL? {
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = URL(fileURLWithPath: file.path).resolvingSymlinksInPath().standardizedFileURL
        return resolved.path.hasPrefix(base) ? resolved : nil
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        guard let url = task.request.url, let doc = document, let f = Self.fileURL(url),
              let file = Self.inside(f, root: doc.deletingLastPathComponent()) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        let isDocument = file.path == doc.resolvingSymlinksInPath().standardizedFileURL.path
        let mime = isDocument ? "text/html; charset=utf-8" : Self.subresourceTypes[file.pathExtension.lowercased()]
        guard let mime else { return task.didFailWithError(URLError(.noPermissionsToReadFile)) }
        queue.async {
            let body = Self.read(file).map { isDocument ? Self.document($0, folder: doc.deletingLastPathComponent()) : $0 }
            DispatchQueue.main.async {
                guard !self.stopped.contains(id) else { return }
                guard let body else { return task.didFailWithError(URLError(.noPermissionsToReadFile)) }
                // X-DNS-Prefetch-Control: hyperlinks' host names are not looked up ahead of a click.
                let headers = ["Content-Type": mime, "Content-Security-Policy": Self.csp, "X-Content-Type-Options": "nosniff", "X-DNS-Prefetch-Control": "off"]
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didReceive(body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    /// A regular file's bytes, at most `limit`.
    static func read(_ file: URL, limit: Int = maxBytes) -> Data? {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= limit else { return nil }
        return try? h.readToEnd() ?? Data()
    }

    // MARK: the document, rewritten

    static let maxSheets = 8
    static let maxSheetBytes = 1 << 20

    /// The document as served: decoded from its own encoding and sent as UTF-8, sibling stylesheets inlined, and every `<link>`
    /// start tag, of any namespace prefix, made an inert element. Resource hints are never looked for by their rel (entities,
    /// decoys and odd quoting defeat that): no element named link survives.
    static func document(_ data: Data, folder: URL) -> Data {
        var html = decode(data)
        html = inlineStylesheets(html, folder: folder)
        html = inertLinks(html)
        html = replace(html, #"<meta\b[^>]*charset[^>]*>"#, with: #"<meta charset="utf-8">"#)
        // Nothing goes before the document's own text: markup ahead of <!DOCTYPE> puts the page in quirks mode. DNS prefetching
        // is turned off by a response header instead.
        return Data(html.utf8)
    }

    /// Every start tag named `link` or `<prefix>:link`, in any case, renamed; what follows the name is left as is.
    static func inertLinks(_ html: String) -> String {
        replace(html, #"<(?:[^\s/<>:]*:)*link(?=[\s/>]|$)"#, with: "<spacebar-inert", options: [.caseInsensitive])
    }

    static func replace(_ s: String, _ pattern: String, with template: String, options: NSRegularExpression.Options = [.caseInsensitive]) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// `<link rel=stylesheet href=…>` naming a regular file in the folder (at most maxSheets, each maxSheetBytes) becomes a
    /// `<style>` with its text. Anything this misreads is still made inert afterwards; a sheet's own `</style>` or `<link` gains
    /// nothing, since the inert pass runs over the result.
    static func inlineStylesheets(_ html: String, folder: URL) -> String {
        guard let re = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = "", at = 0, used = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard used < maxSheets else { break }
            let tag = ns.substring(with: m.range)
            guard tag.range(of: #"\brel\s*=\s*["']?[^"'>]*\bstylesheet\b"#, options: [.regularExpression, .caseInsensitive]) != nil,
                  let href = attribute("href", in: tag), !href.contains(":"), !href.hasPrefix("/"), !href.hasPrefix("\\"),
                  let rel = href.removingPercentEncoding,
                  let file = inside(folder.appendingPathComponent(rel.components(separatedBy: CharacterSet(charactersIn: "?#")).first ?? rel), root: folder),
                  file.pathExtension.lowercased() == "css",
                  let data = read(file, limit: maxSheetBytes) else { continue }
            used += 1
            let css = replace(decode(data), #"@import\s+(?:url\()?\s*["']?\s*(?:[a-z][a-z0-9+.-]*:|//)[^;]*;?"#, with: "")
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at)) + "<style>" + css + "</style>"
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    static func attribute(_ name: String, in tag: String) -> String? {
        guard let r = tag.range(of: "\\b\(name)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", options: [.regularExpression, .caseInsensitive]) else { return nil }
        var v = String(tag[r].split(separator: "=", maxSplits: 1).last ?? "").trimmingCharacters(in: .whitespaces)
        if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
        return v
    }

    /// The text of an HTML file: a byte order mark wins, then a charset named in its first 1024 bytes, then UTF-8 when the bytes
    /// are valid UTF-8, else Windows-1252 (what browsers assume).
    static func decode(_ d: Data) -> String {
        if d.starts(with: [0xEF, 0xBB, 0xBF]) { return String(decoding: d.dropFirst(3), as: UTF8.self) }
        if d.starts(with: [0xFF, 0xFE]) { return String(data: d.dropFirst(2), encoding: .utf16LittleEndian) ?? "" }
        if d.starts(with: [0xFE, 0xFF]) { return String(data: d.dropFirst(2), encoding: .utf16BigEndian) ?? "" }
        let head = String(decoding: d.prefix(1024).map { $0 < 0x80 ? $0 : 0x3F }, as: UTF8.self)
        if let r = head.range(of: #"charset\s*=\s*["']?\s*[A-Za-z0-9_.:-]+"#, options: [.regularExpression, .caseInsensitive]) {
            let label = head[r].split(separator: "=", maxSplits: 1).last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")).lowercased() } ?? ""
            // A document that says UTF-16 without a byte order mark is read as UTF-8, as browsers do.
            if !label.hasPrefix("utf-16"), label != "utf-8", label != "utf8" {
                let cf = CFStringConvertIANACharSetNameToEncoding(label as CFString)
                let enc = cf == kCFStringEncodingInvalidId ? nil : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cf))
                // Browsers read ISO-8859-1 and ASCII as Windows-1252.
                let chosen = ["iso-8859-1", "latin1", "us-ascii", "ascii"].contains(label) ? .windowsCP1252 : enc
                if let chosen, let s = String(data: d, encoding: chosen) { return s }
            }
        }
        return String(data: d, encoding: .utf8) ?? String(data: d, encoding: .windowsCP1252) ?? String(decoding: d, as: UTF8.self)
    }
}
