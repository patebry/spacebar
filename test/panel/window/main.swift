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
let viewer = Viewer.shared
let panel = viewer.panel
OffScreen.keepDrawing(WebHost.shared.web)

spin(until: 15) { WebHost.shared.ready }
guard WebHost.shared.ready else { print("FAIL window: the page never became ready"); exit(1) }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let notes = dir.appendingPathComponent("Notes.md"), other = dir.appendingPathComponent("Other.md")
try! "# Notes\n\nSome text.\n".write(to: notes, atomically: true, encoding: .utf8)
try! "# Other\n\nMore text.\n".write(to: other, atomically: true, encoding: .utf8)

var shown = 0
func show(_ url: URL) {
    shown += 1
    let id = shown
    viewer.show([url.path], requestID: id) { _ in }
    spin(until: 5) { panel.isVisible && panel.alphaValue == 1 }
    spin(0.5)
}

show(notes)
check("shown at the frame it was given", panel.isVisible && panel.frame == first, panel.frame)
let sizing = (panel.contentView?.constraints ?? []).filter { ($0.identifier ?? "").hasPrefix("NSViewController.preferredContentSize") }
check("the content view has no preferred-size constraints", sizing.isEmpty, sizing)
check("the window is named for VoiceOver by the file shown", panel.title == "Notes.md", panel.title)
let closeB = panel.standardWindowButton(.closeButton)!, mini = panel.standardWindowButton(.miniaturizeButton)!, zoom = panel.standardWindowButton(.zoomButton)!
check("minimize, which the panel cannot do, is hidden", mini.isHidden && !closeB.isHidden && !zoom.isHidden)
check("zoom sits where minimize was", abs(zoom.frame.minX - mini.frame.minX) < 0.5 && zoom.frame.minX > closeB.frame.maxX, (closeB.frame, zoom.frame))
if let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(panel.windowNumber), [.boundsIgnoreFraming]) {
    let rep = NSBitmapImageRep(cgImage: img), c = closeB.convert(closeB.bounds, to: nil), scale = CGFloat(rep.pixelsWide) / panel.frame.width
    let px = rep.colorAt(x: Int(c.midX * scale), y: Int((panel.frame.height - c.midY) * scale))?.usingColorSpace(.sRGB)
    check("the close button is drawn red, not inactive grey", px.map { $0.redComponent > 0.7 && $0.greenComponent < 0.55 } == true, px ?? "no pixel")
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
    WebHost.shared.web.evaluateJavaScript(source) { r, _ in out = r; done = true }
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

/// The middle of the panel's content, global from the top left of the main display, as the tap reads a pointer.
func panelMiddle() -> CGPoint {
    let top = NSScreen.screens.first!.frame.maxY, f = panel.frame
    return CGPoint(x: f.midX, y: top - (f.minY + f.height * 0.45))
}
func gestureEvent(_ subtype: Int64, phase: Int64, value: Double = 0) -> CGEvent {
    let e = CGEvent(source: nil)!
    e.type = CGEventType(rawValue: 29)!
    e.setIntegerValueField(CGEventField(rawValue: 110)!, value: subtype)
    e.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
    e.setIntegerValueField(CGEventField(rawValue: 132)!, value: phase)
    e.location = panelMiddle()
    return e
}
func pinchIn() {
    let events = [gestureEvent(8, phase: 1)] + (0..<5).map { _ in gestureEvent(8, phase: 2, value: 0.1) } + [gestureEvent(8, phase: 4)]
    for e in events { viewer.gesture(e.data! as Data); spin(0.02) }
    spin(0.5)
}
func pdfView(_ v: NSView?) -> PDFView? {
    guard let v else { return nil }
    if let p = v as? PDFView, !p.isHidden { return p }
    for s in v.subviews { if let p = pdfView(s) { return p } }
    return nil
}

for (url, n) in [(png, "a PNG (the page's own image view)"), (heic, "a HEIC (ImagePane)")] {
    show(url)
    spin(until: 3) { zoomLabel() > 0 }
    let before = zoomLabel()
    pinchIn()
    let after = zoomLabel()
    check("a pinch handed over by the helper zooms \(n)", before > 0 && after > before, "\(before)% -> \(after)%")
}
show(pdf)
spin(until: 3) { pdfView(panel.contentView) != nil }
let pv = pdfView(panel.contentView)
let scaleBefore = pv?.scaleFactor ?? 0
pinchIn()
let scaleAfter = pv?.scaleFactor ?? 0
check("a pinch handed over by the helper zooms a PDF", pv != nil && scaleAfter > scaleBefore * 1.05, "\(scaleBefore) -> \(scaleAfter)")
viewer.close()
spin(0.5)
let closedLabel = zoomLabel()
pinchIn()
check("a gesture with the panel closed changes nothing", zoomLabel() == closedLabel)

print(failures == 0 ? "panel window: all passed" : "panel window: \(failures) failed")
exit(failures == 0 ? 0 : 1)
