import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves the page's `spacebar:` URLs:
///   spacebar://bundle/…            the web/ folder (the CSP allows scripts from here, so a path must stay inside web/)
///   spacebar://file/<abs path>     images beside the document, never anything a browser would run
///   spacebar://user/custom.css     the user's CSS in the support folder
///   spacebar://user/themes/<f>.css a user theme; only a plain file name inside themes/
/// The app's live preview uses it with `fileHost: false`.
final class SchemeHandler: NSObject, WKURLSchemeHandler {
    let webRoot: URL
    let supportDir: () -> URL
    let fileHost: Bool
    var onRefused: (String) -> Void = { _ in }
    static let maxUserCSSBytes = 1 << 20

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
            let f = URL(fileURLWithPath: url.path).standardizedFileURL
            return UTType(filenameExtension: f.pathExtension)?.conforms(to: .image) == true ? f : nil
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

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        guard let fileURL = resolve(url) else {
            onRefused("refused load \(url.absoluteString)")
            return task.didFailWithError(URLError(.noPermissionsToReadFile))
        }
        do {
            let data = try Data(contentsOf: fileURL)
            let mime = url.host == "user" ? "text/css" : UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
            // An image (an SVG included) runs no script as <img>; the header keeps it inert however else it might be loaded.
            var headers = ["Content-Type": mime, "Content-Length": String(data.count), "Cache-Control": "no-store"]
            if url.host == "file" { headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'" }
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        } catch {
            onRefused("read failed \(fileURL.path): \(error.localizedDescription)")
            task.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}
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

    /// The document-start script: the settings, then web/settings.js, which applies them to <html> before first paint.
    static func userScript(_ payload: [String: Any], webRoot: URL) -> WKUserScript {
        let apply = (try? String(contentsOf: webRoot.appendingPathComponent("settings.js"), encoding: .utf8)) ?? ""
        return WKUserScript(source: "window.__sbInitial = \(json(payload));\n\(apply)", injectionTime: .atDocumentStart, forMainFrameOnly: true)
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
