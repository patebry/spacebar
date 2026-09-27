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
check("a missing file is not downloaded", !HTMLPane.isDownloaded(dir.appendingPathComponent("nope.html")))

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
scripted.close()
closed.close()
check("close: both panes leave the container", container.subviews == [web])

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of the") HTML view checks")
exit(failures == 0 ? 0 : 1)
