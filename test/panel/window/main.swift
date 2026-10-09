// The Space panel as a real window, parked off screen (test/offscreen.swift): the frame it is given is the frame it keeps, through
// showing a file, layout, closing and opening again. A preferred content size on the panel's controller once overrode every frame
// (AppKit turns it into constraints at priority 501), so remembered sizes and the default placement never applied. Then pinches
// as the helper hands them over.
import Cocoa
import ImageIO
import PDFKit
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> Any = "") {
    print("\(ok ? "PASS" : "FAIL") window: \(name)\(ok ? "" : " \(detail())")")
    if !ok { failures += 1 }
    fflush(stdout)
}
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) } }
func spin(until s: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(s); while !done() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }

WebHost.pageHost = "panel"
_ = NSApplication.shared
OffScreen.install()
NSApp.setActivationPolicy(.accessory)
let first = NSRect(x: -20000, y: -20000, width: 1000, height: 600)
Viewer.parkedFrame = first
Viewer.activates = false
Viewer.shared.started = true
let viewer = Viewer.shared
/// The spare a Space opens in, kept first among the spares, so every Space here reuses it.
let win = viewer.freshWindow()
let panel = win.panel
OffScreen.keepDrawing(win.host.web)

spin(until: 15) { win.host.ready }
guard win.host.ready else { print("FAIL window: the page never became ready"); exit(1) }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let notes = dir.appendingPathComponent("Notes.md"), other = dir.appendingPathComponent("Other.md")
try! "# Notes\n\nSome text.\n".write(to: notes, atomically: true, encoding: .utf8)
try! "# Other\n\nMore text.\n".write(to: other, atomically: true, encoding: .utf8)

var shown = 0
func show(_ url: URL) {
    shown += 1
    let id = shown
    // A Space when closed; with the window open, Finder's selection moving to the file, which it follows.
    if viewer.current === win, win.open { viewer.show([url.path], requestID: id) { _ in } } else { viewer.open([url.path], requestID: id) { _ in } }
    spin(until: 5) { panel.isVisible && panel.alphaValue == 1 }
    spin(0.5)
}

show(notes)
check("shown at the frame it was given", panel.isVisible && panel.frame == first, panel.frame)
let sizing = (panel.contentView?.constraints ?? []).filter { ($0.identifier ?? "").hasPrefix("NSViewController.preferredContentSize") }
check("the content view has no preferred-size constraints", sizing.isEmpty, sizing)
check("the window is named for VoiceOver by the file shown", panel.title == "Notes.md", panel.title)
let closeB = panel.standardWindowButton(.closeButton)!, mini = panel.standardWindowButton(.miniaturizeButton)!, zoom = panel.standardWindowButton(.zoomButton)!
check("close, minimize and zoom are all shown", !mini.isHidden && !closeB.isHidden && !zoom.isHidden)
check("the lights in order: close, minimize, zoom", mini.frame.minX > closeB.frame.maxX && zoom.frame.minX > mini.frame.maxX, (closeB.frame, mini.frame, zoom.frame))
if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) {
    let rep = NSBitmapImageRep(cgImage: img), c = closeB.convert(closeB.bounds, to: nil), scale = CGFloat(rep.pixelsWide) / panel.frame.width
    let px = rep.colorAt(x: Int(c.midX * scale), y: Int((panel.frame.height - c.midY) * scale))?.usingColorSpace(.sRGB)
    // Opened by a Space, the window is not key (Finder keeps the keyboard), so its lights are drawn inactive, as any
    // background window's are.
    check("not key: the close button is drawn inactive grey", !panel.isKeyWindow && px.map { abs($0.redComponent - $0.greenComponent) < 0.1 } == true, px ?? "no pixel")
} else {
    print("SKIP window: no window image (screen recording not allowed?): light colour not checked")
}
if let dir = ProcessInfo.processInfo.environment["PANEL_SHOTS"],
   let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) {
    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent("panel.png"))
}
spin(1)
check("still that frame after layout and a second", panel.frame == first, panel.frame)

let resized = NSRect(x: -20000, y: -20000, width: 1180, height: 640)
panel.setFrame(resized, display: true)
spin(0.5)
check("a resize while open holds", panel.frame == resized, panel.frame)
show(other)
check("showing another file keeps the resized frame", panel.frame == resized, panel.frame)
check("the title follows the file", panel.title == "Other.md", panel.title)

viewer.close()
spin(0.5)
check("closed", !panel.isVisible)
let next = NSRect(x: -21000, y: -20500, width: 860, height: 540)
Viewer.parkedFrame = next
show(notes)
check("opened again at the new frame, not the controller's size", panel.frame == next, panel.frame)
viewer.close()
spin(0.3)

// A pinch on the trackpad, as the helper's tap takes it from Finder and hands it over (Viewer.gesture): the window server's
// gesture events, at a global point over the panel, never through NSApp.sendEvent, which drops them in an app that is not active.
func js(_ source: String) -> Any? {
    var out: Any?, done = false
    win.host.web.evaluateJavaScript(source) { r, _ in out = r; done = true }
    spin(until: 3) { done }
    return out
}
func zoomLabel() -> Int { Int(((js("(document.querySelector('#kind .img-zoom') || {}).textContent || ''") as? String) ?? "").dropLast()) ?? -1 }
func picture(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    return ctx.makeImage()!
}
let png = dir.appendingPathComponent("large.png"), heic = dir.appendingPathComponent("large.heic"), pdf = dir.appendingPathComponent("doc.pdf")
let pngOut = CGImageDestinationCreateWithURL(png as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(pngOut, picture(4000, 3000), nil)
CGImageDestinationFinalize(pngOut)
let sips = Process()
sips.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
sips.arguments = ["-s", "format", "heic", png.path, "--out", heic.path]
sips.standardOutput = FileHandle.nullDevice
try! sips.run()
sips.waitUntilExit()
var box = CGRect(x: 0, y: 0, width: 612, height: 792)
let pdfCtx = CGContext(pdf as CFURL, mediaBox: &box, nil)!
for _ in 0..<2 {
    pdfCtx.beginPDFPage(nil)
    pdfCtx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1))
    pdfCtx.fill(CGRect(x: 72, y: 72, width: 468, height: 648))
    pdfCtx.endPDFPage()
}
pdfCtx.closePDF()

/// `p` in the panel, global from the top left of the main display, as the tap reads a pointer.
func global(_ p: NSPoint) -> CGPoint {
    let top = NSScreen.screens.first!.frame.maxY, f = panel.frame
    return CGPoint(x: f.minX + p.x, y: top - (f.minY + p.y))
}
func gestureEvent(_ subtype: Int64, at p: NSPoint, phase: Int64, value: Double = 0) -> CGEvent {
    let e = CGEvent(source: nil)!
    e.type = CGEventType(rawValue: 29)!
    e.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
    e.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
    e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    e.location = global(p)
    return e
}
func pinchIn(at p: NSPoint) {
    let events = [gestureEvent(8, at: p, phase: 1)] + (0..<5).map { _ in gestureEvent(8, at: p, phase: 2, value: 0.15) } + [gestureEvent(8, at: p, phase: 4)]
    for e in events { viewer.gesture(e.data! as Data); spin(0.02) }
    spin(0.6)
}
func find<T: NSView>(_ type: T.Type, in v: NSView?) -> T? {
    guard let v, !v.isHidden else { return nil }
    if let t = v as? T { return t }
    for s in v.subviews { if let t = find(type, in: s) { return t } }
    return nil
}
/// A point a quarter of the way in from the left and from the top of `r`: off centre both ways, so a pinch anchored at the
/// wrong place (a flipped y) moves what is under it.
func upperLeft(_ r: NSRect) -> NSPoint { NSPoint(x: r.minX + r.width * 0.25, y: r.maxY - r.height * 0.25) }
/// The pinch zoomed about the pointer: what was under it (as a fraction of the image or page) still is.
func anchored(_ n: String, _ before: CGPoint?, _ after: CGPoint?) {
    guard let b = before, let a = after else { return check("\(n): pinch zooms about the pointer", false, "no point read") }
    check("\(n): pinch zooms about the pointer", hypot(a.x - b.x, a.y - b.y) < 0.03, "\(b) -> \(a)")
}

// The page's own image view: the point under the pointer as a fraction of the <img>'s box.
show(png)
spin(until: 3) { zoomLabel() > 0 }
let web = win.host.web
func imgBox() -> CGRect? {
    guard let r = js("(() => { const i = document.querySelector('#doc .img-stage img'); if (!i) return null; const b = i.getBoundingClientRect(); return [b.left, b.top, b.width, b.height]; })()") as? [Double], r.count == 4 else { return nil }
    return CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
}
func cssPoint(_ p: NSPoint) -> CGPoint {
    let v = web.convert(p, from: nil), z = web.pageZoom
    return CGPoint(x: v.x / z, y: (web.isFlipped ? v.y : web.bounds.height - v.y) / z)
}
func windowPoint(css c: CGPoint) -> NSPoint {
    let z = web.pageZoom
    return web.convert(NSPoint(x: c.x * z, y: web.isFlipped ? c.y * z : web.bounds.height - c.y * z), to: nil)
}
func imgFraction(_ p: NSPoint) -> CGPoint? {
    guard let b = imgBox(), b.width > 0 else { return nil }
    let c = cssPoint(p)
    return CGPoint(x: (c.x - b.minX) / b.width, y: (c.y - b.minY) / b.height)
}
if let box = imgBox() {
    let at = windowPoint(css: CGPoint(x: box.minX + box.width * 0.25, y: box.minY + box.height * 0.25))
    let before = zoomLabel(), sent = win.gesturesSent, under = imgFraction(at)
    pinchIn(at: at)
    check("a pinch handed over by the helper zooms a PNG (the page's own image view)", before > 0 && zoomLabel() > before, "\(before)% -> \(zoomLabel())%")
    check("each event of the pinch reached the open panel", win.gesturesSent - sent == 7, "\(win.gesturesSent - sent)")
    anchored("a PNG", under, imgFraction(at))
} else {
    check("a PNG: the image's box", false, "no #doc .img-stage img")
}

// ImagePane: the point under the pointer as a fraction of the image view's document.
show(heic)
spin(until: 3) { zoomLabel() > 0 && find(ImageScrollView.self, in: panel.contentView) != nil }
if let sv = find(ImageScrollView.self, in: panel.contentView), let doc = sv.documentView {
    let shown = doc.convert(doc.bounds, to: nil).intersection(sv.convert(sv.bounds, to: nil))
    let at = upperLeft(shown)
    func fraction() -> CGPoint { let d = doc.convert(at, from: nil); return CGPoint(x: d.x / doc.bounds.width, y: d.y / doc.bounds.height) }
    let before = zoomLabel(), under = fraction()
    pinchIn(at: at)
    check("a pinch handed over by the helper zooms a HEIC (ImagePane)", before > 0 && zoomLabel() > before, "\(before)% -> \(zoomLabel())%")
    anchored("a HEIC", under, fraction())
} else {
    check("a HEIC: the native image view", false, "no ImageScrollView")
}

// PDFView zooms about a point of its own choosing, not the pointer, so only the zoom is checked.
show(pdf)
spin(until: 3) { find(PDFView.self, in: panel.contentView) != nil }
let pv = find(PDFView.self, in: panel.contentView)
var scaleOpen = 0.0
if let pv {
    let at = upperLeft(pv.convert(pv.bounds, to: nil))
    let scaleBefore = pv.scaleFactor
    pinchIn(at: at)
    scaleOpen = pv.scaleFactor
    check("a pinch handed over by the helper zooms a PDF", scaleOpen > scaleBefore * 1.05, "\(scaleBefore) -> \(scaleOpen)")
} else {
    check("a PDF: the native PDF view", false, "no PDFView")
}
viewer.close()
spin(0.5)
let sentClosed = win.gesturesSent
pinchIn(at: NSPoint(x: panel.frame.width / 2, y: panel.frame.height / 2))
check("a gesture with the panel closed reaches nothing", win.gesturesSent == sentClosed && (pv?.scaleFactor ?? 0) == scaleOpen,
      "\(win.gesturesSent - sentClosed) sent, scale \(scaleOpen) -> \(pv?.scaleFactor ?? 0)")

// A file opened from Finder or another app (Viewer.openDocuments): its own window, which the helper never follows.
show(notes)
for w in viewer.windows { OffScreen.keepDrawing(w.host.web) }
viewer.openDocuments([other])
spin(until: 5) { viewer.windows.contains { $0.document && $0.open && $0.panel.alphaValue == 1 } }
let docWin = viewer.windows.first { $0.document }
check("a document opens in a window of its own", docWin.map { $0.open && $0 !== win } == true)
check("the helper still follows the window it opened, not the document's", viewer.current === win && win.open)
spin(0.5)
let count = viewer.windows.count
viewer.openDocuments([other])
spin(0.5)
check("the same document again reuses its window", viewer.windows.count == count && viewer.windows.filter { $0.document }.count == 1 && docWin?.open == true,
      "\(count) -> \(viewer.windows.count)")
viewer.openDocuments([URL(string: "https://example.com/a.md")!])
spin(0.3)
check("a URL that is not a file opens nothing", viewer.windows.filter { $0.document }.count == 1)
docWin?.panel.performClose(nil)
spin(0.5)
check("closed, the document window is no longer one", docWin.map { !$0.open && !$0.document } == true)
check("closing it leaves the helper's window open", viewer.current === win && win.open)
viewer.close()
spin(0.3)

// A document the viewer declines (a package) goes to the app it would open in without spacebar, never to nothing.
var handed: [URL] = []
Viewer.handOff = { handed.append($0) }
let pkg = dir.appendingPathComponent("Thing.app")
try! FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
viewer.openDocuments([pkg])
spin(until: 5) { !handed.isEmpty }
check("a declined document is handed to another app", handed.map(\.path) == [pkg.path], handed)
check("and leaves no window of its own", !viewer.windows.contains { $0.document || $0.request < 0 })

// Files opened together cascade, each window on a frame of its own.
let a = dir.appendingPathComponent("A.md"), b = dir.appendingPathComponent("B.md")
try! "# A\n".write(to: a, atomically: true, encoding: .utf8)
try! "# B\n".write(to: b, atomically: true, encoding: .utf8)
viewer.openDocuments([a, b])
let pair = viewer.windows.filter { $0.request < 0 }
check("two documents opened together get different frames", pair.count == 2 && pair[0].panel.frame.origin != pair[1].panel.frame.origin,
      pair.map(\.panel.frame))
for w in pair { w.panel.performClose(nil) }
spin(0.5)

print(failures == 0 ? "panel window: all passed" : "panel window: \(failures) failed")
exit(failures == 0 ? 0 : 1)
