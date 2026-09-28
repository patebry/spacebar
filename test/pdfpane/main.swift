import AppKit
import PDFKit
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

final class Flipped: NSView { override var isFlipped: Bool { true } }

func makePDF(_ url: URL, pages: Int) {
    var box = CGRect(x: 0, y: 0, width: 300, height: 400)
    let ctx = CGContext(url as CFURL, mediaBox: &box, nil)!
    for i in 0..<pages {
        ctx.beginPDFPage(nil)
        ctx.setFillColor(CGColor(red: 0, green: 0.2, blue: 1, alpha: 1))
        ctx.fill(box)
        let text = NSAttributedString(string: "Page \(i + 1)", attributes: [.font: NSFont.systemFont(ofSize: 24), .foregroundColor: NSColor.white])
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        text.draw(at: NSPoint(x: 40, y: 200))
        ctx.endPDFPage()
    }
    ctx.closePDF()
}

func openDescriptors(_ path: String) -> Int {
    var n = 0, buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    for fd in 0..<getdtablesize() where fcntl(fd, F_GETPATH, &buf) != -1 && String(cString: buf) == path { n += 1 }
    return n
}

_ = NSApplication.shared
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let a = dir.appendingPathComponent("a.pdf"), b = dir.appendingPathComponent("b.pdf"), bad = dir.appendingPathComponent("bad.pdf")
makePDF(a, pages: 3)
makePDF(b, pages: 1)
try! Data("%PDF-1.4\nnothing here\n".utf8).write(to: bad)

// ---- frame(css:in:zoom:): CSS pixels from the viewport's top left to the container's coordinates ----
let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
let plain = NSView(frame: host.bounds), flipped = Flipped(frame: host.bounds)
host.addSubview(plain)
check("frame: unflipped web view, y measured from the top", PDFPane.frame(css: CGRect(x: 240, y: 100, width: 760, height: 700), in: plain, zoom: 1)
      == NSRect(x: 240, y: 0, width: 760, height: 700))
plain.removeFromSuperview()
host.addSubview(flipped)
check("frame: flipped web view", PDFPane.frame(css: CGRect(x: 240, y: 100, width: 760, height: 700), in: flipped, zoom: 1)
      == NSRect(x: 240, y: 0, width: 760, height: 700))
check("frame: page zoom scales CSS pixels", PDFPane.frame(css: CGRect(x: 100, y: 50, width: 200, height: 100), in: flipped, zoom: 2)
      == NSRect(x: 200, y: 500, width: 400, height: 200))
check("frame: clipped to the web view", PDFPane.frame(css: CGRect(x: 900, y: 700, width: 500, height: 500), in: flipped, zoom: 1)
      == NSRect(x: 900, y: 0, width: 100, height: 100))
check("frame: empty, off-view or non-finite rects give nothing",
      [CGRect(x: 0, y: 0, width: 0, height: 10), CGRect(x: 2000, y: 0, width: 10, height: 10), CGRect(x: CGFloat.nan, y: 0, width: 10, height: 10),
       CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 10)].allSatisfy { PDFPane.frame(css: $0, in: flipped, zoom: 1) == nil })
let loose = NSView(frame: host.bounds)
check("frame: a web view outside any container gives nothing", PDFPane.frame(css: CGRect(x: 0, y: 0, width: 10, height: 10), in: loose, zoom: 1) == nil)

// ---- open(): PDFKit's document, or why not ----
if case .failure(.unreadable) = PDFPane.open(bad) { check("open: a file PDFKit cannot parse is refused", true) } else { check("open: a file PDFKit cannot parse is refused", false) }
guard case .success(let docA) = PDFPane.open(a) else { fatalError("a.pdf did not open") }
check("open: a PDF opens with its pages", docA.pageCount == 3 && docA.page(at: 1)?.string?.contains("Page 2") == true)

// ---- the pane in a real (off-screen) window above a WKWebView, as in the extension ----
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
let web = WKWebView(frame: container.bounds)
web.autoresizingMask = [.width, .height]
container.addSubview(web)
window.contentView = container
window.orderBack(nil)

let pane = PDFPane()
var links: [URL] = []
pane.onLink = { links.append($0) }
pane.show(docA, path: a.path, over: web)
check("show: not in the container until the page places it, hidden",
      pane.view.superview == nil && pane.view.isHidden && !pane.placed)
check("show: fitted, continuous, vertical, with page breaks", pane.view.autoScales && pane.view.displayMode == .singlePageContinuous
      && pane.view.displayDirection == .vertical && pane.view.displaysPageBreaks)
let msg: [String: Any] = ["path": a.path, "x": 240, "y": 108, "w": 760, "h": 692, "hide": false, "bg": [240, 240, 242], "dark": false]
pane.place(message: ["path": b.path, "x": 0, "y": 0, "w": 10, "h": 10], in: web)
check("place: a message for another file is ignored", pane.view.isHidden && !pane.placed)
pane.place(message: msg, in: web)
check("place: at the page's area, above the web view", !pane.view.isHidden && pane.placed && pane.view.frame == NSRect(x: 240, y: 0, width: 760, height: 692)
      && pane.view.superview === container && container.subviews.last === pane.view, "\(pane.view.frame)")
spin(0.2)
/// Whether the top of the first page is on screen.
func atTop() -> Bool {
    guard let dv = pane.view.documentView, pane.view.currentPage.flatMap({ pane.view.document?.index(for: $0) }) == 0 else { return false }
    let vis = dv.visibleRect
    return dv.isFlipped ? vis.minY <= dv.bounds.minY + 30 : vis.maxY >= dv.bounds.maxY - 30
}
check("place: a new document opens at the top of its first page, not scrolled to its end", atTop(),
      "\(pane.view.documentView?.visibleRect ?? .zero) in \(pane.view.documentView?.bounds ?? .zero) page \(pane.view.currentPage.flatMap { pane.view.document?.index(for: $0) } ?? -1)")
let bg = pane.view.backgroundColor.usingColorSpace(.sRGB)!
check("place: the backdrop and appearance the page asks for", abs(bg.redComponent * 255 - 240) < 1 && abs(bg.blueComponent * 255 - 242) < 1
      && pane.view.appearance?.name == .aqua)
pane.place(message: msg.merging(["dark": true, "bg": [30, 30, 32]]) { _, n in n }, in: web)
check("place: dark", pane.view.appearance?.name == .darkAqua && pane.view.backgroundColor.usingColorSpace(.sRGB)!.redComponent < 0.2)
pane.place(message: msg.merging(["x": "240", "w": true]) { _, n in n }, in: web)
check("place: strings and booleans are not numbers", pane.view.frame == NSRect(x: 240, y: 0, width: 760, height: 692))

/// How far below the view's top edge the top of `page` sits, in page points (negative: cut off above the view).
func topGap(_ i: Int) -> CGFloat {
    let v = pane.view, page = v.document!.page(at: i)!
    let y = v.convert(NSPoint(x: 0, y: page.bounds(for: v.displayBox).maxY), from: page).y
    return ((v.isFlipped ? y - v.bounds.minY : v.bounds.maxY - y) / v.scaleFactor)
}
let wide = msg.merging(["x": 8, "w": 992]) { _, n in n }
let gap0 = topGap(0)
pane.place(message: wide, in: web)
spin(0.1)
check("width: at the top of the first page, the sidebar hiding keeps its top edge on screen", atTop() && topGap(0) >= 0 && abs(topGap(0) - gap0) < 2,
      "gap \(topGap(0)) was \(gap0)")
pane.place(message: msg, in: web)
spin(0.1)
check("width: and showing it again", atTop() && topGap(0) >= 0 && abs(topGap(0) - gap0) < 2, "gap \(topGap(0)) was \(gap0)")
let into = docA.page(at: 1)!
pane.view.go(to: PDFDestination(page: into, at: NSPoint(x: 0, y: into.bounds(for: pane.view.displayBox).maxY - 150)))
spin(0.1)
let mid = topGap(1)
for (label, m) in [("hidden", wide), ("shown", msg)] {
    pane.place(message: m, in: web)
    spin(0.1)
    check("width: part way down a page, the sidebar \(label) keeps the same line at the top",
          pane.view.currentPage.map { docA.index(for: $0) } == 1 && abs(topGap(1) - mid) < 2, "gap \(topGap(1)) was \(mid)")
}
pane.view.go(to: docA.page(at: 0)!)
spin(0.1)

window.setFrame(NSRect(x: -20000, y: -20000, width: 1200, height: 900), display: true)
container.frame = NSRect(x: 0, y: 0, width: 1200, height: 900)
check("resize: between messages the view keeps its margins, as the page's layout does",
      pane.view.frame == NSRect(x: 240, y: 0, width: 960, height: 792), "\(pane.view.frame)")
pane.place(message: msg.merging(["x": 0, "w": 1200, "h": 792]) { _, n in n }, in: web)
check("resize: the sidebar collapsing moves it to the edge", pane.view.frame == NSRect(x: 0, y: 0, width: 1200, height: 792))

pane.place(message: msg.merging(["hide": true]) { _, n in n }, in: web)
check("hide with a rect: hidden, document kept", pane.view.isHidden && pane.view.document === docA)
pane.place(message: msg, in: web)
pane.place(message: ["path": a.path, "hide": true], in: web)
check("hide alone: hidden, document kept", pane.view.isHidden && pane.view.document === docA)
pane.place(message: msg, in: web)

pane.view.go(to: docA.page(at: 2)!)
spin(0.1)
guard case .success(let docA2) = PDFPane.open(a) else { fatalError() }
pane.show(docA2, path: a.path, over: web)
spin(0.1)
check("reload of the same file keeps the page on screen", pane.view.document === docA2 && pane.view.currentPage.map { docA2.index(for: $0) } == 2,
      "\(pane.view.currentPage.map { docA2.index(for: $0) } ?? -1)")

pane.pdfViewWillClick(onLink: pane.view, with: URL(string: "https://example.com/x")!)
check("a link goes to the owner, never to NSWorkspace", links == [URL(string: "https://example.com/x")!])
check("links: web links pass the policy", PDFPane.linkRefusal(URL(string: "https://example.com/x")!) == nil && PDFPane.linkRefusal(URL(string: "HTTP://example.com")!) == nil)
check("links: file, javascript, mailto and other schemes are refused",
      [URL(fileURLWithPath: a.path), URL(string: "javascript:alert(1)")!, URL(string: "mailto:x@example.com")!, URL(string: "x-apple.systempreferences:")!,
       URL(string: "spacebar://file/etc/hosts")!].allSatisfy { PDFPane.linkRefusal($0) != nil })

// ---- teardown: the view leaves, the document is freed, no descriptor stays on the file ----
weak var weakB: PDFDocument?
autoreleasepool {
    guard case .success(let docB) = PDFPane.open(b) else { fatalError() }
    weakB = docB
    pane.show(docB, path: b.path, over: web)
}
spin(0.2)
autoreleasepool { pane.close() }
spin(0.3)
check("close: removed from the container, hidden, forgotten", pane.view.superview == nil && pane.view.isHidden && pane.path == nil && !pane.placed
      && !container.subviews.contains(pane.view) && container.subviews == [web])
check("close: the document is freed", weakB == nil && pane.view.document == nil)
check("close: no descriptor left on either file", openDescriptors(a.path) == 0 && openDescriptors(b.path) == 0)
pane.place(message: ["path": b.path, "x": 0, "y": 0, "w": 100, "h": 100], in: web)
check("close: a late message does not bring it back", pane.view.superview == nil && pane.view.isHidden)

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of the") PDF view checks")
exit(failures == 0 ? 0 : 1)
