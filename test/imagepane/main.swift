import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func spin(until: Double = 10, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { spin(0.02) } }

_ = NSApplication.shared
OffScreen.install()
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let sandboxed = ProcessInfo.processInfo.environment["IMAGEPANE_SANDBOX"] != nil

/// A `w`×`h` picture, left half red and right half blue, so a turn shows.
func picture(_ w: Int, _ h: Int) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.2, blue: 0.2, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
    ctx.setFillColor(CGColor(srgbRed: 0.2, green: 0.3, blue: 0.9, alpha: 1))
    ctx.fill(CGRect(x: w / 2, y: 0, width: w - w / 2, height: h))
    return ctx.makeImage()!
}

@discardableResult
func write(_ name: String, _ type: String, _ images: [CGImage], orientation: Int? = nil) -> URL {
    let url = dir.appendingPathComponent(name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
    for i in images { CGImageDestinationAddImage(d, i, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary }) }
    if !CGImageDestinationFinalize(d) { print("note: \(type) not written here") }
    return url
}

// The first run writes the fixtures; the sandboxed copy only reads them.
let formats: [(String, String)] = [("photo.heic", "public.heic"), ("scan.tiff", "public.tiff"), ("layers.psd", "com.adobe.photoshop-image"),
                                   ("render.exr", "com.ilm.openexr-image"), ("sprite.tga", "com.truevision.tga-image"), ("still.jp2", "public.jpeg-2000")]
if !sandboxed {
    for (name, type) in formats { write(name, type, [picture(120, 80)]) }
    write("turned.heic", "public.heic", [picture(120, 80)], orientation: 6)
    write("turned.tiff", "public.tiff", [picture(120, 80)], orientation: 8)
    write("app.icns", "com.apple.icns", [picture(16, 16), picture(128, 128), picture(32, 32)])
    write("large.tiff", "public.tiff", [picture(4000, 1000)])
    try! Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: dir.appendingPathComponent("junk.dng"))
    try! Data("not an image".utf8).write(to: dir.appendingPathComponent("fake.heic"))
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ff.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-i", dir.appendingPathComponent("scan.tiff").path, "-c:v", "libaom-av1",
                    "-still-picture", "1", dir.appendingPathComponent("web.avif").path]
    ff.standardError = FileHandle.nullDevice
    try? ff.run()
    ff.waitUntilExit()
}
let avif = FileManager.default.fileExists(atPath: dir.appendingPathComponent("web.avif").path)
let decodable = formats.map(\.0) + ["turned.heic", "turned.tiff", "app.icns", "large.tiff"] + (avif ? ["web.avif"] : [])

func loaded(_ name: String, maxSide: Int = ImagePane.screenPixels) -> ImagePane.Loaded? {
    if case .success(let l) = ImagePane.open(dir.appendingPathComponent(name), maxSide: maxSide) { return l }
    return nil
}

// ---- decoding ----
let bad = decodable.filter { loaded($0) == nil }
check("\(sandboxed ? "sandboxed with the extension's entitlements: " : "")ImageIO decodes HEIC, TIFF, PSD, EXR, TGA, JPEG 2000, ICNS\(avif ? ", AVIF" : "")",
      bad.isEmpty, "\(bad)")
if !avif { print("SKIP AVIF: no ffmpeg with libaom here to make one") }
if let l = loaded("photo.heic") { check("a HEIC decodes at its size, whole", l.size == CGSize(width: 120, height: 80) && !l.reduced && l.image.width == 120, "\(l.size)") }
if let a = loaded("turned.heic"), let b = loaded("turned.tiff") {
    check("EXIF orientation is applied: turned a quarter, 80 × 120, as decoded", a.size == CGSize(width: 80, height: 120) && a.image.width == 80
          && b.size == CGSize(width: 80, height: 120) && b.image.height == 120, "\(a.size) \(b.size)")
}
if let l = loaded("app.icns") { check("an icon file shows its largest size", l.size == CGSize(width: 128, height: 128), "\(l.size)") }
if let l = loaded("large.tiff"), let full = loaded("large.tiff", maxSide: ImagePane.maxPixels) {
    check("a large image is decoded screen-sized first, its full size kept for 100%", l.reduced && l.image.width == ImagePane.screenPixels
          && l.size == CGSize(width: 4000, height: 1000) && !full.reduced && full.image.width == 4000, "\(l.image.width) \(full.image.width)")
}
check("a damaged RAW and a text file named .heic are refused", loaded("junk.dng") == nil && loaded("fake.heic") == nil)
// A PNG header declaring 12,000 × 12,000 pixels (144 megapixels) and no data: refused from its properties, never decoded.
if !sandboxed {
    var ihdr = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13]) + Data("IHDR".utf8)
    ihdr += Data([0, 0, 0x2E, 0xE0, 0, 0, 0x2E, 0xE0, 8, 2, 0, 0, 0]) + Data([0, 0, 0, 0])
    try! ihdr.write(to: dir.appendingPathComponent("bomb.tiff"))
}
check("an image declaring more than 80 megapixels is refused before any decode", ImagePane.pixelSize(dir.appendingPathComponent("bomb.tiff")) == nil
      && loaded("bomb.tiff") == nil)
if sandboxed { exit(failures == 0 ? 0 : 1) }

// ---- routing: which images get the native view ----
func payload(_ name: String) -> [String: Any] {
    let path = dir.appendingPathComponent(name).path
    return FileView.payload(path: path, kind: FileTypes.kind(name: name), root: dir.path, reason: "open", canOpen: true)
}
let native = ["heic", "heif", "avif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2", "psd", "exr", "tga", "jp2", "icns"]
for ext in native where !FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.\(ext)").path) {
    try! Data([1, 2, 3]).write(to: dir.appendingPathComponent("x.\(ext)"))
}
let wrongNative = native.filter { FileTypes.kind(name: "x.\($0)") != .image || payload("x.\($0)")["view"] as? String != "bitmap" }
check("HEIC, AVIF, TIFF, RAW (dng cr2 cr3 nef arw orf raf rw2), PSD, EXR, TGA, JPEG 2000 and ICNS get the native view", wrongNative.isEmpty, "\(wrongNative)")
let web = ["png", "jpg", "jpeg", "gif", "webp", "svg", "bmp", "ico"]
for ext in web { try! Data([1, 2, 3]).write(to: dir.appendingPathComponent("w.\(ext)")) }
let wrongWeb = web.filter { payload("w.\($0)")["view"] as? String != "image" || (payload("w.\($0)")["src"] as? String)?.hasPrefix("spacebar://file/") != true }
check("PNG, JPEG, GIF, WebP, SVG, BMP and ICO stay <img> from the file host", wrongWeb.isEmpty, "\(wrongWeb)")
let rawServed = native.filter { ["dng", "cr2", "psd", "exr", "tga", "jp2", "icns"].contains($0) && FileTypes.contentType(forPath: "x.\($0)") != FileTypes.octetStream }
check("the file host serves no RAW, PSD, EXR, TGA, JPEG 2000 or ICNS", rawServed.isEmpty, "\(rawServed)")
let big = dir.appendingPathComponent("huge.heic")
FileManager.default.createFile(atPath: big.path, contents: nil)
let h = try! FileHandle(forWritingTo: big)
try! h.truncate(atOffset: UInt64(FileTypes.maxImageBytes) + 1)
try! h.close()
check("an image past the 50 MB cap gets the info card", payload("huge.heic")["view"] as? String == "info")
check("the payload names the kind", payload("photo.heic")["kindName"] as? String == UTType("public.heic")?.localizedDescription)

// ---- the pane in a real (off-screen) window above a WKWebView, as in the extension ----
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
/// The page under the pane: counts the scrolls it is handed.
final class Page: WKWebView {
    var scrolls = 0
    override func scrollWheel(with e: NSEvent) { scrolls += 1 }
}
let webView = Page(frame: container.bounds)
webView.autoresizingMask = [.width, .height]
container.addSubview(webView)
window.contentView = container
window.orderBack(nil)

let pane = ImagePane()
ImagePane.zoomDuration = 0
var zooms: [(String, Int)] = []
pane.onZoom = { zooms.append(($0, $1)) }
let largePath = dir.appendingPathComponent("large.tiff").path
pane.show(loaded("large.tiff")!, path: largePath)
check("show: hidden and out of the container until the page places it", pane.view.isHidden && pane.view.superview == nil && !pane.placed && zooms.isEmpty)
pane.place(message: ["path": "/elsewhere.tiff", "x": 0, "y": 0, "w": 10, "h": 10], in: webView)
check("place: a message for another file is ignored", pane.view.superview == nil && !pane.placed)
let msg: [String: Any] = ["path": largePath, "x": 200, "y": 100, "w": 800, "h": 600, "hide": false, "bg": [30, 30, 32], "dark": true, "radius": 8]
pane.place(message: msg, in: webView)
spin(0.05)
check("place: at the page's area, above the web view, dark, corners rounded", !pane.view.isHidden && pane.placed
      && pane.view.frame == NSRect(x: 200, y: 100, width: 800, height: 600) && container.subviews.last === pane.view
      && pane.view.layer?.cornerRadius == 8 && pane.view.appearance?.name == .darkAqua, "\(pane.view.frame)")
check("fitted: the whole image in the area (800 wide of 4000: 20%), from the screen-sized decode, reported for the caption",
      pane.fitted && abs(pane.view.magnification - 0.2) < 0.001 && pane.decodedWidth == ImagePane.screenPixels && zooms.last.map { $0.0 == largePath && $0.1 == 20 } == true,
      "\(pane.view.magnification) \(zooms)")
let doc = pane.imageView
pane.toggle(at: NSPoint(x: 3000, y: 500))
spin(0.05)
check("a double-click zooms to actual size about the point", !pane.fitted && abs(pane.view.magnification - 1) < 0.001 && zooms.last?.1 == 100
      && pane.view.contentView.bounds.midX > 2000, "\(pane.view.magnification) \(pane.view.contentView.bounds)")
spin(until: 5) { pane.decodedWidth == 4000 }
check("at 100% the whole image is decoded in place of the screen-sized one", pane.decodedWidth == 4000
      && doc.image?.size == NSSize(width: 4000, height: 1000), "\(pane.decodedWidth)")
check("⌘+ zooms in by a step", pane.key("zoomIn") && abs(pane.view.magnification - 1.25) < 0.001 && zooms.last?.1 == 125)
check("⌘− zooms out by a step, never below fitted", pane.key("zoomOut") && abs(pane.view.magnification - 1) < 0.001
      && (0..<12).allSatisfy { _ in pane.key("zoomOut") } && abs(pane.view.magnification - 0.2) < 0.001 && pane.fitted)
_ = pane.key("zoomIn")
check("⌘0 fits again", pane.key("zoomReset") && pane.fitted && zooms.last?.1 == 20)
check("zoom stops at 800%", { for _ in 0..<40 { _ = pane.key("zoomIn") }; return abs(pane.view.magnification - ImagePane.maxZoom) < 0.001 }())
_ = pane.key("zoomReset")

// A drag moves a zoomed image and is not a click; a click after it fits again.
pane.toggle(at: NSPoint(x: 2000, y: 500))
let before = pane.view.contentView.bounds.origin
func mouse(_ type: NSEvent.EventType, _ p: NSPoint, clicks: Int = 1) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                       clickCount: clicks, pressure: 1)!
}
let mid = pane.view.convert(NSPoint(x: 400, y: 300), to: nil)
pane.view.mouseDown(with: mouse(.leftMouseDown, mid))
pane.view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: mid.x - 150, y: mid.y)))
pane.view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: mid.x - 150, y: mid.y)))
let after = pane.view.contentView.bounds.origin
check("a drag moves the zoomed image and does not zoom back out", !pane.fitted && after.x > before.x + 100, "\(before) \(after)")
pane.view.mouseDown(with: mouse(.leftMouseDown, mid))
pane.view.mouseUp(with: mouse(.leftMouseUp, mid))
check("a single click leaves the zoom alone", !pane.fitted && abs(pane.view.magnification - 1) < 0.001)
pane.view.mouseDown(with: mouse(.leftMouseDown, mid, clicks: 2))
pane.view.mouseUp(with: mouse(.leftMouseUp, mid, clicks: 2))
check("a double-click on a zoomed image fits it again", pane.fitted && zooms.last?.1 == 20)

// ---- the trackpad and the mouse through NSApp.sendEvent, as real input arrives, in a window that is not key of an app that
// is not active: the Space viewer's case ----
check("the harness is as the viewer is: not active, its window not key", !NSApp.isActive && !window.isKeyWindow)
let mag = { pane.view.magnification }
let left = pane.view.convert(NSPoint(x: 200, y: 300), to: nil)
Synth.send(Synth.pinch(window, at: left, by: 0.1))
check("without GestureRouter AppKit drops the pinch (the Space panel's zoom failure)", pane.fitted && abs(mag() - 0.2) < 0.001, "\(mag())")
GestureRouter.install()
let under = doc.convert(left, from: nil)
Synth.send(Synth.pinch(window, at: left, by: 0.1))
let underAfter = doc.convert(left, from: nil)
check("a pinch zooms smoothly, step by step, reported for the caption", mag() > 0.26 && !pane.fitted && (zooms.last?.1 ?? 0) > 26, "\(mag()) \(zooms.suffix(3))")
check("a pinch zooms about the pointer", hypot(under.x - underAfter.x, under.y - underAfter.y) < 40, "\(under) \(underAfter)")
Synth.send(Synth.pinch(window, at: left, by: -0.3, steps: 8))
spin(0.5)
check("a pinch never leaves the image smaller than fitted", abs(mag() - 0.2) < 0.01 && pane.fitted, "\(mag())")
Synth.send([Synth.smartMagnify(window, at: left)])
check("a two-finger double tap zooms a fitted image to 100% about the pointer", abs(mag() - 1) < 0.001 && !pane.fitted
      && abs(doc.convert(left, from: nil).x - under.x) < 40, "\(mag()) \(doc.convert(left, from: nil)) \(under)")
let origin = pane.view.contentView.bounds.origin
let pageScrolls = webView.scrolls
Synth.send(Synth.scroll(window, at: left, dx: -60, dy: -120))
spin(0.5)
let moved = pane.view.contentView.bounds.origin
check("two fingers move a zoomed image, not the page", abs(moved.y - origin.y) > 80 && abs(moved.x - origin.x) > 30 && webView.scrolls == pageScrolls,
      "\(origin) \(moved) \(webView.scrolls)")
Synth.send([Synth.smartMagnify(window, at: left)])
check("a two-finger double tap on a zoomed image fits it", pane.fitted && abs(mag() - 0.2) < 0.001)
Synth.send(Synth.scroll(window, at: left, dy: -120))
check("two fingers over a fitted image scroll the page under it", webView.scrolls > pageScrolls && pane.fitted, "\(webView.scrolls)")
Synth.send(Synth.scroll(window, at: left, dy: 40, precise: false, control: true))
check("a wheel with ctrl zooms", mag() > 0.21 && !pane.fitted, "\(mag())")
_ = pane.key("zoomReset")
Synth.send(Synth.click(window, at: left, 1))
check("a click through the window leaves the zoom alone", pane.fitted)
Synth.send(Synth.click(window, at: left, 1) + Synth.click(window, at: left, 2))
check("a double-click through the window zooms to 100% once", abs(mag() - 1) < 0.001 && !pane.fitted, "\(mag())")
Synth.send(Synth.click(window, at: left, 1) + Synth.click(window, at: left, 2))
check("another double-click fits it again", pane.fitted)

// Double-click and the keys animate, unless the user asks for reduced motion; a key during the animation steps from where it goes.
ImagePane.zoomDuration = 0.25
pane.toggle(at: under)
if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
    check("reduced motion: a double-click zooms at once", abs(mag() - 1) < 0.001)
} else {
    let midway = mag()
    spin(0.5)
    check("a double-click zooms in an animation", midway < 0.99 && abs(mag() - 1) < 0.001, "\(midway) \(mag())")
}
_ = pane.key("zoomIn"); _ = pane.key("zoomIn")
spin(0.6)
check("⌘+ twice in a row, animated, steps twice", abs(mag() - 1.5625) < 0.001 && zooms.last?.1 == 156, "\(mag())")
_ = pane.key("zoomReset")
spin(0.6)
ImagePane.zoomDuration = 0

// A resize while fitted fits again; a small image shown whole starts at 100% and a click doubles it.
pane.place(message: msg.merging(["w": 400]) { _, n in n }, in: webView)
spin(0.05)
check("a resize while fitted fits the new area (10%)", pane.fitted && abs(pane.view.magnification - 0.1) < 0.001 && zooms.last?.1 == 10, "\(pane.view.magnification)")
let photo = dir.appendingPathComponent("photo.heic").path
pane.show(loaded("photo.heic")!, path: photo)
pane.place(message: msg.merging(["path": photo]) { _, n in n }, in: webView)
spin(0.05)
check("another image starts fitted: a small one at 100%, centred", pane.fitted && abs(pane.view.magnification - 1) < 0.001 && zooms.last.map { $0.0 == photo && $0.1 == 100 } == true
      && abs(pane.view.contentView.bounds.midX - 60) < 1 && abs(pane.view.contentView.bounds.midY - 40) < 1, "\(pane.view.contentView.bounds)")
pane.toggle(at: NSPoint(x: 60, y: 40))
check("a double-click on an image already whole doubles it", abs(pane.view.magnification - 2) < 0.001 && zooms.last?.1 == 200)
pane.show(loaded("photo.heic")!, path: photo)
check("the same file again (a change on disk) keeps its zoom", abs(pane.view.magnification - 2) < 0.001 && !pane.fitted)
pane.place(message: ["path": photo, "hide": true], in: webView)
check("place: hide with no rect conceals", pane.view.isHidden)
pane.place(message: msg.merging(["path": photo, "dark": false, "radius": 0]) { _, n in n }, in: webView)
check("place: light again, square corners", !pane.view.isHidden && pane.view.appearance?.name == .aqua && pane.view.layer?.masksToBounds == false)
// load: decoded off the main thread, then shown; a file ImageIO cannot decode is reported for its info card.
var failedPaths: [String] = []
pane.onFailed = { failedPaths.append($0) }
let tiff = dir.appendingPathComponent("scan.tiff")
pane.load(tiff)
check("load: the pane is for the file at once, its image not yet decoded", pane.path == tiff.path && pane.imageView.image == nil)
spin(until: 5) { pane.imageView.image != nil }
check("load: decoded off the main thread, then shown fitted", pane.imageView.image?.size == NSSize(width: 120, height: 80) && pane.fitted && failedPaths.isEmpty)
pane.load(dir.appendingPathComponent("fake.heic"))
check("load: another file clears the last image at once", pane.imageView.image == nil)
spin(until: 5) { !failedPaths.isEmpty }
check("load: a file ImageIO cannot decode is reported, for that file", failedPaths == [dir.appendingPathComponent("fake.heic").path], "\(failedPaths)")
check("pixelSize: from the properties alone, turned by EXIF, nil for a non-image",
      ImagePane.pixelSize(dir.appendingPathComponent("turned.heic")) == CGSize(width: 80, height: 120)
      && ImagePane.pixelSize(dir.appendingPathComponent("fake.heic")) == nil)
pane.close()
check("close: out of the container, the image let go", pane.view.superview == nil && pane.path == nil && !pane.placed && pane.imageView.image == nil
      && !pane.key("zoomIn"))

window.orderOut(nil)
print(failures == 0 ? "imagepane: all passed" : "imagepane: \(failures) failed")
exit(failures == 0 ? 0 : 1)
