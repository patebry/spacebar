// Large files through the Space helper's viewer (Viewer/Viewer.swift), driven as the helper drives it over XPC, with the panel
// parked off screen. For each file: show -> the page's DOM drawn ("painted", posted as draw() returns), show -> the content up
// (a table row, a tree row, the native view), the longest the viewer's main thread went without answering, and the viewer
// process's peak footprint. Build and run with test/bigfiles/run.sh.
//   bigfiles <files dir> [--fixtures]
//   PERF_TARGETS=0   the timing and memory targets are printed, not graded (CI)
//   RUNS=3           shows per file
//   DEBUG=1          what the page shows when a file's content never came up
import AppKit
import ImageIO
import PDFKit
import WebKit

let files = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let env = ProcessInfo.processInfo.environment
func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }

// ---- the fixtures ImageIO and PDFKit draw, made by a run of their own so none of their memory is the viewer's ----
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "--fixtures" {
    let side = 12_000
    let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let p = ctx.data!.assumingMemoryBound(to: UInt32.self), row = ctx.bytesPerRow / 4
    for y in 0..<side { for x in 0..<side { p[y * row + x] = UInt32(x * 255 / side) | UInt32(y * 255 / side) << 8 | UInt32((x ^ y) & 0xff) << 16 } }
    let d = CGImageDestinationCreateWithURL(files.appendingPathComponent("huge-12k.png") as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(d, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(d)
    var box = CGRect(x: 0, y: 0, width: 612, height: 792)
    let pdf = CGContext(files.appendingPathComponent("pages-500.pdf") as CFURL, mediaBox: &box, nil)!
    for page in 1...500 {
        pdf.beginPDFPage(nil)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: pdf, flipped: false)
        ("Page \(page)\n\n" + String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 60) as NSString)
            .draw(in: box.insetBy(dx: 60, dy: 60), withAttributes: [.font: NSFont.systemFont(ofSize: 12)])
        NSGraphicsContext.restoreGraphicsState()
        pdf.endPDFPage()
    }
    pdf.closePDF()
    exit(0)
}

func turn(_ until: Date) { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: until) } }
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { turn(min(end, Date().addingTimeInterval(0.02))) } }
func spin(until: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { turn(Date().addingTimeInterval(0.002)) } }

func footprint() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
    return Double(info.phys_footprint) / 1e6
}

/// While on: how long the main thread takes to run a block posted to it (every millisecond), and the process's footprint, at
/// their worst. A block waits exactly as long as whatever holds the main thread, so its wait is the longest stall input would see.
final class Watch {
    private let lock = NSLock()
    private var on = false, gen = 0
    private(set) var maxStall = 0.0, peak = 0.0
    func start() {
        lock.lock(); on = true; gen += 1; maxStall = 0; peak = footprint(); let g = gen; lock.unlock()
        Thread.detachNewThread { [self] in
            let done = DispatchSemaphore(value: 0)
            while true {
                lock.lock(); let live = on && g == gen; lock.unlock()
                if !live { return }
                let t = now()
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let stall = ms(t, now()), f = footprint()
                lock.lock(); if g == gen { maxStall = max(maxStall, stall); peak = max(peak, f) }; lock.unlock()
                usleep(1000)
            }
        }
        Thread.detachNewThread { [self] in
            while true {
                lock.lock(); let live = on && g == gen; lock.unlock()
                if !live { return }
                let f = footprint()
                lock.lock(); if g == gen { peak = max(peak, f) }; lock.unlock()
                usleep(500)
            }
        }
    }
    func stop() -> (stall: Double, peak: Double) {
        lock.lock(); on = false; defer { lock.unlock() }
        return (maxStall, peak)
    }
}
let watch = Watch()

// ---- the viewer, as the viewer app starts it, parked off screen ----
WebHost.pageHost = "panel"
_ = NSApplication.shared
OffScreen.install()
NSApp.setActivationPolicy(.accessory)
Viewer.parkedFrame = NSRect(x: -20000, y: -20000, width: 1100, height: 760)
let viewer = Viewer.shared

/// Stands between the page and WebHost on the "sb" handler: when each render's DOM is drawn ("painted") and drawn to a frame
/// ("rendered", from requestAnimationFrame, which a locked screen may never run).
final class Recorder: NSObject, WKScriptMessageHandler {
    var painted: UInt64?, rendered: UInt64?
    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        WebHost.shared.userContentController(ucc, didReceive: m)
        guard let b = m.body as? [String: Any], let type = b["type"] as? String else { return }
        if type == "painted" {
            // "Loading…" is drawn for a slow read; only the file's own view counts.
            let at = now()
            m.webView?.evaluateJavaScript("current.view") { r, _ in if r as? String != "loading", self.painted == nil { self.painted = at } }
        }
        if type == "rendered" { rendered = rendered ?? now() }
    }
}
let rec = Recorder()
let web = WebHost.shared.web
spin(until: 15) { WebHost.shared.ready }
guard WebHost.shared.ready else { print("FAIL the page never became ready"); exit(1) }
web.evaluateJavaScript("sb.warm && sb.warm(); 0")
web.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
web.configuration.userContentController.add(rec, name: "sb")
web.evaluateJavaScript("window.__errs = []; addEventListener('error', (e) => window.__errs.push(String(e.message))); 0")

func js(_ src: String, timeout: Double = 10) -> Any? {
    var out: Any?, done = false
    web.evaluateJavaScript(src) { r, _ in out = r; done = true }
    spin(until: timeout) { done }
    return out
}

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

struct Case {
    let name: String, file: String
    /// The content is up: evaluated in the page, true once it is (nil: a native view).
    let up: String?
    /// After the last show: what the page must hold, as a check.
    let check: String?
    let expect: String
    /// Graded: the main thread never stalls longer than this, and the footprint grows no more than this.
    var stallTarget = 50.0, growthTarget = 60.0
}
func size(_ file: String) -> Int { (try? FileManager.default.attributesOfItem(atPath: files.appendingPathComponent(file).path)[.size] as? Int) ?? -1 }
/// The Markdown file's text as the page must hold it: CRLF made LF, its byte order mark kept (UTF-16 units, then the first).
let markdown = (try? String(contentsOf: files.appendingPathComponent("notes/big.md"), encoding: .utf8)).map { $0.replacingOccurrences(of: "\r\n", with: "\n") } ?? ""
let rowCount = "(() => { const h = (document.getElementById('kind') || {}).textContent || ''; const m = h.match(/([\\d,]+) rows/); return m ? +m[1].replace(/,/g, '') : 0; })()"
let cases: [Case] = [
    Case(name: "CSV 16 MB", file: "big-16mb.csv", up: "!!document.querySelector('#doc table.csv tbody tr:not(.pad) td')", check: "String(\(rowCount) > 300000)", expect: "true"),
    Case(name: "CSV 16 MB, CJK + accents", file: "intl-16mb.csv", up: "!!document.querySelector('#doc table.csv tbody tr:not(.pad) td')",
         check: "String(\(rowCount) > 200000) + (document.querySelector('#doc table.csv tbody td:nth-child(3)') || {}).textContent.slice(0, 2)", expect: "true名前"),
    Case(name: "CSV 16 MB, Windows-1252", file: "cp1252-16mb.csv", up: "!!document.querySelector('#doc table.csv tbody tr:not(.pad) td')",
         check: "String(\(rowCount) > 300000) + ' ' + current.encoding + ' ' + (document.querySelector('#doc table.csv tbody td:nth-child(4)') || {}).textContent.slice(0, 24)",
         expect: "true Windows-1252 Café crème naïve déjà vu"),
    Case(name: "CSV 50k rows", file: "rows-50k.csv", up: "!!document.querySelector('#doc table.csv tbody tr:not(.pad) td')", check: rowCount, expect: "50000"),
    Case(name: "JSON 2 MB minified", file: "minified-2mb.json", up: "document.querySelectorAll('#doc .json-tree .jt-row').length > 1",
         check: "current.view + ':' + (current.text || '').length", expect: "json:\(size("minified-2mb.json"))"),
    Case(name: "code 2 MB (JS)", file: "bundle-2mb.js", up: "!!document.querySelector('#doc pre.code')",
         check: "current.view + ':' + (current.text || '').length", expect: "code:\(size("bundle-2mb.js"))"),
    Case(name: "Markdown 4 MB (BOM, CRLF, [[links]])", file: "notes/big.md", up: "document.querySelectorAll('#doc h2').length > 1000",
         check: "(current.view || 'markdown') + ':' + current.text.length + ':' + current.text.charCodeAt(0) + ':' + current.text.includes('\\r') + ':' + document.querySelectorAll('#doc h2').length",
         expect: "markdown:\(markdown.utf16.count):65279:false:2000"),
    // PDFKit has opened the document before the page is told to draw the PDF view; the native view is placed from the page's
    // layout on an animation frame, which a locked screen never runs, so it is timed only where there is one.
    Case(name: "PDF 500 pages", file: "pages-500.pdf", up: "current.view === 'pdf'", check: "current.view", expect: "pdf"),
    Case(name: "PNG 12k x 12k", file: "huge-12k.png", up: "(() => { const i = document.querySelector('#doc .img-stage img'); return !!(i && i.complete && i.naturalWidth); })()",
         check: "(() => { const i = document.querySelector('#doc .img-stage img'); return i ? i.naturalWidth + 'x' + i.naturalHeight : ''; })()", expect: "12000x12000"),
    Case(name: "zip 10k entries", file: "many-10k.zip", up: "document.querySelectorAll('#doc [data-path]').length >= 50",
         check: "(document.getElementById('doc').textContent.match(/[\\d,]+ files, [\\d,]+ folders/) || [''])[0]", expect: "5,000 files, 50 folders"),
    Case(name: "folder 5,000 files", file: "folder-5000", up: "current.view === 'overview'",
         check: "current.view", expect: "overview"),
    Case(name: "file in 5,000-file folder", file: "folder-5000/item-2500.txt", up: "document.querySelectorAll('#side-list a.row').length > 20",
         check: "String(document.querySelectorAll('#side-list a.row').length > 20)", expect: "true"),
]

struct Sample { let painted: Double?, rendered: Double?, up: Double?, stall: Double, peak: Double, base: Double; var unlisted = false }
var request = 0
func show(_ c: Case) -> Sample {
    request += 1
    let id = request, url = files.appendingPathComponent(c.file)
    rec.painted = nil
    rec.rendered = nil
    spin(0.3)
    let base = footprint()
    watch.start()
    let t0 = now()
    DispatchQueue.global(qos: .userInteractive).async { viewer.show([url.path], requestID: id) { _ in } }
    var upAt: UInt64?
    var asking = false, lastAsk: UInt64 = 0
    spin(until: 20) {
        if upAt == nil {
            if let probe = c.up {
                if !asking, rec.painted != nil, ms(lastAsk, now()) >= 5 {
                    lastAsk = now()
                    asking = true
                    web.evaluateJavaScript("current.path === \(String(data: try! JSONSerialization.data(withJSONObject: [url.path]), encoding: .utf8)!)[0] && \(probe)") { r, _ in
                        if r as? Bool == true, upAt == nil { upAt = now() }
                        asking = false
                    }
                }
            } else if nativeUp() {
                upAt = now()
            }
        }
        return upAt != nil
    }
    // The writer's listing failed: the archive's card.
    let unlisted = upAt == nil && (js("document.getElementById('doc').textContent.includes('contents can’t be listed')") as? Bool ?? false)
    if upAt == nil, env["DEBUG"] != nil {
        print("  not up: painted \(rec.painted != nil) asking \(asking) page:", js("JSON.stringify([current.path, current.view, document.querySelectorAll('#doc [data-path]').length, document.getElementById('doc').textContent.slice(0, 60), document.getElementById('status').textContent])") ?? "nil")
    }
    // What arrives after the content is up (highlighting, the rest of a table) still holds the viewer's main thread, or not.
    spin(1.0)
    let w = watch.stop()
    return Sample(painted: rec.painted.map { ms(t0, $0) }, rendered: rec.rendered.map { ms(t0, $0) }, up: upAt.map { ms(t0, $0) },
                  stall: w.stall, peak: w.peak, base: base, unlisted: unlisted)
}

func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}
let runs = Int(env["RUNS"] ?? "3") ?? 3
let graded = env["PERF_TARGETS"] != "0"
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") { print("\(ok ? "PASS" : "FAIL") \(name)\(ok || detail.isEmpty ? "" : ": \(detail)")"); if !ok { failures += 1 } }
func target(_ name: String, _ ok: Bool) { graded ? check(name, ok) : print("INFO \(name)") }

print(String(format: "viewer up; footprint %.1f MB. %d shows per file, from a closed panel; times from the show call.", footprint(), runs))
print(String(format: "%-26@ %9@ %9@ %9@ %10@ %10@ %9@", "file", "DOM", "frame", "content", "main stall", "peak MB", "growth"))
var results: [(Case, [Sample])] = []
for c in cases where env["ONLY"].map({ c.name.contains($0) }) ?? true {
    _ = show(c)
    viewer.close()
    spin(0.5)
    var samples: [Sample] = [], unlisted = 0
    for i in 0..<runs {
        let s = show(c)
        if s.unlisted { unlisted += 1 } else { samples.append(s) }
        if i < runs - 1 { viewer.close(); spin(0.8) }
    }
    let got = (js(c.check ?? "''") as? CustomStringConvertible).map { "\($0)" } ?? "nil"
    viewer.close()
    spin(0.8)
    let med = { (f: (Sample) -> Double?) -> String in
        let v = samples.compactMap(f)
        return v.count < samples.count ? "—" : String(format: "%.0f", pct(v, 0.5))
    }
    let stall = samples.map(\.stall).max() ?? .nan, peak = samples.map(\.peak).max() ?? .nan
    let growth = samples.map { $0.peak - $0.base }.max() ?? .nan
    print(String(format: "%-26@ %9@ %9@ %9@ %10.1f %10.1f %9.1f", c.name as NSString, med(\.painted) as NSString, med(\.rendered) as NSString,
                 med(\.up) as NSString, stall, peak, growth))
    results.append((c, samples))
    let shown = !samples.isEmpty && samples.allSatisfy { $0.up != nil } && got == c.expect
    check("\(c.name): shown (\(got))", shown, "expected \(c.expect), content up \(samples.map { $0.up != nil })")
    if c.file.hasSuffix(".zip") {
        check("\(c.name): the writer listed it in \(runs - unlisted) of \(runs) shows", unlisted == 0, "the archive's card instead in \(unlisted)")
    }
    target(String(format: "\(c.name): main thread never stalls over %.0f ms (%.1f)", c.stallTarget, stall), stall <= c.stallTarget)
    target(String(format: "\(c.name): footprint grows at most %.0f MB (%.1f)", c.growthTarget, growth), growth <= c.growthTarget)
}
// Two large files shown one after the other: at once (the first show is dropped), and while the page is still busy, so both
// renders are sent before the page runs either. The second is what ends up on screen, whole.
if env["ONLY"].map({ $0 == "pairs" }) ?? true {
    for (a, b, busy) in [("big-16mb.csv", "intl-16mb.csv", false), ("notes/big.md", "cp1252-16mb.csv", false),
                         ("intl-16mb.csv", "big-16mb.csv", true), ("cp1252-16mb.csv", "notes/big.md", true)] {
        let first = files.appendingPathComponent(a), second = files.appendingPathComponent(b)
        request += 2
        let id = request
        if busy {
            // The page's thread is held for 4 s; each show's render waits behind it, as behind a slow render or a page load.
            web.evaluateJavaScript("(() => { const end = Date.now() + 4000; while (Date.now() < end); })(); 0")
            DispatchQueue.global(qos: .userInteractive).async { viewer.show([first.path], requestID: id - 1) { _ in } }
            spin(1.5)
            DispatchQueue.global(qos: .userInteractive).async { viewer.show([second.path], requestID: id) { _ in } }
        } else {
            DispatchQueue.global(qos: .userInteractive).async {
                viewer.show([first.path], requestID: id - 1) { _ in }
                viewer.show([second.path], requestID: id) { _ in }
            }
        }
        let want = "\(String(data: try! JSONSerialization.data(withJSONObject: [second.path]), encoding: .utf8)!)[0]"
        let drawn = second.pathExtension == "md" ? "document.querySelectorAll('#doc h2').length > 1000" : "!!document.querySelector('#doc table.csv tbody tr:not(.pad) td')"
        var shown = false
        spin(until: 25) {
            shown = js("current.path === \(want) && \(drawn)") as? Bool ?? false
            if !shown { spin(0.05) }
            return shown
        }
        check("\(a), then \(b)\(busy ? " while the page is busy" : " at once"): \(b) is drawn", shown)
        viewer.close()
        spin(0.8)
    }
}
if let errs = js("window.__errs") as? [String] { check("no script errors in the page", errs.isEmpty, errs.prefix(3).joined(separator: " | ")) }
print("(DOM: the page's draw() done. frame: its next animation frame, — where a locked screen runs none. content: the table, tree, native view or listing up. main stall: the viewer's main thread at its longest without answering, from the show to a second after the content is up. peak/growth: the viewer process's footprint.)")
print(failures == 0 ? "big files: all checks passed" : "big files: \(failures) failed")
exit(failures == 0 ? 0 : 1)
