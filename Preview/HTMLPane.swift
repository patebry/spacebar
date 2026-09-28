import AppKit
import UniformTypeIdentifiers
import WebKit

/// An HTML file on screen, rendered as a page in its own WKWebView laid over the part of the panel the page reserves for it,
/// like PDFPane. It shares nothing with the preview's web view: no message handler, no `spacebar` scheme, no stored data.
///
/// Scripts run only in a file made on this Mac (no quarantine flag) while the htmlScripts setting allows it; a downloaded file
/// renders with scripts off and nothing loaded from the web: it is served through OfflineFiles, with its resource hints taken
/// out and a CSP that allows nothing but its own folder. Every navigation away from the file goes to `onLink`, so the pane
/// only ever shows the file it was given.
final class HTMLPane: NSObject, WKNavigationDelegate, WKUIDelegate {
    let view: WKWebView
    private(set) var path: String?
    private(set) var placed = false
    /// Whether this view runs scripts; fixed when it is made, so a file needing the other mode gets a new pane.
    let scripts: Bool
    var onLink: (URL) -> Void = { _ in }
    private var file: URL?
    private static var offlineRules: WKContentRuleList?

    /// Blocks every web load: a downloaded file must not tell a server it was opened. One rule per scheme: WebKit's url-filter
    /// has no disjunction, and a list with one fails to compile.
    static let offlineRuleSource = "[" + ["^https?://", "^wss?://", "^ftp://"].map {
        #"{"trigger":{"url-filter":"\#($0)"},"action":{"type":"block"}}"#
    }.joined(separator: ",") + "]"

    /// Serves a pane without web access; nil for one that runs scripts, which loads the file itself.
    private let offline: OfflineFiles?
    /// Links a page's own script follows without a click are dropped: see LinkClickGate.
    private var gate = LinkClickGate()
    private var monitor: Any?

    init(scripts: Bool) {
        self.scripts = scripts
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // Content rules block loads but not the connections `<link rel=preconnect>` and friends open, and a data store's
        // proxy settings did not hold them either (tested on macOS 15): the markup itself is served without them.
        offline = scripts ? nil : OfflineFiles()
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

    static let hintRels = ["preconnect", "dns-prefetch", "prefetch", "prerender", "preload", "modulepreload"]
    /// Markup without its `<link>` resource hints, which open connections that content rules do not see.
    static func strippingHints(_ html: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]) else { return html }
        let ns = html as NSString
        var out = "", at = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range).lowercased()
            guard let rel = tag.range(of: #"rel\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#, options: .regularExpression) else { continue }
            let value = tag[rel].split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
            guard hintRels.contains(where: { value.contains($0) }) else { continue }
            out += ns.substring(with: NSRange(location: at, length: m.range.location - at))
            at = m.range.location + m.range.length
        }
        return out + ns.substring(from: at)
    }

    /// Whether a pane for `url` runs scripts under `setting` (Settings.htmlScripts).
    static func runsScripts(_ url: URL, setting: String) -> Bool { setting == "local" && !isDownloaded(url) }

    /// Shows `url` above `web`. The same file again (a change on disk) reloads it.
    func show(_ url: URL, over web: NSView) {
        guard let container = web.superview else { return }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: web)
        }
        path = url.path
        file = url
        offline?.root = url.deletingLastPathComponent()
        let load = { [weak self] in
            guard let self, self.file == url else { return }
            if self.offline != nil { self.view.load(URLRequest(url: OfflineFiles.url(for: url))); return }
            self.view.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        if scripts { return load() }
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
        view.frame = f
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
/// file's folder (symbolic links resolved, then checked again), HTML without its resource hints, every response under a CSP
/// that allows no script and nothing from anywhere but that folder. The content rules block web loads as well.
final class OfflineFiles: NSObject, WKURLSchemeHandler {
    static let scheme = "spacebar-html"
    static let csp = "default-src 'self' data: blob:; script-src 'none'; style-src 'self' 'unsafe-inline' data:; connect-src 'none'; "
        + "form-action 'none'; base-uri 'self'; object-src 'none'"
    static let maxBytes = 64 << 20
    /// The folder of the file on screen; set by the pane before each load.
    var root: URL?
    private var stopped = Set<ObjectIdentifier>()
    private let queue = DispatchQueue(label: "md.spacebar.html-offline", qos: .userInitiated)

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

    /// The file to serve for `url`: a regular file inside `root`, both resolved; nil otherwise.
    static func servable(_ url: URL, root: URL?) -> URL? {
        guard let root, let f = fileURL(url) else { return nil }
        let base = root.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let resolved = URL(fileURLWithPath: f.path).resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path.hasPrefix(base) else { return nil }
        return resolved
    }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        stopped.remove(id)
        guard let url = task.request.url, let file = Self.servable(url, root: root) else {
            return task.didFailWithError(URLError(.fileDoesNotExist))
        }
        queue.async {
            let body = Self.read(file)
            DispatchQueue.main.async {
                guard !self.stopped.contains(id) else { return }
                guard let body else { return task.didFailWithError(URLError(.noPermissionsToReadFile)) }
                let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let headers = ["Content-Type": mime, "Content-Security-Policy": Self.csp, "X-Content-Type-Options": "nosniff"]
                task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
                task.didReceive(body)
                task.didFinish()
            }
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) { stopped.insert(ObjectIdentifier(task)) }

    /// A regular file's bytes, at most maxBytes; HTML without its resource hints.
    private static func read(_ file: URL) -> Data? {
        let fd = open(file.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxBytes, let data = try? h.readToEnd() ?? Data() else { return nil }
        guard ["html", "htm", "xhtml"].contains(file.pathExtension.lowercased()) else { return data }
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return Data(HTMLPane.strippingHints(text).utf8)
    }
}
