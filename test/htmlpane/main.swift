import AppKit
import WebKit
import os

let log = Logger(subsystem: "md.spacebar.test", category: "htmlpane")
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

_ = NSApplication.shared
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let local = dir.appendingPathComponent("made-here.html"), downloaded = dir.appendingPathComponent("downloaded.html")
try! Data("<p>hi</p>".utf8).write(to: local)
try! Data("<p>hi</p>".utf8).write(to: downloaded)
let flag = "0083;6543a1b2;Safari;"
check("fixture: the quarantine flag is set on the downloaded file", setxattr(downloaded.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0) == 0,
      String(cString: strerror(errno)))

// ---- which file runs scripts: made on this Mac, and only while the setting allows it ----
check("a file made on this Mac is not downloaded; a quarantined one is", !HTMLPane.isDownloaded(local) && HTMLPane.isDownloaded(downloaded))
check("scripts: on for a file made on this Mac under \"local\"", HTMLPane.runsScripts(local, setting: "local"))
check("scripts: off for a downloaded file, whatever the setting", !HTMLPane.runsScripts(downloaded, setting: "local") && !HTMLPane.runsScripts(downloaded, setting: "off"))
check("scripts: off everywhere under \"off\"", !HTMLPane.runsScripts(local, setting: "off"))
check("scripts: an unknown setting is off", !HTMLPane.runsScripts(local, setting: "on") && !HTMLPane.runsScripts(local, setting: ""))
removexattr(downloaded.path, "com.apple.quarantine", 0)
check("the flag removed: the file counts as made here again", !HTMLPane.isDownloaded(downloaded) && HTMLPane.runsScripts(downloaded, setting: "local"))
check("fails closed: a file whose flag cannot be read (missing here) counts as downloaded", HTMLPane.isDownloaded(dir.appendingPathComponent("nope.html"))
      && !HTMLPane.runsScripts(dir.appendingPathComponent("nope.html"), setting: "local"))

// ---- links: one per real click in the pane, within a second ----
do {
    var g = LinkClickGate()
    let t = Date()
    check("gate: no click, no link", !g.allow(at: t))
    g.clicked(at: t)
    check("gate: a click lets one link through, and only one", g.allow(at: t.addingTimeInterval(0.2)) && !g.allow(at: t.addingTimeInterval(0.3)))
    g.clicked(at: t)
    check("gate: a click over a second ago lets nothing through", !g.allow(at: t.addingTimeInterval(1.5)))
    g.clicked(at: t)
    check("gate: a clock that went back lets nothing through", !g.allow(at: t.addingTimeInterval(-1)))
}

// ---- macOS 13's fallback: resource hints are taken out of the markup ----
do {
    let html = #"<LINK REL="preconnect" href="https://a"><link rel='dns-prefetch' href=//b><link href=x rel=prefetch><link rel="stylesheet preload" href=s.css><link rel=stylesheet href=k.css><p>x</p>"#
    let out = HTMLPane.strippingHints(html)
    check("hints: preconnect, dns-prefetch, prefetch and preload links go; a stylesheet stays",
          out == #"<link rel=stylesheet href=k.css><p>x</p>"#, out)
}

// ---- the two kinds of pane: a local file runs scripts and loads from the web; a downloaded one does neither ----
/// A server on 127.0.0.1 that answers every request with a 404 and counts the connections.
final class Server {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    private(set) var port: UInt16 = 0
    private let lock = NSLock()
    private var n = 0
    var hits: Int { lock.lock(); defer { lock.unlock() }; return n }
    init() {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = bind(fd, $0, len); _ = getsockname(fd, $0, &len) } }
        port = UInt16(bigEndian: addr.sin_port)
        listen(fd, 8)
        Thread { [self] in
            while true {
                let c = accept(self.fd, nil, nil)
                guard c >= 0 else { return }
                self.lock.lock(); self.n += 1; self.lock.unlock()
                var buf = [UInt8](repeating: 0, count: 2048)
                _ = read(c, &buf, buf.count)
                let r = "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
                _ = r.withCString { write(c, $0, strlen($0)) }
                close(c)
            }
        }.start()
    }
}

let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 800, height: 600), styleMask: [.borderless], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
let web = WKWebView(frame: container.bounds)
container.addSubview(web)
window.contentView = container
window.orderBack(nil)

let localServer = Server(), downloadedServer = Server()
func page(_ s: Server) -> Data {
    Data(#"<p id=p>static</p><img src="http://127.0.0.1:\#(s.port)/img.png"><script>document.getElementById('p').textContent = 'scripted'</script>"#.utf8)
}
func text(_ v: WKWebView) -> String? {
    var out: String?, done = false
    v.evaluateJavaScript("document.getElementById('p') && document.getElementById('p').textContent") { r, _ in out = r as? String; done = true }
    for _ in 0..<100 where !done { spin(0.02) }
    return out
}
try! page(localServer).write(to: local)
removexattr(local.path, "com.apple.quarantine", 0)
try! page(downloadedServer).write(to: downloaded)
setxattr(downloaded.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0)

let scripted = HTMLPane(scripts: HTMLPane.runsScripts(local, setting: "local"))
scripted.show(local, over: web)
for _ in 0..<150 where localServer.hits == 0 { spin(0.02) }
spin(0.3)
check("made on this Mac: its scripts run and it loads from the web, like a browser", scripted.scripts && text(scripted.view) == "scripted" && localServer.hits > 0,
      "\(text(scripted.view) ?? "nil") hits \(localServer.hits)")

let closed = HTMLPane(scripts: HTMLPane.runsScripts(downloaded, setting: "local"))
closed.show(downloaded, over: web)
for _ in 0..<150 where closed.view.url == nil { spin(0.02) }
spin(1)
check("downloaded: shown, with scripts off and nothing loaded from the web",
      !closed.scripts && closed.view.url?.path == downloaded.path && text(closed.view) == "static" && downloadedServer.hits == 0,
      "\(text(closed.view) ?? "nil") hits \(downloadedServer.hits)")

// ---- no connection at all from a downloaded file: resource hints included (content rules do not see them) ----
func hintPage(_ s: Server) -> Data {
    let u = "http://127.0.0.1:\(s.port)"
    return Data(#"<link rel=preconnect href="\#(u)/pc"><link rel=dns-prefetch href="\#(u)/dp"><link rel=prefetch href="\#(u)/pf"><link rel=preload as=image href="\#(u)/pl"><p id=p>static</p>"#.utf8)
}
do {
    let server = Server()
    let hinted = dir.appendingPathComponent("hinted.html")
    let outsideName = "spacebar-outside-\(getpid()).png"
    try! (hintPage(server) + Data("<img src=beside.png><img src=link.png><img src=../\(outsideName)>".utf8)).write(to: hinted)
    setxattr(hinted.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0)
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "test/fixtures/img.png"), to: dir.appendingPathComponent("beside.png"))
    let outside = dir.deletingLastPathComponent().appendingPathComponent(outsideName)
    try? FileManager.default.copyItem(at: URL(fileURLWithPath: "test/fixtures/img.png"), to: outside)
    try? FileManager.default.createSymbolicLink(at: dir.appendingPathComponent("link.png"), withDestinationURL: outside)
    let pane = HTMLPane(scripts: false)
    pane.show(hinted, over: web)
    for _ in 0..<150 where pane.view.url == nil { spin(0.02) }
    spin(2)
    check("downloaded: preconnect, dns-prefetch, prefetch and preload reach no server, and the page is shown",
          server.hits == 0 && text(pane.view) == "static" && pane.view.url?.path == hinted.path, "hits \(server.hits) text \(text(pane.view) ?? "nil")")
    var widths: [String: Int] = [:], done = false
    pane.view.evaluateJavaScript("JSON.stringify([...document.images].map((i) => [i.getAttribute('src'), i.naturalWidth]))") { r, _ in
        for pair in ((try? JSONSerialization.jsonObject(with: Data(((r as? String) ?? "[]").utf8))) as? [[Any]]) ?? [] {
            if let k = pair.first as? String, let w = pair.last as? Int { widths[k] = w }
        }
        done = true
    }
    for _ in 0..<200 where !done { spin(0.02) }
    check("downloaded: a picture beside it loads; one outside its folder, or linked from outside, does not",
          (widths["beside.png"] ?? 0) > 0 && widths["link.png"] == 0 && widths["../\(outside.lastPathComponent)"] == 0, "\(widths)")
    pane.close()
    try? FileManager.default.removeItem(at: outside)
}

// ---- a script's own click on a link is not followed ----
let clicker = dir.appendingPathComponent("clicker.html")
try! Data(#"<a id=a href="https://example.invalid/auto">x</a><script>document.getElementById('a').click(); window.open('https://example.invalid/w')</script>"#.utf8).write(to: clicker)
var followed: [URL] = []
let auto = HTMLPane(scripts: true)
auto.onLink = { followed.append($0) }
auto.show(clicker, over: web)
for _ in 0..<150 where auto.view.url == nil { spin(0.02) }
spin(1)
check("a link the page's script clicks, or a window it opens, is not followed without the user's click", followed.isEmpty, "\(followed)")
auto.close()
for _ in 0..<100 where auto.view.url?.absoluteString != "about:blank" { spin(0.02) }
check("close: the pane is blanked", auto.view.url?.absoluteString == "about:blank", auto.view.url?.absoluteString ?? "nil")

scripted.close()
closed.close()
check("close: every pane leaves the container", container.subviews == [web])

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of the") HTML view checks")
exit(failures == 0 ? 0 : 1)
