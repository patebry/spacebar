import SwiftUI
import WebKit

/// The Appearance tab's preview: the extension's own page, rendering a short sample with the current settings.
struct LivePreview: NSViewRepresentable {
    @ObservedObject var store: SettingsStore

    /// The extension's web folder inside this app, or SPACEBAR_WEB_DIR for a development build without it.
    static let webRoot: URL? = {
        let fm = FileManager.default
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/SpacebarPreview.appex/Contents/Resources/web")
        if fm.fileExists(atPath: bundled.appendingPathComponent("index.html").path) { return bundled }
        if let dir = ProcessInfo.processInfo.environment["SPACEBAR_WEB_DIR"], !dir.isEmpty,
           fm.fileExists(atPath: (dir as NSString).appendingPathComponent("index.html")) {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return nil
    }()

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        guard let root = Self.webRoot else {
            let label = NSTextField(labelWithString: "Preview unavailable: the extension's web folder is missing.")
            label.textColor = .secondaryLabelColor
            label.alignment = .center
            return label
        }
        return context.coordinator.makeWebView(root: root, settings: store.settings)
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.apply(store.settings)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        (view as? WKWebView)?.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        private var web: WKWebView?
        private var root: URL?
        private var ready = false
        private var lastJSON = ""

        static let shell = URL(string: "spacebar://bundle/index.html")!
        /// Marks the page as the app's sample, which hides the toolbar (base.css): its buttons do nothing here.
        static let embedded = WKUserScript(source: "document.documentElement.classList.add('sb-embedded');",
                                           injectionTime: .atDocumentStart, forMainFrameOnly: true)
        static let sample = """
        # Release notes

        Press **space** on any Markdown file to read it the way it was meant to look, with [links](https://example.com) \
        and `inline code`.

        - [x] Pick a theme
        - [ ] Choose a font size

        > Simple things should be simple.

        ```swift
        let greeting = "Hello, spacebar"
        print(greeting)
        ```
        """

        func makeWebView(root: URL, settings: Settings) -> WKWebView {
            self.root = root
            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(SchemeHandler(webRoot: root, fileHost: false), forURLScheme: "spacebar")
            config.userContentController.add(WeakMessageHandler(self), name: "sb")
            let web = PreviewWebView(frame: .zero, configuration: config)
            web.navigationDelegate = self
            web.setValue(false, forKey: "drawsBackground")
            self.web = web
            apply(settings)
            web.load(URLRequest(url: Self.shell))
            return web
        }

        /// The preview is a picture of the settings, not a document: nothing in it can be edited or toggled.
        private func payload(_ s: Settings) -> [String: Any] {
            var p = PageSettings.payload(s)
            p["inlineEditing"] = false
            p["taskToggles"] = false
            return p
        }

        func apply(_ s: Settings) {
            guard let web, let root else { return }
            switch s.appearance {
            case "light": web.appearance = NSAppearance(named: .aqua)
            case "dark": web.appearance = NSAppearance(named: .darkAqua)
            default: web.appearance = nil
            }
            let p = payload(s)
            let json = PageSettings.json(p)
            guard json != lastJSON else { return }
            lastJSON = json
            // A reload (e.g. after a web content crash) starts from these settings, with no flash of the old ones.
            let ucc = web.configuration.userContentController
            ucc.removeAllUserScripts()
            ucc.addUserScript(PageSettings.userScript(p, webRoot: root))
            ucc.addUserScript(Self.embedded)
            if ready {
                web.evaluateJavaScript("(typeof sb === 'object' && typeof sb.applySettings === 'function') ? (sb.applySettings(\(json)), 1) : 0")
            }
        }

        private func renderSample() {
            let doc: [String: Any] = ["text": Self.sample, "path": "/preview.md", "base": "spacebar://bundle/", "name": "Preview", "reason": "open", "ver": 0]
            web?.evaluateJavaScript("sb.render(\(PageSettings.json(doc))); 0")
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            let origin = message.frameInfo.securityOrigin
            guard message.frameInfo.isMainFrame, origin.protocol == "spacebar", origin.host == "bundle",
                  let body = message.body as? [String: Any], body["type"] as? String == "ready" else { return }
            ready = true
            renderSample()
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            let isShell = action.request.url == Self.shell && action.targetFrame?.isMainFrame == true
            decisionHandler(isShell ? .allow : .cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            webView.load(URLRequest(url: Self.shell))
        }
    }
}

/// Scrolls, but takes no clicks: a click would start an inline edit or follow a link in a page that is only a sample.
final class PreviewWebView: WKWebView {
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    override func menu(for event: NSEvent) -> NSMenu? { nil }
}

/// WKUserContentController retains its handlers; this keeps it from retaining the coordinator (and through it, the web view).
final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(ucc, didReceive: message)
    }
}
