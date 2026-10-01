// Drives the Space helper's viewer (Viewer/Viewer.swift) as the helper does over XPC, with its panel parked off screen, and
// times each show. Build and run with test/viewerlatency/run.sh.
import AppKit
import ImageIO
import PDFKit
import WebKit

let files = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let runs = Int(CommandLine.arguments[2]) ?? 20
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }
// Each turn in its own autorelease pool, as NSApplication's event loop gives the viewer: without one, what AppKit and PDFKit
// autorelease while drawing is never let go, and would count as the viewer's memory.
func turn(_ until: Date) { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: until) } }
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { turn(min(end, Date().addingTimeInterval(0.05))) } }
func spin(until: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { turn(Date().addingTimeInterval(0.001)) } }

// ---- fixtures, all under 5 MB: a photo-like PNG, JPEG and HEIC, a 12-page PDF, a log, and siblings for the sidebar. Made by
// a run of their own (`--fixtures`), so none of their memory is counted as the viewer's. ----
let walk = files.appendingPathComponent("walk")
let walkNames = ["a.md", "b.md", "c.txt", "d.swift", "e.md", "f.png", "g.md", "h.log", "i.md", "j.md"]
if CommandLine.arguments.count > 3, CommandLine.arguments[3] == "--fixtures" {
    func photo(_ w: Int, _ h: Int) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let p = ctx.data!.assumingMemoryBound(to: UInt32.self)
        var seed: UInt32 = 7
        for y in 0..<h {
            for x in 0..<w {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                let n = seed >> 28
                p[y * (ctx.bytesPerRow / 4) + x] = UInt32((x * 255 / w) & 0xff) | UInt32((y * 255 / h) & 0xff) << 8 | UInt32(128 + n) << 16
            }
        }
        return ctx.makeImage()!
    }
    func write(_ name: String, _ type: String, _ image: CGImage, quality: Double = 0.85) {
        let d = CGImageDestinationCreateWithURL(files.appendingPathComponent(name) as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(d, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        CGImageDestinationFinalize(d)
    }
    let big = photo(4032, 3024)
    write("photo.jpg", "public.jpeg", big)
    write("photo.heic", "public.heic", big, quality: 0.6)
    write("screen.png", "public.png", photo(1600, 1000))
    let red = CGContext(data: nil, width: 800, height: 600, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    red.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
    red.fill(CGRect(x: 0, y: 0, width: 800, height: 600))
    write("red.png", "public.png", red.makeImage()!)
    write("red.heic", "public.heic", red.makeImage()!)
    try! Data("not an image".utf8).write(to: files.appendingPathComponent("broken.heic"))
    do {
        let url = files.appendingPathComponent("report.pdf") as CFURL
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let ctx = CGContext(url, mediaBox: &box, nil)!
        for page in 1...12 {
            ctx.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            let text = "Page \(page)\n\n" + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60)
            (text as NSString).draw(in: box.insetBy(dx: 60, dy: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
    try! (0..<4000).map { "2026-09-29 12:00:\(String(format: "%02d", $0 % 60)) worker[\($0)] processed job \($0) in \($0 % 97) ms" }.joined(separator: "\n")
        .write(to: files.appendingPathComponent("server.log"), atomically: true, encoding: .utf8)
    for i in 0..<40 { try! "sibling \(i)\n".write(to: files.appendingPathComponent(String(format: "note-%02d.txt", i)), atomically: true, encoding: .utf8) }
    try! FileManager.default.createDirectory(at: walk, withIntermediateDirectories: true)
    for n in walkNames {
        let src: String
        switch (n as NSString).pathExtension {
        case "png": src = "screen.png"
        case "swift": src = "Controller.swift"
        case "log", "txt": src = "server.log"
        default: src = "notes.md"
        }
        try! FileManager.default.copyItem(at: files.appendingPathComponent(src), to: walk.appendingPathComponent(n))
    }
    exit(0)
}

// ---- the viewer, as the viewer app starts it, parked off screen ----
WebHost.pageHost = "panel"
_ = NSApplication.shared
OffScreen.install()
NSApp.setActivationPolicy(.accessory)
Viewer.parkedFrame = NSRect(x: -20000, y: -20000, width: 1100, height: 720)
let launched = now()
let viewer = Viewer.shared

/// Stands between the page and WebHost on the "sb" handler, noting when each render has been drawn (the page posts `rendered`
/// from the animation frame after it lays out); an <img> is also waited for until it is decoded.
final class Painted: NSObject, WKScriptMessageHandler {
    var last: (path: String, view: String, at: UInt64)?
    /// Each render drawn, as "path view".
    var renders: [String] = []
    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        WebHost.shared.userContentController(ucc, didReceive: m)
        guard let b = m.body as? [String: Any], b["type"] as? String == "rendered" else { return }
        let at = now()
        m.webView?.evaluateJavaScript("[current.path, current.view]") { r, _ in
            guard let pv = r as? [String], pv.count == 2 else { return }
            self.renders.append("\(pv[0]) \(pv[1])")
            guard pv[1] == "image" else { self.last = (pv[0], pv[1], at); return }
            m.webView?.callAsyncJavaScript("const i = document.querySelector('#doc .img-stage img'); if (i) await i.decode(); return 1;",
                                           arguments: [:], in: nil, in: .page) { _ in self.last = (pv[0], pv[1], now()) }
        }
    }
}
let painted = Painted()
let web = WebHost.shared.web
spin(until: 10) { WebHost.shared.ready }
let pageReady = now()
if ProcessInfo.processInfo.environment["NOWARM"] == nil { web.evaluateJavaScript("sb.warm && sb.warm(); 0") }
web.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
web.configuration.userContentController.add(painted, name: "sb")

/// A native view (PDF, image) is up with its content, over the page.
func nativeUp() -> Bool {
    var stack = viewer.panel.contentView.map { [$0] } ?? []
    while let v = stack.popLast() {
        stack += v.subviews
        if v.isHidden || v.superview == nil { continue }
        if let p = v as? PDFView, p.document != nil, p.frame.width > 0 { return true }
        if let s = v as? ImageScrollView, (s.documentView as? NSImageView)?.image != nil, s.frame.width > 0 { return true }
    }
    return false
}

/// The window server's view of the panel, polled off the main thread: its first frame with alpha above 0.
func frameWatch(_ wid: @escaping () -> Int, from t0: UInt64, _ done: @escaping (UInt64?) -> Void) {
    DispatchQueue.global(qos: .userInteractive).async {
        var seen: UInt64?
        while seen == nil, ms(t0, now()) < 5000 {
            let n = wid()
            if n > 0, let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(n)) as? [[String: Any]])?.first,
               w[kCGWindowIsOnscreen as String] as? Bool == true, (w[kCGWindowAlpha as String] as? Double ?? 0) > 0 {
                seen = now()
            } else {
                usleep(500)
            }
        }
        done(seen)
    }
}

let lock = NSLock()
var windowNumber = 0
var request = 0
struct Sample { let frame: Double?; let painted: Double? }
var closedLeftUp = 0
/// LATENCY_TARGETS=0 (CI): the latency targets are printed, not graded, and each close is given longer to settle.
let graded = ProcessInfo.processInfo.environment["LATENCY_TARGETS"] != "0"
let settle = graded ? 0.25 : 1.0

/// One Space: the helper's show call, from an XPC thread; then the close the next Space or Esc sends.
func space(_ url: URL) -> Sample {
    request += 1
    let id = request
    painted.last = nil
    let t0 = now()
    var frameAt: UInt64?, frameDone = false
    lock.lock(); let wn = windowNumber; lock.unlock()
    frameWatch({ lock.lock(); defer { lock.unlock() }; return windowNumber > 0 ? windowNumber : wn }, from: t0) { t in frameAt = t; frameDone = true }
    DispatchQueue.global(qos: .userInteractive).async { viewer.show([url.path], requestID: id) { _ in } }
    var paintedAt: UInt64?
    spin(until: 5) {
        lock.lock(); windowNumber = viewer.panel.windowNumber; lock.unlock()
        if paintedAt == nil, let p = painted.last, p.path == url.path {
            if ["pdf", "bitmap"].contains(p.view) { if nativeUp() { paintedAt = now() } } else { paintedAt = p.at }
        }
        return paintedAt != nil && frameDone
    }
    viewer.close()
    spin(settle)
    if viewer.panel.isVisible { closedLeftUp += 1 }
    return Sample(frame: frameAt.map { ms(t0, $0) }, painted: paintedAt.map { ms(t0, $0) })
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
func line(_ name: String, _ xs: [Double?]) -> String {
    let v = xs.compactMap { $0 }
    let miss = xs.count - v.count
    return String(format: "%-26@ p50 %6.1f  p95 %6.1f  max %6.1f ms%@", name as NSString, pct(v, 0.5), pct(v, 0.95), v.max() ?? .nan,
                  miss > 0 ? " (\(miss) missed)" as NSString : "" as NSString)
}

func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Double(info.phys_footprint) / 1e6
}
func resident() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) } }
    return Double(info.resident_size) / 1e6
}
print(String(format: "viewer up: page ready %.0f ms after launch; footprint %.1f MB, resident %.1f MB", ms(launched, pageReady), footprint(), resident()))
let kinds: [(String, String)] = [("Markdown", "notes.md"), ("text (log)", "server.log"), ("code (Swift)", "Controller.swift"), ("PNG <img>", "screen.png"),
                                 ("JPEG <img>", "photo.jpg"), ("HEIC (ImagePane)", "photo.heic"), ("PDF (PDFPane)", "report.pdf")]
let cold = space(files.appendingPathComponent("notes.md"))
print(String(format: "first show after launch: frame %.1f ms, painted %.1f ms", cold.frame ?? .nan, cold.painted ?? .nan))
var allFrames: [Double?] = [], allPainted: [Double?] = [], targetPainted: [Double?] = []
print("\nshow -> first visible frame | show -> content painted, \(runs) runs each")
for (name, file) in kinds where ProcessInfo.processInfo.environment["ONLY"].map({ name.contains($0) }) ?? true {
    let url = files.appendingPathComponent(file)
    var st = stat(); stat(url.path, &st)
    let samples = (0..<runs).map { _ in space(url) }
    if ProcessInfo.processInfo.environment["DEBUG"] != nil { print(samples.map { String(format: "%.0f/%.0f", $0.frame ?? -1, $0.painted ?? -1) }.joined(separator: " ")) }
    allFrames += samples.map(\.frame)
    allPainted += samples.map(\.painted)
    if !name.hasPrefix("code") { targetPainted += samples.map(\.painted) }
    print(line("\(name) frame", samples.map(\.frame)) + String(format: "   (%.1f MB)", Double(st.st_size) / 1e6))
    print(line("\(name) painted", samples.map(\.painted)))
    if ProcessInfo.processInfo.environment["DEBUG"] != nil { spin(1); print(String(format: "  footprint after: %.1f MB", footprint())) }
}
print(line("ALL frame", allFrames))
print(line("ALL painted", allPainted))

// ---- the panel reused for another file never shows the last one: a red image, then Markdown, each first visible frame ----
func redShare(_ img: CGImage?) -> Double {
    guard let img, let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
    let bpr = img.bytesPerRow, bpp = img.bitsPerPixel / 8
    var red = 0, n = 0
    for y in stride(from: img.height / 3, to: img.height * 2 / 3, by: 7) {
        for x in stride(from: img.width / 3, to: img.width * 2 / 3, by: 7) {
            let o = y * bpr + x * bpp
            if p[o + 2] > 150 && p[o + 1] < 120 && p[o] < 120 { red += 1 }
            n += 1
        }
    }
    return Double(red) / Double(max(n, 1))
}
/// The panel's red share as the window server has it; the capture is let go at once, so it is not counted as the viewer's memory.
func capturedRed() -> Double {
    autoreleasepool { redShare(CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(viewer.panel.windowNumber), [.boundsIgnoreFraming])) }
}
var stale: [Double] = []
for _ in 0..<5 {
    _ = space(files.appendingPathComponent("red.png"))
    request += 1
    let id = request
    DispatchQueue.global().async { viewer.show([files.appendingPathComponent("notes.md").path], requestID: id) { _ in } }
    var first: Double?
    spin(until: 3) {
        if first == nil, viewer.panel.alphaValue > 0, viewer.panel.isVisible {
            first = capturedRed()
        }
        return first != nil
    }
    stale.append(first ?? -1)
    viewer.close()
    spin(0.25)
}
print("\nred image, then Markdown: red in the middle of each first visible frame: " + stale.map { String(format: "%.2f", $0) }.joined(separator: " "))

// ---- an arrow key: the next file in the sidebar painted ----
print("\narrow -> next file painted (list session, warm)")
let first = walk.appendingPathComponent(walkNames[0])
DispatchQueue.global().async { viewer.show([first.path], requestID: 9999) { _ in } }
spin(until: 5) { painted.last?.path == first.path }
spin(until: 5) { viewer.keys.session != nil }
spin(0.3)
guard viewer.keys.session != nil else { print("FAIL no list session: the sidebar never took the arrows"); exit(1) }
var arrows: [Double?] = []
var at = 0
for i in 0..<(runs * 2) {
    let down = (i / (walkNames.count - 1)) % 2 == 0
    let next = at + (down ? 1 : -1)
    let target = walk.appendingPathComponent(walkNames[next])
    painted.last = nil
    let t0 = now()
    DispatchQueue.global(qos: .userInteractive).async { viewer.key(down ? "down" : "up", isRepeat: false) }
    var got: UInt64?
    spin(until: 3) {
        if got == nil, let p = painted.last, p.path == target.path {
            if ["pdf", "bitmap"].contains(p.view) { if nativeUp() { got = now() } } else { got = p.at }
        }
        return got != nil
    }
    arrows.append(got.map { ms(t0, $0) })
    if got == nil, ProcessInfo.processInfo.environment["DEBUG"] != nil { print("missed \(target.lastPathComponent): last \(painted.last.map { "\($0.path) \($0.view)" } ?? "nil") session \(viewer.keys.session ?? -1)") }
    at = next
    spin(0.15)
}
print(line("arrow next file", arrows))
viewer.close()

// ---- memory: this process (the viewer's own; WebKit's content process is apart) after 3 s idle ----
spin(3)
let idleFootprint = footprint()
print(String(format: "\nviewer idle after every run: footprint %.1f MB, resident %.1f MB", idleFootprint, resident()))

// ---- a suspended panel (another app came forward), then restored, closed or replaced: only a restore shows the old content ----
func firstFrame(until: Double = 3) -> Double? {
    var first: Double?
    spin(until: until) {
        if first == nil, viewer.panel.alphaValue > 0, viewer.panel.isVisible {
            first = capturedRed()
        }
        return first != nil
    }
    return first
}
func suspended(_ image: String, before: () -> Void = {}) {
    request += 1
    let id = request
    painted.last = nil
    let url = files.appendingPathComponent(image)
    DispatchQueue.global().async { viewer.show([url.path], requestID: id) { _ in } }
    spin(until: 5) { painted.last?.path == url.path && viewer.panel.alphaValue > 0 && (image.hasSuffix(".png") || nativeUp()) }
    spin(0.1)
    before()
    DispatchQueue.global().async { viewer.suspend() }
    spin(0.3)
}
func restoreReply() -> Bool? {
    request += 1
    var answer: Bool?
    let id = request
    DispatchQueue.global().async { viewer.restore(id) { ok in DispatchQueue.main.async { answer = ok } } }
    spin(until: 2) { answer != nil }
    return answer
}
var restored: [Double] = [], afterClose: [Double] = [], replaced: [Double] = [], closedShown = 0, closedRestored = 0
for image in ["red.png", "red.heic"] {
    for _ in 0..<3 {
        suspended(image)
        _ = restoreReply()
        restored.append(firstFrame() ?? -1)
        viewer.close()
        spin(settle)

        suspended(image)
        viewer.close()
        if firstFrame(until: 0.5) != nil { closedShown += 1 }
        if restoreReply() != false || viewer.panel.alphaValue > 0 { closedRestored += 1 }
        request += 1
        let a = request
        DispatchQueue.global().async { viewer.show([files.appendingPathComponent("notes.md").path], requestID: a) { _ in } }
        afterClose.append(firstFrame() ?? -1)
        viewer.close()
        spin(settle)

        suspended(image)
        request += 1
        let b = request
        DispatchQueue.global().async { viewer.show([files.appendingPathComponent("notes.md").path], requestID: b) { _ in } }
        replaced.append(firstFrame() ?? -1)
        viewer.close()
        spin(settle)
    }
}
// A PDF keeps its page through a suspend and restore.
func pdfView() -> PDFView? {
    var stack = viewer.panel.contentView.map { [$0] } ?? []
    while let v = stack.popLast() {
        if let p = v as? PDFView, p.document != nil { return p }
        stack += v.subviews
    }
    return nil
}
var pdfPage = -1
suspended("report.pdf") {
    if let p = pdfView(), let page = p.document?.page(at: 6) { p.go(to: page) }
    spin(0.3)
}
_ = restoreReply()
spin(0.3)
if let p = pdfView(), let page = p.currentPage { pdfPage = p.document?.index(for: page) ?? -1 }
viewer.close()
spin(settle)
print("PDF at page 7, suspended and restored: at page \(pdfPage + 1)")
let shares = { (xs: [Double]) in xs.map { String(format: "%.2f", $0) }.joined(separator: " ") }
print("suspended red image (PNG, then HEIC), red in the first visible frame: restored \(shares(restored)); closed, then Markdown \(shares(afterClose)); replaced by Markdown \(shares(replaced))")

// ---- an image that fell back to its info card is rendered once, not shown again when the panel appears ----
let broken = files.appendingPathComponent("broken.heic")
var brokenRenders: [Int] = []
for _ in 0..<3 {
    painted.renders = []
    _ = space(broken)
    spin(0.5)
    brokenRenders.append(painted.renders.filter { $0.hasPrefix(broken.path + " ") && !$0.hasSuffix(" loading") }.count)
}
print("an undecodable HEIC, renders per show: \(brokenRenders.map(String.init).joined(separator: " "))")

// ---- zoom in the panel as the trackpad, the mouse and the helper's keys reach it: real input's path (NSApp.sendEvent) into a
// panel that is never key, of an app that is never active ----
func js(_ source: String) -> Any? {
    var out: Any?, done = false
    web.evaluateJavaScript(source) { r, _ in out = r; done = true }
    spin(until: 3) { done }
    return out
}
func zoomLabel() -> Int { Int(((js("(document.querySelector('#kind .img-zoom') || {}).textContent || ''") as? String) ?? "").dropLast()) ?? -1 }
/// The middle of the image's area, in the panel's coordinates.
func imageMiddle() -> NSPoint? {
    guard let r = js("(() => { const a = document.querySelector('#doc .img-stage, #doc .pdf-area'); if (!a) return null; const b = a.getBoundingClientRect(); return [b.left + b.width / 2, b.top + b.height / 2]; })()") as? [Double],
          r.count == 2 else { return nil }
    let z = web.pageZoom
    return web.convert(NSPoint(x: r[0] * z, y: r[1] * z), to: nil)
}
func openImage(_ name: String) {
    request += 1
    let id = request, url = files.appendingPathComponent(name)
    painted.last = nil
    DispatchQueue.global().async { viewer.show([url.path], requestID: id) { _ in } }
    spin(until: 5) { painted.last?.path == url.path && viewer.panel.alphaValue > 0 && (name.hasSuffix(".png") || nativeUp()) }
    spin(0.4)
}
var zoomFailures: [String] = []
func zoomCheck(_ name: String, _ ok: Bool) { if !ok { zoomFailures.append(name) } }
let panelIsViewers = !NSApp.isActive && !viewer.panel.isKeyWindow && !viewer.panel.canBecomeKey
for name in ["screen.png", "photo.heic"] {
    openImage(name)
    let fit = zoomLabel()
    guard let mid = imageMiddle(), fit > 0, fit < 100 else { zoomFailures.append("\(name): not shown fitted (\(zoomLabel()))"); viewer.close(); spin(settle); continue }
    Synth.send(Synth.pinch(viewer.panel, at: mid, by: 0.1), pause: 0.03)
    spin(0.4)
    zoomCheck("\(name): a pinch zooms (\(fit)% -> \(zoomLabel())%)", zoomLabel() > fit + 5)
    DispatchQueue.global().async { viewer.key("zoomReset", isRepeat: false) }
    spin(0.5)
    zoomCheck("\(name): ⌘0 fits (\(zoomLabel())%)", zoomLabel() == fit)
    Synth.send([Synth.smartMagnify(viewer.panel, at: mid)])
    spin(0.5)
    zoomCheck("\(name): a two-finger double tap zooms to 100% (\(zoomLabel())%)", zoomLabel() == 100)
    Synth.send(Synth.click(viewer.panel, at: mid, 1) + Synth.click(viewer.panel, at: mid, 2), pause: 0.03)
    spin(0.5)
    zoomCheck("\(name): a double-click fits (\(zoomLabel())%)", zoomLabel() == fit)
    DispatchQueue.global().async { viewer.key("zoomIn", isRepeat: false) }
    spin(0.5)
    zoomCheck("\(name): ⌘+ zooms in a step (\(zoomLabel())%)", abs(zoomLabel() - Int((Double(fit) * 1.25).rounded())) <= 1)
    viewer.close()
    spin(settle)
}
print("\nzoom in the panel (never key, app never active): " + (zoomFailures.isEmpty ? "pinch, two-finger double tap, double-click, ⌘+ and ⌘0 on a PNG and a HEIC" : zoomFailures.joined(separator: "; ")))

// ---- the targets: Space -> frame includes the helper's own decision (7.5 ms p50 measured in Finder, FINDINGS.md), added here ----
var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
func target(_ name: String, _ ok: Bool) { graded ? check(name, ok) : print("INFO \(name)") }
let decision = 8.0
let frames = allFrames.compactMap { $0 }, paints = targetPainted.compactMap { $0 }, keys = arrows.compactMap { $0 }
target(String(format: "frame p95 %.1f ms (viewer %.1f + helper decision %.0f) <= 60 ms", pct(frames, 0.95) + decision, pct(frames, 0.95), decision),
       frames.count == allFrames.count && pct(frames, 0.95) + decision <= 60)
target(String(format: "painted p50 %.1f ms <= 120 ms and p95 %.1f ms <= 200 ms (Markdown, text, images, PDF)", pct(paints, 0.5) + decision, pct(paints, 0.95) + decision),
       paints.count == targetPainted.count && pct(paints, 0.5) + decision <= 120 && pct(paints, 0.95) + decision <= 200)
target(String(format: "arrow -> next file painted p50 %.1f ms <= 50 ms", pct(keys, 0.5)), keys.count == arrows.count && pct(keys, 0.5) <= 50)
target(String(format: "viewer idle footprint %.1f MB <= 90 MB", idleFootprint), idleFootprint <= 90)
check("the first visible frame of the next file never shows the last one", stale.allSatisfy { $0 == 0 })
check(String(format: "every close orders the panel out within %.0f ms", settle * 1000), closedLeftUp == 0)
check("a suspended panel restored shows its content again (the red check sees red)", restored.allSatisfy { $0 > 0.9 })
check("a suspended PDF restored is still at its page", pdfPage == 6)
check("a suspended panel closed never appears again, and a restore after the close is refused", closedShown == 0 && closedRestored == 0)
check("a suspended panel closed, then shown for another file: the first visible frame has none of the old one", afterClose.allSatisfy { $0 == 0 })
check("a suspended panel replaced by a show of another file: the first visible frame has none of the old one", replaced.allSatisfy { $0 == 0 })
check("an image that fell back to its info card is rendered once per show", brokenRenders.allSatisfy { $0 == 1 })
check("the harness's panel is the viewer's: never key, its app not active", panelIsViewers)
check("zoom in the panel: pinch, two-finger double tap, double-click, ⌘+ and ⌘0, on <img> and ImagePane", zoomFailures.isEmpty)
print(failures == 0 ? "viewer latency: all targets met" : "viewer latency: \(failures) targets missed")
exit(failures == 0 ? 0 : 1)
