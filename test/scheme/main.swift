// Checks SchemeHandler.resolve: the user host serves only custom.css and themes/<name>.css from the support folder, and no
// URL spelling reaches another file. Build and run with test/scheme/run.sh.
import Foundation
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let dir = SettingsFile.supportDir
let fm = FileManager.default
_ = SettingsFile.ensure()
try! Data(":root{}".utf8).write(to: dir.appendingPathComponent("custom.css"))
try! Data(":root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("dark.css"))
try! Data("secret".utf8).write(to: dir.appendingPathComponent("secret.css"))
try! fm.createSymbolicLink(atPath: SettingsFile.themesDir.appendingPathComponent("link.css").path, withDestinationPath: "/etc/hosts")
try! fm.createDirectory(at: SettingsFile.themesDir.appendingPathComponent("dir.css"), withIntermediateDirectories: true)
try! Data(repeating: 0x20, count: SchemeHandler.maxUserCSSBytes + 1).write(to: SettingsFile.themesDir.appendingPathComponent("huge.css"))

let h = SchemeHandler(webRoot: URL(fileURLWithPath: CommandLine.arguments[1]))
func r(_ s: String) -> String? { URL(string: s).flatMap { h.resolve($0) }?.path }

try! Data(":root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("My Theme.css"))
var spaced = Settings(); spaced.userTheme = "My Theme.css"
let spacedURL = PageSettings.payload(spaced, supportDir: dir)["userThemeURL"] as? String ?? ""
check("theme with a space: payload URL is encoded and resolves", spacedURL.contains("My%20Theme.css") && r(spacedURL) != nil)
check("encoded separator inside a name refused", r("spacebar://user/themes/a%2Fdark.css") == nil && r("spacebar://user/themes/%2E%2E%2Fcustom.css") == nil)
check("custom.css served", r("spacebar://user/custom.css") == dir.appendingPathComponent("custom.css").path)
check("theme served", r("spacebar://user/themes/dark.css") == SettingsFile.themesDir.appendingPathComponent("dark.css").path)
check("theme with version query served", r("spacebar://user/themes/dark.css?v=123") != nil)
for bad in ["spacebar://user/settings.json", "spacebar://user/secret.css", "spacebar://user/../settings.json", "spacebar://user/themes/../settings.json",
            "spacebar://user/themes/..%2Fsettings.json", "spacebar://user/themes/%2E%2E/custom.css", "spacebar://user/themes/..%2F..%2F..%2Fetc%2Fhosts",
            "spacebar://user//custom.css", "spacebar://user/./custom.css", "spacebar://user/themes/sub/dark.css", "spacebar://user/themes/",
            "spacebar://user/themes/.hidden.css", "spacebar://user/themes/dark.css%00.png", "spacebar://user/custom.css/",
            "spacebar://user/themes/dir.css", "spacebar://user/themes/huge.css", "spacebar://user/themes/missing.css",
            "spacebar://user/%63ustom.css", "spacebar://USER/custom.css", "spacebar://bundle/../../settings.json", "spacebar://bundle/%2E%2E/Info.plist"] {
    check("refused \(bad)", r(bad) == nil)
}
check("symlinked theme refused", r("spacebar://user/themes/link.css") == nil)
check("bundle file served", r("spacebar://bundle/index.html") != nil)
// The file host: any regular file under the sidebar's root, images only elsewhere, nothing through a link out of the root.
let tree = dir.appendingPathComponent("tree", isDirectory: true).resolvingSymlinksInPath()
let away = dir.appendingPathComponent("away", isDirectory: true).resolvingSymlinksInPath()
try! fm.createDirectory(at: tree.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! fm.createDirectory(at: away, withIntermediateDirectories: true)
for (name, at) in [("a.png", tree), ("doc.pdf", tree), ("notes.txt", tree), ("page.html", tree), ("sub/b.jpg", tree), ("pic.png", away), ("secret.txt", away), ("secret.pdf", away)] {
    try! Data("x".utf8).write(to: at.appendingPathComponent(name))
}
try! fm.createSymbolicLink(atPath: tree.appendingPathComponent("out.txt").path, withDestinationPath: away.appendingPathComponent("secret.txt").path)
try! fm.createSymbolicLink(atPath: tree.appendingPathComponent("out.pdf").path, withDestinationPath: away.appendingPathComponent("secret.pdf").path)
try! fm.createSymbolicLink(atPath: tree.appendingPathComponent("etc").path, withDestinationPath: "/etc")
try! fm.createSymbolicLink(atPath: tree.appendingPathComponent("in.txt").path, withDestinationPath: "notes.txt")
try! fm.createDirectory(at: tree.appendingPathComponent("folder.pdf"), withIntermediateDirectories: true)
mkfifo(tree.appendingPathComponent("fifo.png").path, 0o600)
func fu(_ path: String) -> String { FileTypes.fileURL(path)!.absoluteString }
check("file host, no root: images only", r(fu(tree.path + "/a.png")) != nil && r(fu(tree.path + "/notes.txt")) == nil && r(fu(tree.path + "/doc.pdf")) == nil
      && r("spacebar://file/etc/hosts") == nil)
h.fileRoot = tree.path
check("file host: images under the root; never a PDF (a PDF is drawn natively)", r(fu(tree.path + "/a.png")) != nil && r(fu(tree.path + "/sub/b.jpg")) != nil
      && r(fu(tree.path + "/doc.pdf")) == nil && r(FileTypes.fileURL(tree.path + "/doc.pdf", version: "9")!.absoluteString) == nil)
check("file host: never text, HTML or anything unknown, even under the root", [tree.path + "/notes.txt", tree.path + "/page.html", tree.path + "/in.txt"].allSatisfy { r(fu($0)) == nil })
check("file host: outside the root, images only", r(fu(away.path + "/pic.png")) != nil && r(fu(away.path + "/secret.txt")) == nil
      && r(fu(away.path + "/secret.pdf")) == nil && r("spacebar://file/etc/hosts") == nil && r("spacebar://file/etc/passwd") == nil)
check("file host: no link out of the root", r(fu(tree.path + "/out.txt")) == nil && r(fu(tree.path + "/out.pdf")) == nil
      && r(fu(tree.path + "/etc/hosts")) == nil && r(fu(tree.path + "/etc/passwd")) == nil)
check("file host: an image link is read at its resolved path", r(fu(tree.path + "/a.png")) == FolderListing.realPath(tree.path + "/a.png"))
for bad in [tree.path + "/../away/secret.txt", tree.path + "/sub/../../away/secret.pdf", tree.path + "/./../away/secret.txt"] {
    check("file host: traversal refused \(bad.suffix(28))", r(fu(bad)) == nil && r("spacebar://file" + bad) == nil)
}
check("file host: encoded traversal refused", r("spacebar://file" + tree.path + "/%2E%2E/away/secret.txt") == nil
      && r("spacebar://file" + tree.path + "/..%2Faway%2Fsecret.txt") == nil && r("spacebar://file" + tree.path + "/sub%2F..%2F..%2Faway%2Fsecret.pdf") == nil)
check("file host: folders, FIFOs and missing files refused", r(fu(tree.path + "/folder.pdf")) == nil && r(fu(tree.path + "/fifo.png")) == nil
      && r(fu(tree.path + "/gone.png")) == nil && r(fu(tree.path)) == nil)
check("file host: the query (a cache version) is ignored for images", r(FileTypes.fileURL(tree.path + "/a.png", version: "123")!.absoluteString) != nil)
check("file host: content type by the map; HTML, text and unknown are octet-stream",
      SchemeHandler.contentType(host: "file", file: tree.appendingPathComponent("a.png")) == "image/png"
      && SchemeHandler.contentType(host: "file", file: tree.appendingPathComponent("doc.pdf")) == "application/pdf"
      && SchemeHandler.contentType(host: "file", file: tree.appendingPathComponent("x.svg")) == "image/svg+xml"
      && ["page.html", "notes.txt", "x.js", "x.xhtml", "x"].allSatisfy { SchemeHandler.contentType(host: "file", file: tree.appendingPathComponent($0)) == FileTypes.octetStream }
      && SchemeHandler.contentType(host: "user", file: tree.appendingPathComponent("x.html")) == "text/css")
let pdf = FileTypes.fileURL(tree.path + "/doc.pdf", version: "1")!
check("shell policy: the shell in the main frame only, and no frame at all",
      ShellPolicy.allows(URL(string: ShellPolicy.shell), mainFrame: true) && !ShellPolicy.allows(pdf, mainFrame: true)
      && !ShellPolicy.allows(pdf, mainFrame: false) && !ShellPolicy.allows(URL(string: ShellPolicy.shell), mainFrame: false)
      && !ShellPolicy.allows(FileTypes.fileURL(tree.path + "/page.html"), mainFrame: false)
      && !ShellPolicy.allows(URL(string: "about:blank"), mainFrame: false) && !ShellPolicy.allows(URL(string: "https://example.com/x.pdf"), mainFrame: false))
let noFile = SchemeHandler(webRoot: URL(fileURLWithPath: CommandLine.arguments[1]), fileHost: false)
noFile.fileRoot = tree.path
check("file host off for the app preview", URL(string: fu(tree.path + "/a.png")).flatMap { noFile.resolve($0) } == nil)

// The file host reads off the main thread and answers on it: never after `stop`, and a read past the timeout fails the task
// once while its late result is dropped. Readers are injected; `a.png` under the tree is the resolved file.
final class FakeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    var offMain = false
    init(_ url: URL) { request = URLRequest(url: url) }
    private func note(_ e: String) { events.append(e); if !Thread.isMainThread { offMain = true } }
    func didReceive(_ response: URLResponse) { note("response") }
    func didReceive(_ data: Data) { note("data") }
    func didFinish() { note("finish") }
    func didFailWithError(_ error: Error) { note((error as? URLError)?.code == .timedOut ? "timeout" : "fail") }
}
func spin(_ seconds: TimeInterval, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
}
let web = WKWebView(frame: .zero)
let img = URL(string: fu(tree.path + "/a.png"))!
let gate = DispatchSemaphore(value: 0)
h.readFile = { _ in gate.wait(); return Data("png".utf8) }
h.readTimeout = 5
let stopped = FakeTask(img)
h.webView(web, start: stopped)
check("file host: start does not wait for the read", stopped.events.isEmpty)
h.webView(web, stop: stopped)
gate.signal()
spin(0.3)
check("file host: nothing is sent to a task after stop", stopped.events.isEmpty)
var reads = 0
h.readFile = { _ in reads += 1; return Data("png".utf8) }
let queued = FakeTask(img)
h.webView(web, start: queued)
h.webView(web, stop: queued)
spin(0.3)
check("file host: a task stopped before its read starts is never read", reads == 0 && queued.events.isEmpty)
let served = FakeTask(img)
h.readFile = { _ in Data("png".utf8) }
h.webView(web, start: served)
spin(2) { served.events.last == "finish" }
check("file host: an image read off the main thread is answered on it", served.events == ["response", "data", "finish"] && !served.offMain)
let late = DispatchSemaphore(value: 0)
h.readFile = { _ in late.wait(); return Data("png".utf8) }
h.readTimeout = 0.2
let slow = FakeTask(img)
h.webView(web, start: slow)
spin(1)
late.signal()
spin(0.3)
check("file host: a read past the timeout fails the task once; its late result is dropped", slow.events == ["timeout"])
let refusedTask = FakeTask(URL(string: "spacebar://file/etc/hosts")!)
h.webView(web, start: refusedTask)
check("file host: a refused URL still fails at once", refusedTask.events == ["fail"])
h.readFile = SchemeHandler.readImage
let big = tree.appendingPathComponent("big.png")
try! Data().write(to: big)
let fh = try! FileHandle(forWritingTo: big)
try! fh.truncate(atOffset: UInt64(FileTypes.maxImageBytes) + 1)
try! fh.close()
check("file host: the image read is bounded", (try? SchemeHandler.readImage(big)) == nil && (try? SchemeHandler.readImage(tree.appendingPathComponent("a.png"))) == Data("x".utf8))

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") scheme checks")
exit(failures == 0 ? 0 : 1)
