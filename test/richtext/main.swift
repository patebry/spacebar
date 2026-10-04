import AppKit
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

_ = NSApplication.shared
OffScreen.install()
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let fm = FileManager.default

// Fixtures: an RTF with a heading, a link and black text; an RTFD package and a flattened RTFD; an .rtf that is really HTML.
let body = NSMutableAttributedString(string: "Quarterly notes\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 22), .foregroundColor: NSColor.black])
body.append(NSAttributedString(string: "Plain black text on a white page. ", attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.black]))
body.append(NSAttributedString(string: "A link", attributes: [.link: URL(string: "https://example.com/rtf")!, .font: NSFont.systemFont(ofSize: 14)]))
body.append(NSAttributedString(string: "\n" + String(repeating: "More lines of the document.\n", count: 200), attributes: [.font: NSFont.systemFont(ofSize: 14)]))
let rtf = dir.appendingPathComponent("notes.rtf")
try! body.rtf(from: NSRange(location: 0, length: body.length), documentAttributes: [:])!.write(to: rtf)
let pkg = dir.appendingPathComponent("pack.rtfd")
try! body.fileWrapper(from: NSRange(location: 0, length: body.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
    .write(to: pkg, options: [], originalContentsURL: nil)
let flat = dir.appendingPathComponent("flat.rtfd")
try! body.rtfd(from: NSRange(location: 0, length: body.length), documentAttributes: [:])!.write(to: flat)
let fake = dir.appendingPathComponent("fake.rtf")
try! Data("<html><body><script>window.x=1</script><img src=\"https://example.com/beacon.png\">hi</body></html>".utf8).write(to: fake)

// ---- which files come here: the kind, the sidebar icon, and the view FileView asks for ----
check("kind: .rtf, an .rtfd package and a flattened .rtfd are rich text, with the text icon",
      FileTypes.kind(name: "a.rtf") == .rtf && FileTypes.kind(name: "A.RTF") == .rtf && FileTypes.kind(name: "d.rtfd", isDirectory: true, isPackage: true) == .rtf
      && FileTypes.kind(name: "f.rtfd") == .rtf && FileKind.rtf.icon == "text")
let listing = FolderListing.list(dir.path, sort: "name", readmeFirst: false)
check("sidebar: the RTFD package is one item, not a folder, listed as rich text",
      listing.entries.first { $0.name == "pack.rtfd" }.map { !$0.isDirectory && $0.kind == .rtf } == true)
for (u, name) in [(rtf, "RTF"), (pkg, "RTFD package"), (flat, "flattened RTFD")] {
    let p = FileView.payload(path: u.path, kind: .rtf, root: dir.path, reason: "open", canOpen: true)
    check("payload: \(name) gets the native rich text view, never the source view", p["view"] as? String == "rtf" && p["text"] == nil, "\(p["view"] ?? "nil")")
}
let big = dir.appendingPathComponent("big.rtf")
fm.createFile(atPath: big.path, contents: nil)
truncate(big.path, off_t(FolderListing.maxDocumentBytes + 1))
check("payload: an RTF over 64 MB is its info card", FileView.payload(path: big.path, kind: .rtf, root: dir.path, reason: "open", canOpen: true)["view"] as? String == "info")

// ---- open(): AppKit's RTF reader, and nothing else ----
guard case .success(let a) = RichTextPane.open(rtf) else { fatalError("notes.rtf did not open") }
check("open: RTF keeps its text, fonts and link", a.string.hasPrefix("Quarterly notes") && a.string.contains("A link")
      && (a.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 22
      && a.attribute(.link, at: (a.string as NSString).range(of: "A link").location, effectiveRange: nil) != nil)
if case .success(let p) = RichTextPane.open(pkg) { check("open: an RTFD package", p.string.hasPrefix("Quarterly notes")) } else { check("open: an RTFD package", false) }
if case .success(let p) = RichTextPane.open(flat) { check("open: a flattened RTFD", p.string.hasPrefix("Quarterly notes")) } else { check("open: a flattened RTFD", false) }
if case .failure(.unreadable) = RichTextPane.open(fake) { check("open: an .rtf that is HTML is refused, never parsed as a web page", true) }
else { check("open: an .rtf that is HTML is refused, never parsed as a web page", false) }
if case .failure(.tooLarge) = RichTextPane.open(big) { check("open: past 64 MB is refused before reading", true) } else { check("open: past 64 MB is refused before reading", false) }
if case .failure = RichTextPane.open(dir.appendingPathComponent("gone.rtf")) { check("open: a missing file", true) } else { check("open: a missing file", false) }

// ---- the pane in an off-screen window above a WKWebView, as in the extension ----
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
let web = WKWebView(frame: container.bounds)
web.autoresizingMask = [.width, .height]
container.addSubview(web)
window.contentView = container
window.orderBack(nil)

let pane = RichTextPane()
/// The pane's find, which may answer later: waits up to 5 s for it.
func findNow(_ q: String) -> Int {
    var n: Int?
    pane.find(q) { n = $0 }
    let end = Date().addingTimeInterval(5)
    while n == nil, Date() < end { spin(0.02) }
    return n ?? -1
}
var links: [URL] = []
pane.onLink = { links.append($0) }
pane.show(a, path: rtf.path)
check("show: not in the container until the page places it, hidden", pane.view.superview == nil && pane.view.isHidden && !pane.placed)
check("show: read-only and selectable, no editing aids", !pane.textView.isEditable && pane.textView.isSelectable && !pane.textView.importsGraphics
      && !pane.textView.isAutomaticLinkDetectionEnabled && pane.textView.string.hasPrefix("Quarterly notes"))
let msg: [String: Any] = ["path": rtf.path, "x": 240, "y": 108, "w": 760, "h": 692, "hide": false, "bg": [250, 250, 250], "dark": false]
pane.place(message: ["path": pkg.path, "x": 0, "y": 0, "w": 10, "h": 10], in: web)
check("place: a message for another file is ignored", pane.view.isHidden && !pane.placed)
pane.place(message: msg, in: web)
spin(0.2)
check("place: at the page's area, above the web view", !pane.view.isHidden && pane.placed && pane.view.frame == NSRect(x: 240, y: 0, width: 760, height: 692)
      && pane.view.superview === container && container.subviews.last === pane.view, "\(pane.view.frame)")
check("place: the text wraps to the view's width and scrolls", abs(pane.textView.frame.width - pane.view.contentSize.width) < 1
      && pane.textView.frame.height > pane.view.contentSize.height, "\(pane.textView.frame) in \(pane.view.contentSize)")
check("place: starts at the top", pane.view.contentView.bounds.origin.y == 0)

/// The mean brightness of the text view as drawn, and of its darkest pixels (the text).
func shot() -> (mean: Double, ink: Double) {
    let v = pane.view
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    var sum = 0.0, n = 0.0, lum: [Double] = []
    for y in stride(from: 0, to: rep.pixelsHigh / 3, by: 2) { for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        let l = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        sum += l; n += 1; lum.append(l)
    } }
    lum.sort()
    return (sum / max(n, 1), lum[lum.count / 400])
}
let light = shot()
check("light: a light page with dark text", light.mean > 0.85 && light.ink < 0.3, "\(light)")
pane.place(message: msg.merging(["dark": true, "bg": [30, 30, 32]]) { _, n in n }, in: web)
spin(0.2)
let dark = shot()
check("dark: the theme's dark background, and the document's black text mapped light", pane.view.appearance?.name == .darkAqua
      && dark.mean < 0.35 && lum(pane.textView) && dark.ink < 0.2, "\(dark)")
func lum(_ t: NSTextView) -> Bool { t.usesAdaptiveColorMappingForDarkAppearance }
// The brightest pixels are the text: in dark mode, light text on the dark background.
func brightest() -> Double {
    let v = pane.view
    let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
    v.cacheDisplay(in: v.bounds, to: rep)
    var best = 0.0
    for y in stride(from: 0, to: rep.pixelsHigh / 3, by: 1) { for x in stride(from: 0, to: rep.pixelsWide / 2, by: 1) {
        guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
        best = max(best, 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent)
    } }
    return best
}
check("dark: black text is drawn light", brightest() > 0.7, "\(brightest())")
pane.place(message: msg, in: web)

pane.view.contentView.scroll(to: NSPoint(x: 0, y: 900))
pane.view.reflectScrolledClipView(pane.view.contentView)
guard case .success(let a2) = RichTextPane.open(rtf) else { fatalError() }
pane.show(a2, path: rtf.path)
check("reload of the same file keeps the place on screen", abs(pane.view.contentView.bounds.origin.y - 900) < 1, "\(pane.view.contentView.bounds.origin.y)")
guard case .success(let b) = RichTextPane.open(pkg) else { fatalError() }
pane.show(b, path: pkg.path)
check("another file starts at the top", pane.view.contentView.bounds.origin.y == 0)
pane.place(message: ["path": pkg.path, "hide": true], in: web)
check("hide alone: hidden, text kept", pane.view.isHidden && pane.textView.string.hasPrefix("Quarterly"))
pane.place(message: msg.merging(["path": pkg.path]) { _, n in n }, in: web)

let at = (pane.textView.string as NSString).range(of: "A link").location
_ = pane.textView(pane.textView, clickedOnLink: URL(string: "https://example.com/rtf")!, at: at)
_ = pane.textView(pane.textView, clickedOnLink: "https://example.com/s" as NSString, at: at)
check("a link goes to the owner (which applies the PDF link policy), never to NSWorkspace",
      links == [URL(string: "https://example.com/rtf")!, URL(string: "https://example.com/s")!] && pane.textView(pane.textView, clickedOnLink: 5, at: 0))

// ---- the panel's keys: find, ⌘C of the selection, zoom, paging, and a reading width on a wide panel ----
let n = findNow("quarterly")
check("find: case-insensitive, the first match selected", n >= 1 && pane.selectedText?.lowercased() == "quarterly", "\(n) \(pane.selectedText ?? "nil")")
pane.findClear()
check("find: nothing for a word not there", findNow("zzzabsent") == 0)
pane.textView.setSelectedRange(NSRange(location: 0, length: 9))
check("selection: the selected text is what ⌘C copies", pane.selectedText == "Quarterly")
pane.zoom("zoomIn")
check("zoom: ⌘+ magnifies the document", pane.view.magnification > 1.05, "\(pane.view.magnification)")
pane.zoom("zoomReset")
check("zoom: ⌘0 back to its size", abs(pane.view.magnification - 1) < 0.001)
check("paging: Page Down, Home and End move the text; arrows do not", pane.scrollKey("pagedown") && pane.scrollKey("home") && pane.scrollKey("end") && !pane.scrollKey("down"))
pane.place(message: msg.merging(["x": 0, "w": 1000, "path": pane.path!]) { _, n in n }, in: web)
check("reading width: on a wide panel the text is centred at a comfortable measure",
      pane.textView.textContainerInset.width > RichTextPane.inset.width && abs(pane.textView.textContainer!.size.width - RichTextPane.measure) < 2,
      "\(pane.textView.textContainerInset) \(pane.textView.textContainer!.size)")
pane.place(message: msg, in: web)

pane.close()
check("close: removed from the container, hidden, forgotten", pane.view.superview == nil && pane.view.isHidden && pane.path == nil && !pane.placed
      && container.subviews == [web] && pane.textView.string.isEmpty)
pane.place(message: msg, in: web)
check("close: a late message does not bring it back", pane.view.superview == nil && pane.view.isHidden)

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of the") rich text view checks")
exit(failures == 0 ? 0 : 1)
