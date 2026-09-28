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

// ---- the downloaded document as served: no element named link survives, whatever its prefix, case or attributes ----
do {
    let out = OfflineFiles.inertLinks("<LINK rel=preconnect><h:link rel=x/><link\nrel=a><link/><linked><p>link</p><a:b:link>")
    check("inert: link start tags of any case, prefix or ending are renamed; <linked> and text are not",
          out == "<spacebar-inert rel=preconnect><spacebar-inert rel=x/><spacebar-inert\nrel=a><spacebar-inert/><linked><p>link</p><spacebar-inert>", out)
    let latin = Data("<meta charset=windows-1252><p>caf".utf8) + Data([0xE9]) + Data("</p>".utf8)
    check("decode: a declared legacy charset", OfflineFiles.decode(latin).hasSuffix("café</p>"))
    check("decode: invalid UTF-8 with no charset is Windows-1252", OfflineFiles.decode(Data([0x63, 0x61, 0x66, 0xE9])) == "café")
    check("decode: a UTF-16 byte order mark wins", OfflineFiles.decode("<p>ü</p>".data(using: .utf16)!) == "<p>ü</p>")
    let served = String(decoding: OfflineFiles.document(latin, folder: dir), as: UTF8.self)
    check("document: sent as UTF-8 with its charset meta replaced and DNS prefetch off",
          served.contains("café") && served.contains(#"<meta charset="utf-8">"#) && !served.contains("windows-1252") && served.hasPrefix(#"<meta http-equiv="x-dns-prefetch-control" content="off">"#), served)
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

// Every way found to reach a server from a downloaded file, each against its own counting server: zero connections each.
let leakCases: [(String, String)] = [
    ("baseline preconnect", #"<link rel=preconnect href="U/a">"#),
    ("> inside a quoted attribute", #"<link title="a>b" rel=preconnect href="U/a">"#),
    ("data-rel decoy", #"<link data-rel=x rel=preconnect href="U/a">"#),
    ("an entity in rel", #"<link rel="pre&#99;onnect" href="U/a">"#),
    ("a newline after the tag name", "<link\nrel=preconnect href=\"U/a\">"),
    ("upper case, dns-prefetch, prefetch, preload", #"<LINK REL=dns-prefetch HREF="U/d"><link rel=prefetch href="U/p"><link rel=preload as=image href="U/l">"#),
    ("a data: iframe", #"<iframe src="data:text/html,%3Clink%20rel%3Dpreconnect%20href%3D%22U%2Fa%22%3E"></iframe>"#),
    ("srcdoc", #"<iframe srcdoc="&lt;link rel=preconnect href=&quot;U/a&quot;&gt;"></iframe>"#),
    ("a stylesheet on the web", #"<link rel=stylesheet href="U/a.css">"#),
    ("@import, a web font, a background", #"<style>@import url(U/i.css); @font-face{font-family:x;src:url(U/f.woff)} p{font-family:x;background:url(U/bg.png)}</style><p>x</p>"#),
    ("srcset and picture", #"<img srcset="U/s.png 1x"><picture><source srcset="U/p.png"><img src=x.png></picture>"#),
    ("object, embed, video", #"<object data="U/o"></object><embed src="U/e"><video poster="U/v.png" src="U/v.mp4" preload=auto></video>"#),
    ("meta refresh", #"<meta http-equiv=refresh content="0;url=U/r">"#),
    ("svg image and use", #"<svg><image href="U/si.png" width=10 height=10/><use href="U/u.svg#x"/></svg>"#),
    ("an http iframe", #"<iframe src="U/if"></iframe>"#),
    ("a meta CSP loosening it", #"<meta http-equiv=Content-Security-Policy content="default-src *"><img src="U/m.png">"#),
    ("icon and manifest", #"<link rel=icon href="U/i.ico"><link rel=manifest href="U/m.json">"#),
    ("base href", #"<base href="U/"><img src="b.png">"#),
    ("an svg link in the document", #"<svg><foreignObject width=10 height=10><link xmlns="http://www.w3.org/1999/xhtml" rel="preconnect" href="U/a"/></foreignObject></svg>"#),
]
let svgSibling = #"<svg xmlns="http://www.w3.org/2000/svg"><foreignObject width="10" height="10"><link xmlns="http://www.w3.org/1999/xhtml" rel="preconnect" href="U/a"/></foreignObject></svg>"#
let xhtSibling = #"<html xmlns="http://www.w3.org/1999/xhtml"><head><h:link xmlns:h="http://www.w3.org/1999/xhtml" rel="preconnect" href="U/a"/></head><body/></html>"#
let siblingCases: [(String, String, String, String)] = [
    ("an svg beside it in an iframe", "svg", svgSibling, #"<iframe src="S"></iframe>"#),
    ("an svg beside it as an embed", "svg", svgSibling, #"<embed src="S">"#),
    ("an svg beside it as an object", "svg", svgSibling, #"<object data="S"></object>"#),
    ("an .xht beside it", "xht", xhtSibling, #"<iframe src="S"></iframe>"#),
    ("an .xhtml beside it", "xhtml", xhtSibling, #"<iframe src="S"></iframe>"#),
    ("an .xml beside it", "xml", xhtSibling, #"<iframe src="S"></iframe>"#),
    ("an .html beside it", "html", #"<link rel=preconnect href="U/a">"#, #"<iframe src="S"></iframe>"#),
]
func zeroHits(_ name: String, _ html: (String) -> String, sibling: ((String) -> (String, String))? = nil) {
    let server = Server()
    let u = "http://127.0.0.1:\(server.port)"
    let n = abs(name.hashValue) % 1_000_000
    if let sibling { let (file, body) = sibling(u); try! Data(body.utf8).write(to: dir.appendingPathComponent(file)) }
    let f = dir.appendingPathComponent("leak-\(n).html")
    try! Data(("<p id=p>static</p>" + html(u)).utf8).write(to: f)
    setxattr(f.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0)
    let pane = HTMLPane(scripts: false)
    pane.show(f, over: web)
    spin(2)
    check("downloaded, no connection: \(name)", server.hits == 0, "hits \(server.hits)")
    pane.close()
}
for (name, tpl) in leakCases { zeroHits(name, { tpl.replacingOccurrences(of: "U/", with: $0 + "/") }) }
for (name, ext, body, host) in siblingCases {
    let file = "sibling-\(abs(name.hashValue) % 1_000_000).\(ext)"
    zeroHits(name, { _ in host.replacingOccurrences(of: "S", with: file) }, sibling: { (file, body.replacingOccurrences(of: "U/", with: $0 + "/")) })
}
do {
    let server = Server()
    let f = dir.appendingPathComponent("utf16.html")
    try! "<p>x</p><link rel=preconnect href=\"http://127.0.0.1:\(server.port)/a\">".data(using: .utf16)!.write(to: f)
    setxattr(f.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0)
    let pane = HTMLPane(scripts: false)
    pane.show(f, over: web)
    spin(2)
    check("downloaded, no connection: a UTF-16 document", server.hits == 0, "hits \(server.hits)")
    pane.close()
}

// A downloaded page keeps its look: a stylesheet beside it is inlined (a <link> is never kept), and its remote @import dropped.
do {
    let server = Server()
    try! Data("@import url(http://127.0.0.1:\(server.port)/x.css);\np { color: rgb(1, 2, 3) }".utf8).write(to: dir.appendingPathComponent("look.css"))
    let f = dir.appendingPathComponent("styled.html")
    try! Data(#"<link rel="stylesheet" href="look.css"><p id=p>styled</p>"#.utf8).write(to: f)
    setxattr(f.path, "com.apple.quarantine", flag, flag.utf8.count, 0, 0)
    let pane = HTMLPane(scripts: false)
    pane.show(f, over: web)
    for _ in 0..<150 where pane.view.url == nil { spin(0.02) }
    spin(1)
    var color: String?, done = false
    pane.view.evaluateJavaScript("getComputedStyle(document.getElementById('p')).color") { r, _ in color = r as? String; done = true }
    for _ in 0..<100 where !done { spin(0.02) }
    check("downloaded: its stylesheet beside it applies, and nothing is fetched", color == "rgb(1, 2, 3)" && server.hits == 0, "\(color ?? "nil") hits \(server.hits)")
    pane.close()
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
