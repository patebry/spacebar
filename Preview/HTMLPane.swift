import AppKit
import WebKit

/// An HTML file on screen, rendered as a page in its own WKWebView laid over the part of the panel the page reserves for it,
/// like PDFPane. It shares nothing with the preview's web view: no message handler, no `spacebar` scheme, no stored data.
///
/// Scripts run only in a file made on this Mac (no quarantine flag) while the htmlScripts setting allows it; a downloaded file
/// renders with scripts off and nothing loaded from the web. Every navigation away from the file goes to `onLink`, so the
/// pane only ever shows the file it was given.
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

    init(scripts: Bool) {
        self.scripts = scripts
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
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
    }

    /// Whether `url` came from the web: Gatekeeper's quarantine flag, set by browsers, mail and AirDrop.
    static func isDownloaded(_ url: URL) -> Bool {
        getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
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
        let load = { [weak self] in
            guard let self, self.file == url else { return }
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
        view.stopLoading()
        view.loadHTMLString("", baseURL: nil)
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }

    // MARK: navigation: the file itself, its own anchors, and subresources only

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = action.request.url, let file else { return decisionHandler(.cancel) }
        let isMain = action.targetFrame?.isMainFrame ?? false
        if !isMain {
            // Frames inside the page: web content, or files beside it.
            let ok = ["http", "https", "about", "data", "blob"].contains(url.scheme?.lowercased() ?? "")
                || (url.isFileURL && (url.standardizedFileURL.path + "/").hasPrefix(file.deletingLastPathComponent().standardizedFileURL.path + "/"))
            return decisionHandler(ok ? .allow : .cancel)
        }
        if url.isFileURL, url.standardizedFileURL.path == file.standardizedFileURL.path, action.navigationType != .linkActivated || url.fragment != nil {
            return decisionHandler(.allow)
        }
        decisionHandler(.cancel)
        if action.navigationType == .linkActivated { onLink(url) }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        decisionHandler(response.canShowMIMEType ? .allow : .cancel)
    }

    /// target=_blank and window.open: followed like a link, never as a new window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        if action.navigationType == .linkActivated, let url = action.request.url { onLink(url) }
        return nil
    }
}
