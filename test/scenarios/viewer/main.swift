// Day-in-the-life scenarios, driven through the Space helper's viewer as the helper drives it over XPC (show, key, close):
// the real Viewer, PreviewController, page and native panes, with the panel parked off screen. No key or mouse event reaches
// the system (flow 10's keys are NSEvents inside the stub writer), no window on screen. Build and run with test/scenarios/run.sh.
//   scenarios <out dir> [<video dir>]      <out dir>: what test/scenarios/corpus_real.py wrote
//   FLOWS=1,2,...   the flows to run (default all)
//   SCEN_TIMING=0   latency targets are printed, not graded (CI)
//   SCEN_STRICT=1   a KNOWN bug fails the run
//   SCEN_DEBUG=1    print every script evaluated and every render
import AppKit
import AVFoundation
import AVKit
import PDFKit
import Quartz
import UniformTypeIdentifiers
import WebKit

let out = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let videoDir = CommandLine.arguments.count > 2 && !CommandLine.arguments[2].isEmpty
    ? URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath() : nil
let env = ProcessInfo.processInfo.environment
let flows = Set((env["FLOWS"] ?? "1,2,3,4,5,6,7,8,10,11").split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
let timing = env["SCEN_TIMING"] != "0"
let strict = env["SCEN_STRICT"] == "1"
let corpus = out.appendingPathComponent("corpus")
let repo = out.appendingPathComponent("repo")
let manifest = (try? JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("manifest.json")))) as? [String: Any] ?? [:]

func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ a: UInt64, _ b: UInt64) -> Double { Double(b &- a) / 1e6 }

// ---- a watchdog: a main thread stuck for 30 s is a hang, reported with the step it was in ----
let beatLock = NSLock()
var beat = Date()
var step = "start"
func mark(_ s: String) { beatLock.lock(); step = s; beat = Date(); beatLock.unlock() }
Thread.detachNewThread {
    while true {
        sleep(1)
        beatLock.lock()
        let stuck = Date().timeIntervalSince(beat), s = step
        beatLock.unlock()
        if stuck > 30 { print("FAIL the viewer's main thread hung for 30 s during: \(s)"); fflush(stdout); exit(1) }
    }
}
func turn(_ until: Date) {
    beatLock.lock(); beat = Date(); beatLock.unlock()
    autoreleasepool { _ = RunLoop.main.run(mode: .default, before: until) }
}
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { turn(min(end, Date().addingTimeInterval(0.02))) } }
func spin(until: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { turn(Date().addingTimeInterval(0.002)) } }

// ---- results ----
var failures = 0, knownBugs: [String] = []
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
    fflush(stdout)
}
/// A check that fails today for a known, reported bug: printed, graded only with SCEN_STRICT=1.
func known(_ bug: String, _ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { print("PASS \(name) (\(bug) no longer reproduces)"); return }
    knownBugs.append(bug)
    if strict { failures += 1 }
    print("\(strict ? "FAIL" : "KNOWN") \(bug) \(name): \(detail())")
    fflush(stdout)
}
func target(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") { timing ? check(name, ok, detail()) : print("INFO \(name)\(ok ? "" : ": \(detail())")") }
func info(_ s: String) { print("  \(s)"); fflush(stdout) }
func pct(_ xs: [Double], _ p: Double) -> Double {
    let s = xs.sorted()
    return s.isEmpty ? .nan : s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
}

// ---- the viewer, as the viewer app starts it, parked off screen ----
WebHost.pageHost = "panel"
_ = NSApplication.shared
OffScreen.install()
NSApp.setActivationPolicy(.accessory)
Viewer.parkedFrame = NSRect(x: -20000, y: -20000, width: 1100, height: 760)
let viewer = Viewer.shared

/// Stands between the page and WebHost on the "sb" handler: every message the page posts, and each render with its path and view.
final class Recorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    var renders: [(path: String, view: String, at: UInt64)] = []
    var readies = 0
    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        WebHost.shared.userContentController(ucc, didReceive: m)
        guard let b = m.body as? [String: Any] else { return }
        messages.append(b)
        if b["type"] as? String == "ready" { readies += 1 }
        guard b["type"] as? String == "rendered" else { return }
        let at = now()
        m.webView?.evaluateJavaScript("[current.path, current.view || 'markdown']") { r, _ in
            guard let pv = r as? [String], pv.count == 2 else { return }
            self.renders.append((pv[0], pv[1], at))
        }
    }
}
let rec = Recorder()
let web = WebHost.shared.web
OffScreen.keepDrawing(web)
spin(until: 15) { WebHost.shared.ready }
guard WebHost.shared.ready else { print("FAIL the page never became ready"); exit(1) }
web.evaluateJavaScript("sb.warm && sb.warm(); 0")
web.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
web.configuration.userContentController.add(rec, name: "sb")
let errorHook = """
  if (!window.__errs) { window.__errs = [];
    addEventListener('error', (e) => window.__errs.push(String(e.message) + ' @' + (e.filename || '').split('/').pop() + ':' + e.lineno + (e.error && e.error.stack ? ' ' + e.error.stack.split('\\n').slice(0, 3).join(' < ') : '')));
    addEventListener('unhandledrejection', (e) => window.__errs.push('rejection: ' + e.reason)); } 0
  """
web.evaluateJavaScript(errorHook)

func js(_ src: String, timeout: Double = 10) -> Any? {
    var out: Any?, done = false
    web.evaluateJavaScript(src) { r, e in out = r ?? e.map { "ERR \($0)" }; done = true }
    spin(until: timeout) { done }
    if env["SCEN_DEBUG"] != nil, !src.contains("__errs") {
        var n: Any?, d2 = false
        web.evaluateJavaScript("(window.__errs || []).length") { r, _ in n = r; d2 = true }
        spin(until: 2) { d2 }
        print("    js[\(n ?? "?")] \(src.prefix(90).replacingOccurrences(of: "\n", with: " "))")
    }
    return done ? out : "TIMEOUT"
}
func jsJSON(_ body: String) -> [String: Any] {
    guard let s = js("JSON.stringify((() => { \(body) })())") as? String, let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

/// What the page shows: the file, its view, the document's text (its start), notes, the status line and the sidebar.
struct PageState {
    let raw: [String: Any]
    var path: String { raw["path"] as? String ?? "" }
    var view: String { raw["view"] as? String ?? "" }
    var text: String { raw["text"] as? String ?? "" }
    var kindName: String { raw["kindName"] as? String ?? "" }
    var head: String { raw["head"] as? String ?? "" }
    var notes: [String] { raw["notes"] as? [String] ?? [] }
    var status: String { raw["status"] as? String ?? "" }
    var rows: [String] { raw["rows"] as? [String] ?? [] }
    var fileRows: [String] { raw["fileRows"] as? [String] ?? [] }
    var active: String { raw["active"] as? String ?? "" }
    var more: String { raw["more"] as? String ?? "" }
    var errs: [String] { raw["errs"] as? [String] ?? [] }
    var pwned: String? { raw["pwned"] as? String }
    var blank: Bool { raw["blank"] as? Bool ?? false }
}
func page() -> PageState {
    PageState(raw: jsJSON("""
      const d = document.getElementById('doc'), q = (s) => [...d.querySelectorAll(s)];
      const kind = document.getElementById('kind');
      return { path: current.path || '', view: current.path ? (current.view || 'markdown') : '', kindName: current.kindName || '', encoding: current.encoding || '',
        truncated: current.truncated === true, text: d.textContent.slice(0, 40000), head: kind ? kind.textContent : '',
        notes: q('.viewer-note').map((n) => n.textContent), status: document.getElementById('status').textContent,
        rows: [...document.querySelectorAll('#side-list a.row')].map((a) => a.dataset.path),
        fileRows: [...document.querySelectorAll('#side-list a.row.file')].map((a) => a.dataset.path),
        active: (document.querySelector('#side-list a.active') || { dataset: {} }).dataset.path || '',
        more: document.getElementById('side-more').hidden ? '' : document.getElementById('side-more').textContent,
        pwned: window.__pwned === undefined || window.__pwned === null ? null : String(window.__pwned), errs: window.__errs || [],
        blank: document.documentElement.dataset.blank !== undefined };
      """))
}

// ---- the native views over the page ----
func visible(_ v: NSView) -> Bool {
    var x: NSView? = v
    while let y = x { if y.isHidden || y.alphaValue == 0 { return false }; x = y.superview }
    return v.window != nil && v.frame.width > 1 && v.frame.height > 1
}
struct Natives {
    var pdf: PDFView?, player: AVPlayerView?, image: ImageScrollView?, text: NSTextView?, ql: QLPreviewView?, html: WKWebView?
    /// The kinds of native view on screen, as the page's view names them.
    var shown: Set<String> {
        var s: Set<String> = []
        if pdf != nil { s.insert("pdf") }
        if player != nil { s.insert("media") }
        if image != nil { s.insert("bitmap") }
        if text != nil { s.insert("rtf") }
        if ql != nil { s.insert("quicklook") }
        if html != nil { s.insert("html") }
        return s
    }
}
func natives() -> Natives {
    var n = Natives()
    var stack = viewer.panel.contentView.map { [$0] } ?? []
    while let v = stack.popLast() {
        // Apple's preview draws with views of its own (a web view for Office files): they are the preview, not another pane.
        if !(v is QLPreviewView) { stack += v.subviews }
        guard visible(v) else { continue }
        if let p = v as? PDFView, p.document != nil { n.pdf = p }
        if let p = v as? AVPlayerView, p.player?.currentItem != nil { n.player = p }
        if let s = v as? ImageScrollView, (s.documentView as? NSImageView)?.image != nil { n.image = s }
        if let t = v as? NSTextView, !(t.enclosingScrollView is ImageScrollView), t.string.count > 0 { n.text = t }
        if let q = v as? QLPreviewView { n.ql = q }
        if let w = v as? WKWebView, w !== web { n.html = w }
    }
    return n
}
/// The native view a page view is drawn by, if any.
func nativeFor(_ view: String) -> String? {
    switch view {
    case "pdf", "bitmap", "rtf", "quicklook", "html": return view
    case "video", "audio": return "media"
    default: return nil
    }
}

// ---- Space, arrows and close, as the helper sends them ----
var request = 0
var lastMarker: String?

/// The first render of `path` since render index `from` in a view other than "loading", with its time.
func firstRender(_ path: String, from: Int) -> (view: String, at: UInt64)? {
    rec.renders.dropFirst(from).first { $0.path == path && $0.view != "loading" }.map { ($0.view, $0.at) }
}
/// Waits for `path` to be shown: rendered, then its content up: the native view for a native one, an <img> decoded.
func waitShown(_ path: String, from: Int, t0: UInt64, timeout: Double = 8) -> (view: String, rendered: Double?, painted: Double?) {
    var r: (view: String, at: UInt64)?
    spin(until: timeout) { r = firstRender(path, from: from); return r != nil }
    guard let r else { return ("", nil, nil) }
    let rendered = ms(t0, r.at)
    var painted: Double?
    if let want = nativeFor(r.view) {
        spin(until: 5) { natives().shown.contains(want) || rec.renders.last?.view == "info" }
        painted = natives().shown.contains(want) ? ms(t0, now()) : nil
    } else if r.view == "image" {
        var done = false
        web.callAsyncJavaScript("const i = document.querySelector('#doc .img-stage img'); const frame = () => new Promise((r) => requestAnimationFrame(r)); for (let n = 0; i && !(i.complete && i.naturalWidth) && n < 600; n++) await frame(); await frame(); return 1;",
                                arguments: [:], in: nil, in: .page) { _ in done = true }
        spin(until: 10) { done }
        painted = ms(t0, now())
    } else {
        painted = rendered
    }
    return (r.view, rendered, painted)
}
struct Shown { let view: String; let rendered: Double?; let painted: Double?; let page: PageState; let natives: Natives }
/// One Space on `paths`, from a closed panel: shown and read back; `settle` more seconds for late changes (a media file that
/// fails, a thumbnail). The caller closes.
var closingErrors: [String] = []
func space(_ paths: [URL], expect: URL? = nil, any: Bool = false, settle: Double = 0.3, timeout: Double = 8) -> Shown {
    // Errors since the last read (a close, a hide) are kept apart; each show starts with none.
    if let e = js("(() => { const e = window.__errs || []; window.__errs = []; return e; })()") as? [String] { closingErrors += e }
    request += 1
    let id = request, from = rec.renders.count, t0 = now()
    mark("show \(paths.map(\.lastPathComponent).joined(separator: ", "))")
    DispatchQueue.global(qos: .userInteractive).async { viewer.show(paths.map(\.path), requestID: id) { _ in } }
    var target = (expect ?? paths[0]).path
    if any {
        spin(until: timeout) { rec.renders.dropFirst(from).contains { $0.view != "loading" } }
        target = rec.renders.dropFirst(from).first { $0.view != "loading" }?.path ?? target
    }
    let w = waitShown(target, from: from, t0: t0, timeout: timeout)
    spin(settle)
    if env["SCEN_DEBUG"] != nil { info("renders: " + rec.renders.dropFirst(from).map { String(format: "%@ %@ @%.0f", ($0.path as NSString).lastPathComponent, $0.view, ms(t0, $0.at)) }.joined(separator: ", ")) }
    // The view is the page's own, read now: a render's message is labelled when its reply comes back, which under load can be
    // after the next render.
    let p = page()
    return Shown(view: p.path == target ? p.view : w.view, rendered: w.rendered, painted: w.painted, page: p, natives: natives())
}
/// The pointer over `x`, `y` points from the panel's top left, as the page sees it: WebKit takes no synthetic mouse-moved
/// event in a window off screen, so the element there gets a mousemove.
func hover(_ x: Double, _ y: Double) {
    _ = js("{ const t = document.elementFromPoint(\(x), \(y)); t && t.dispatchEvent(new MouseEvent('mousemove', { bubbles: true, clientX: \(x), clientY: \(y) })); } 0")
    spin(0.2)
}
/// Whether a press at `x`, `y` points from the panel's top left would drag the panel; the press is not sent.
func pressDrags(_ x: Double, _ y: Double) -> Bool {
    let p = viewer.panel
    guard let e = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: x, y: p.frame.height - y), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: p.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
    return p.drags(e)
}
func close() {
    mark("close")
    viewer.close()
    spin(0.3)
}

// ---- manifest helpers ----
let corpusSpec = manifest["corpus"] as? [String: [String: Any]] ?? [:]
func marker(of url: URL) -> String? {
    guard let d = try? Data(contentsOf: url, options: .alwaysMapped).prefix(4096), let s = String(data: d, encoding: .utf8),
          let r = s.range(of: #"MARK-[A-Za-z0-9]+"#, options: .regularExpression) else { return nil }
    return String(s[r])
}
func noErrors(_ name: String, _ p: PageState) {
    check("\(name): no page errors", p.errs.isEmpty, p.errs.joined(separator: " | "))
}
func readyCount() -> Int { rec.readies }

print("scenarios: \(out.path)\(videoDir.map { ", videos \($0.path)" } ?? "")")

// ================= 1. a repo folder: README first, then ↓ through 30 files =================
if flows.contains("1") {
    print("\n== 1. open a repo folder, arrow through 30 files of mixed types")
    let s = space([repo], expect: repo.appendingPathComponent("README.md"), settle: 0.5)
    check("1: the folder opens on its README", s.page.path.hasSuffix("/README.md") && s.view == "markdown", "\(s.page.path) \(s.view)")
    info(String(format: "the folder opened on its README in %.0f ms", s.painted ?? .nan))
    spin(until: 5) { viewer.keys.session != nil }
    check("1: the sidebar holds the arrow keys", viewer.keys.session != nil)
    let rows = page().fileRows
    check("1: the sidebar lists README first and every file", rows.first?.hasSuffix("/README.md") == true && rows.count == (manifest["repo"] as? [String])?.count,
          "\(rows.count) rows, first \(rows.first ?? "-")")
    // The traffic lights and the sidebar button share the top row's centre line, and the lights are clear of the button.
    let lights = [NSWindow.ButtonType.closeButton, .zoomButton].compactMap { viewer.panel.standardWindowButton($0).map { $0.convert($0.bounds, to: nil) } }
    let tg = jsJSON("const r = document.getElementById('side-toggle').getBoundingClientRect(); return { mid: r.top + r.height / 2, left: r.left };")
    let lightsMid = lights.first.map { viewer.panel.frame.height - $0.midY } ?? .nan, toggleMid = tg["mid"] as? Double ?? .nan
    check("1: the sidebar button is centred on the traffic lights, to their right", lights.count == 2 && abs(lightsMid - toggleMid) <= 2
          && (tg["left"] as? Double ?? 0) >= lights[1].maxX + 8, "lights \(lights) centre \(lightsMid), button \(tg)")
    // The empty top row and the folder heading's margin drag the panel; its controls and the folder's name do not.
    let head = jsJSON("const r = document.getElementById('side-head').getBoundingClientRect(), t = document.getElementById('side-title').getBoundingClientRect(); return { x: r.right - 12, y: t.top + t.height / 2, tx: t.left + 4 };")
    var zones: [Bool] = []
    for (x, y) in [(300.0, 20.0), ((tg["left"] as? Double ?? 0) + 8, 20.0), (head["x"] as? Double ?? 0, head["y"] as? Double ?? 0), (head["tx"] as? Double ?? 0, head["y"] as? Double ?? 0), (300, 200)] as [(Double, Double)] {
        hover(x, y)
        zones.append(pressDrags(x, y))
    }
    check("1: the empty top row and heading drag the panel; the sidebar button, the folder's name and the page do not", zones == [true, false, true, false, false], "\(zones)")
    hover(300, 20)
    let light = lights.first.map { (Double($0.midX), lightsMid) } ?? (0, 0)
    check("1: a press on a traffic light is the button's, not a drag", viewer.panel.dragZone && !pressDrags(light.0, light.1) && pressDrags(300, 20))
    let ctrl = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 300, y: viewer.panel.frame.height - 20), modifierFlags: .control,
                                  timestamp: 0, windowNumber: viewer.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
    check("1: the window's top edge resizes and a control-click is the page's, not a drag", !pressDrags(300, 2) && ctrl.map { !viewer.panel.drags($0) } == true)
    hover(300, 200)
    var passes: [[Double]] = []
    var worst: [(String, Double)] = []
    var idx = 0
    for pass in 0..<3 {
        var times: [Double] = []
        let down = pass != 1
        for _ in 0..<30 {
            let next = idx + (down ? 1 : -1)
            guard next >= 0, next < rows.count else { break }
            let want = rows[next], prevMarker = marker(of: URL(fileURLWithPath: rows[idx]))
            let from = rec.renders.count, t0 = now()
            mark("arrow to \(want)")
            DispatchQueue.global(qos: .userInteractive).async { viewer.key(down ? "down" : "up", isRepeat: false) }
            let w = waitShown(want, from: from, t0: t0, timeout: 5)
            let p = page(), n = natives()
            let name = (want as NSString).lastPathComponent
            if w.painted == nil {
                check("1: ↓ shows \(name)", false, "never painted (last render \(rec.renders.last.map { "\($0.path) \($0.view)" } ?? "none"))")
            } else if pass == 0 {
                // What a person sees the moment it is painted: this file, highlighted in the sidebar, nothing of the last one.
                let own = marker(of: URL(fileURLWithPath: want))
                let textual = ["markdown", "code", "text", "json", "csv"].contains(w.view)
                let stray = n.shown.subtracting([nativeFor(w.view)].compactMap { $0 })
                var problems: [String] = []
                if p.path != want { problems.append("page shows \(p.path)") }
                if p.active != want { problems.append("sidebar highlights \((p.active as NSString).lastPathComponent)") }
                if let m = prevMarker, m != own, p.text.contains(m) { problems.append("still shows \(m) from the last file") }
                if textual, let m = own, !p.text.contains(m) { problems.append("its text (\(m)) is not on the page") }
                if !stray.isEmpty { problems.append("a stale native view is up: \(stray.sorted())") }
                if w.view == "pdf", let t = n.pdf?.document?.page(at: 0)?.string, let m = own, !t.contains(m) { problems.append("the PDF is another file's") }
                if w.view == "rtf", let t = n.text?.string, let m = own, !t.contains(m) { problems.append("the rich text is another file's") }
                check("1: ↓ \(name) (\(w.view)) painted in \(String(format: "%.0f", w.painted!)) ms, no stale frame", problems.isEmpty, problems.joined(separator: "; "))
            }
            times.append(w.painted ?? 9999)
            if pass == 2 { worst.append((name + " " + w.view, w.painted ?? 9999)) }
            idx = next
            spin(0.1)
        }
        passes.append(times)
    }
    let warm = passes.last ?? []
    info(String(format: "↓ painted, cold pass p50 %.0f max %.0f ms; warm pass p50 %.0f p95 %.0f max %.0f ms", pct(passes[0], 0.5), passes[0].max() ?? .nan,
                pct(warm, 0.5), pct(warm, 0.95), warm.max() ?? .nan))
    let slow = worst.filter { $0.1 > 100 }.map { "\($0.0) \(Int($0.1)) ms" }
    target("1: every file in the warm walk is painted within 100 ms", slow.isEmpty, slow.joined(separator: ", "))
    // ↓ held down: key repeats every 30 ms through PDFs, media, rich text and HTML; where it stops is what shows, alone.
    for (key, count) in [("home", 1), ("down", 23), ("up", 9), ("down", 14)] {
        for i in 0..<count {
            DispatchQueue.global(qos: .userInteractive).async { viewer.key(key, isRepeat: i > 0) }
            spin(0.03)
        }
        idx = key == "home" ? 0 : max(0, min(rows.count - 1, idx + (key == "down" ? count : -count)))
        spin(1.5)
        let want = rows[idx], p = page(), n = natives()
        let wantNative = nativeFor(p.view)
        var problems: [String] = []
        if p.path != want { problems.append("shows \((p.path as NSString).lastPathComponent)") }
        if p.active != want { problems.append("highlights \((p.active as NSString).lastPathComponent)") }
        if let w = wantNative, !n.shown.contains(w) { problems.append("its \(w) view is not up") }
        let stray = n.shown.subtracting([wantNative].compactMap { $0 })
        if !stray.isEmpty { problems.append("a stale native view is up: \(stray.sorted())") }
        if let pl = n.player?.player, pl.rate != 0 { problems.append("a player is playing") }
        check("1: \(key) held \(count)× stops on \((want as NSString).lastPathComponent), shown alone", problems.isEmpty, problems.joined(separator: "; "))
    }
    noErrors("1", page())
    close()
}

// ================= 2. the 50k-row CSV: sort, scroll to the bottom, the header stays =================
if flows.contains("2") {
    print("\n== 2. a 50,000-row CSV: sort by a column, scroll to the bottom, the header stays in place")
    let url = corpus.appendingPathComponent("big-50k.csv")
    let s = space([url], settle: 0.3)
    let shownRows = Int(s.page.head.components(separatedBy: " rows ×").first?.components(separatedBy: " · ").last?.replacingOccurrences(of: ",", with: "") ?? "") ?? 0
    check("2: the CSV opens as a table", s.view == "csv" && shownRows > 40000, "\(s.view) \(s.page.head)")
    known("BUG-csv-cap", "2: a 50,000-row CSV (2.4 MB) shows its 50,000 rows, as the README's CSV limit says", shownRows == 50000,
          "\(shownRows) rows, then '\(s.page.notes.joined(separator: " | "))'")
    info(String(format: "opened in %.0f ms", s.painted ?? .nan))
    let t0 = now()
    _ = js("document.querySelector('#doc .csv-sort[data-col=\"3\"]').click(); 0")
    var sorted = [String: Any]()
    spin(until: 5) {
        sorted = jsJSON("""
          const th = document.querySelectorAll('#doc table.csv thead th')[4];
          const vals = [...document.querySelectorAll('#doc table.csv tbody tr:not(.pad)')].slice(0, 30).map((tr) => +tr.children[4].textContent);
          return { sort: th.getAttribute('aria-sort'), vals };
          """)
        return sorted["sort"] as? String == "ascending"
    }
    let sortMs = ms(t0, now())
    let vals = sorted["vals"] as? [Double] ?? []
    check("2: a click on 'amount' sorts ascending, numbers as numbers", sorted["sort"] as? String == "ascending" && vals.count >= 20 && vals == vals.sorted(),
          "\(sorted)")
    target(String(format: "2: the sort redraws within 500 ms (%.0f ms)", sortMs), sortMs <= 500)
    _ = js("(() => { const s = document.querySelector('#doc .csv-scroll'); s.scrollTop = s.scrollHeight; return 0; })()")
    spin(0.4)
    _ = js("(() => { const s = document.querySelector('#doc .csv-scroll'); s.scrollTop = s.scrollHeight; return 0; })()")
    spin(0.4)
    let bottom = jsJSON("""
      const s = document.querySelector('#doc .csv-scroll'), sr = s.getBoundingClientRect();
      const head = document.querySelector('#doc table.csv thead th:nth-child(5)'), hr = head.getBoundingClientRect();
      const rows = [...document.querySelectorAll('#doc table.csv tbody tr:not(.pad)')];
      const seen = rows.filter((tr) => { const r = tr.getBoundingClientRect(); return r.bottom > hr.bottom + 2 && r.top < sr.bottom - 2; });
      const last = seen[seen.length - 1];
      const hit = document.elementFromPoint(hr.left + hr.width / 2, hr.top + hr.height / 2);
      return { atBottom: Math.abs(s.scrollTop + s.clientHeight - s.scrollHeight) < 2, headTop: hr.top - sr.top, headVisible: !!(hit && hit.closest('thead')),
        headText: head.textContent, lastIndex: last ? +last.getAttribute('aria-rowindex') : -1, lastAmount: last ? +last.children[4].textContent : null,
        seen: seen.length };
      """)
    check("2: scrolled to the bottom, the last row shown is on screen", bottom["atBottom"] as? Bool == true && bottom["lastIndex"] as? Int == shownRows + 1, "\(bottom)")
    let headTop = bottom["headTop"] as? Double ?? 99
    check("2: the header row stays at the top of the table and is not covered", abs(headTop) <= 2 && bottom["headVisible"] as? Bool == true
          && (bottom["headText"] as? String ?? "").contains("amount"), "\(bottom)")
    let maxAmount = vals.isEmpty ? nil : (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").dropFirst().prefix(shownRows).compactMap { Double($0.split(separator: ",")[3]) }.max()
    check("2: the last row holds the largest amount", maxAmount != nil && bottom["lastAmount"] as? Double == maxAmount, "\(String(describing: bottom["lastAmount"])) vs \(String(describing: maxAmount))")
    close()
    // Decimal commas in a semicolon file sort as numbers.
    let semi = space([corpus.appendingPathComponent("semicolon-decimal.csv")])
    _ = js("document.querySelector('#doc .csv-sort[data-col=\"1\"]').click(); 0")
    spin(0.3)
    let first = jsJSON("return { head: document.getElementById('kind').textContent, first: document.querySelector('#doc table.csv tbody tr:not(.pad) td').textContent };")
    check("2: semicolon CSV with decimal commas: named as such, sorted by value (0,99 first)",
          semi.view == "csv" && (first["head"] as? String ?? "").contains("semicolon-separated") && first["first"] as? String == "Kirschen", "view \(semi.view) \(first)")
    noErrors("2", page())
    close()
}

// ================= 3. broken JSON and 2 MB of minified JSON =================
if flows.contains("3") {
    print("\n== 3. broken JSON and a 2 MB minified JSON: both render, the tree works")
    let broken = space([corpus.appendingPathComponent("broken.json")])
    check("3: broken JSON is shown as is, with a note", broken.view == "json" && broken.page.notes.contains { $0.contains("Not valid JSON") }
          && broken.page.text.contains("\"spacebar\""), "\(broken.view) \(broken.page.notes)")
    noErrors("3 broken", broken.page)
    close()
    let big = space([corpus.appendingPathComponent("minified-2mb.json")], settle: 0.2, timeout: 15)
    info(String(format: "2 MB JSON painted in %.0f ms", big.painted ?? .nan))
    let tree = { jsJSON("""
      const rows = document.querySelectorAll('#doc .json-tree .jt-row');
      return { rows: rows.length, mode: document.querySelector('#doc .json-tree') ? 'Tree' : '',
        closed: [...document.querySelectorAll('#doc .jt-row[aria-expanded=false] .jt-tw')].length, deepest: Math.max(0, ...[...rows].map((r) => +r.getAttribute('aria-level'))) };
      """) }
    let t1 = tree()
    check("3: the 2 MB JSON opens as a tree", big.view == "json" && t1["mode"] as? String == "Tree" && (t1["rows"] as? Int ?? 0) >= 2, "\(t1)")
    target(String(format: "3: the 2 MB JSON is painted within 1 s (%.0f ms)", big.painted ?? .nan), (big.painted ?? 9999) <= 1000)
    var t0 = now()
    _ = js("document.querySelector('#doc .jt-row[aria-expanded=false] .jt-tw').click(); 0")
    spin(0.2)
    let t2 = tree()
    check("3: a click on a closed node opens it", (t2["rows"] as? Int ?? 0) > (t1["rows"] as? Int ?? 0), "\(t1) -> \(t2)")
    t0 = now()
    _ = js("[...document.querySelectorAll('#doc .json-all')].find((b) => b.dataset.open === '1').click(); 0")
    spin(until: 5) { (tree()["rows"] as? Int ?? 0) > 3000 }
    let t3 = tree(), expandMs = ms(t0, now())
    check("3: Expand All opens thousands of rows", (t3["rows"] as? Int ?? 0) > 3000, "\(t3)")
    target(String(format: "3: Expand All is drawn within 1 s (%.0f ms)", expandMs), expandMs <= 1000)
    _ = js("[...document.querySelectorAll('#doc .json-all')].find((b) => b.dataset.open === '0').click(); 0")
    spin(0.3)
    check("3: Collapse All closes it to the root", (tree()["rows"] as? Int ?? 99) <= 2, "\(tree())")
    t0 = now()
    // The stub writer keeps no settings, so Raw is applied in the page as settings.json would bring it.
    _ = js("sb.applySettings({ ...settings, rawJSON: true }); 0")
    spin(until: 5) { (jsJSON("return { n: (document.querySelector('#doc pre.code') || {textContent: ''}).textContent.length };")["n"] as? Int ?? 0) > 1_000_000 }
    let rawMs = ms(t0, now())
    let rawLen = jsJSON("return { n: (document.querySelector('#doc pre.code') || {textContent: ''}).textContent.length };")["n"] as? Int ?? 0
    check("3: Raw shows all of the 2 MB line", rawLen > 1_900_000, "\(rawLen) characters")
    target(String(format: "3: Raw is drawn within 1 s (%.0f ms)", rawMs), rawMs <= 1000)
    _ = js("sb.applySettings({ ...settings, rawJSON: false }); 0")
    noErrors("3 big", page())
    close()
    let nested = space([corpus.appendingPathComponent("nested-500.json")])
    _ = js("[...document.querySelectorAll('#doc .json-all')].find((b) => b.dataset.open === '1').click(); 0")
    spin(0.5)
    let deep = tree()
    check("3: 500 levels of nesting: a tree, Expand All reaches the bottom", nested.view == "json" && (deep["deepest"] as? Int ?? 0) >= 500, "\(deep)")
    noErrors("3 nested", page())
    close()
}

// ================= 4. every corpus file =================
if flows.contains("4") {
    print("\n== 4. every corpus file: shown by its kind and view, no page error, no crash")
    var prevMarker: String?
    let skip: Set<String> = ["loop-a", "loop-b", "unreadable.txt", "unreadable.md"]   // flow 7
    for name in corpusSpec.keys.sorted() where !skip.contains(name) {
        let spec = corpusSpec[name]!
        let url = corpus.appendingPathComponent(name)
        let views = spec["view"] as? [String] ?? []
        if spec["package"] as? Bool == true {
            // Space on a package is declined (Apple's preview takes it); in the sidebar it opens in the panel.
            request += 1
            let id = request, from = rec.renders.count
            DispatchQueue.global().async { viewer.show([url.path], requestID: id) { _ in } }
            spin(2)
            check("4: Space on \(name) (a package) is declined, as the README says", rec.renders.count == from && viewer.panel.alphaValue == 0,
                  "\(rec.renders.count - from) renders, panel alpha \(viewer.panel.alphaValue)")
            _ = space([corpus], any: true, settle: 0.5)
            let rowJS = "[...document.querySelectorAll('#side-list a.row')].find((a) => a.dataset.path === \(String(data: try! JSONSerialization.data(withJSONObject: [url.path]), encoding: .utf8)!)[0])"
            for _ in 0..<40 where (js("!!\(rowJS)") as? Bool) != true { _ = js("(() => { const l = document.getElementById('side-list'); (l.closest('#sidebar') || l).scrollBy(0, 300); l.scrollBy(0, 300); return 0; })()"); spin(0.05) }
            let from2 = rec.renders.count, t0 = now()
            _ = js("\(rowJS).click(); 0")
            let w = waitShown(url.path, from: from2, t0: t0)
            let n = natives()
            check("4: \(name) from the sidebar -> \(w.view)", views.contains(w.view) && (n.text?.string.contains(spec["contains"] as? String ?? "") ?? false),
                  "view \(w.view), text '\(n.text?.string.prefix(80) ?? "none")'")
            close()
            continue
        }
        let readies = readyCount()
        let s = space([url], settle: ["video", "audio", "quicklook", "info", "archive"].contains(views.first ?? "") ? 1.0 : 0.3, timeout: 15)
        let p = s.page
        var problems: [String] = []
        if s.rendered == nil { problems.append("never rendered") }
        if !views.contains(s.view) { problems.append("view \(s.view), expected \(views.joined(separator: "/"))") }
        if readyCount() != readies { problems.append("the page reloaded (its web process quit)") }
        if !p.errs.isEmpty { problems.append("page errors: \(p.errs.joined(separator: " | "))") }
        if let m = prevMarker, p.text.contains(m), marker(of: url) != m { problems.append("the last file's text (\(m)) is still on the page") }
        if let want = nativeFor(s.view), !s.natives.shown.contains(want) { problems.append("its native view is not up") }
        let stray = s.natives.shown.subtracting([nativeFor(s.view)].compactMap { $0 })
        if !stray.isEmpty { problems.append("stale native view: \(stray.sorted())") }
        if let c = spec["contains"] as? String {
            let hay = p.text + (s.natives.text?.string ?? "")
            if !hay.contains(c) { problems.append("'\(c)' not shown") }
        }
        if let e = spec["encoding"] as? String, !p.kindName.contains(e) { problems.append("kind '\(p.kindName)' does not name \(e)") }
        if let e = spec["encodingPrefix"] as? String, !p.kindName.contains(e) { problems.append("kind '\(p.kindName)' does not name \(e)") }
        if let k = spec["kindName"] as? String, p.kindName != k { problems.append("kind '\(p.kindName)', expected '\(k)'") }
        if let t = spec["truncated"] as? Bool {
            let noted = p.notes.contains { $0.contains("2 MB") || $0.lowercased().contains("first") }
            if t != noted { problems.append(t ? "no note that only the first 2 MB is shown" : "a truncation note on a file under the cap") }
        }
        if let rows = spec["rows"] as? Int, let cols = spec["cols"] as? Int {
            let shape = "\(rows.formatted()) \(rows == 1 ? "row" : "rows") × \(cols) \(cols == 1 ? "column" : "columns")"
            if !p.head.contains(shape) { problems.append("head '\(p.head)', expected \(shape)") }
        }
        if let h = spec["firstHeader"] as? String {
            let first = js("(document.querySelector('#doc table.csv thead .csv-h') || {}).textContent") as? String
            if first != h { problems.append("first header '\(first ?? "nil")'") }
        }
        if let mode = spec["mode"] as? String, spec["knownBug"] == nil {
            let pressed = js("(document.querySelector('#doc .json-tree') ? 'tree' : document.querySelector('#doc .notebook') ? 'notebook' : 'raw')") as? String
            if pressed != mode { problems.append("JSON mode \(pressed ?? "nil"), expected \(mode)") }
        }
        if let n = spec["images"] as? Int {
            let got = js("[...document.querySelectorAll('#doc img')].filter((i) => i.naturalWidth > 0).length") as? Int ?? 0
            if got < n { problems.append("\(got) of \(n) notebook images drawn") }
        }
        if let n = spec["pages"] as? Int, s.natives.pdf?.document?.pageCount != n { problems.append("\(s.natives.pdf?.document?.pageCount ?? 0) PDF pages") }
        if let n = spec["mermaid"] as? Int {
            let got = js("document.querySelectorAll('#doc pre.mermaid svg').length") as? Int ?? 0
            if got < n { problems.append("\(got) mermaid diagrams drawn") }
        }
        if let n = spec["katex"] as? Int {
            let got = js("document.querySelectorAll('#doc .katex-html').length") as? Int ?? 0
            if got < n { problems.append("\(got) formulas drawn") }
        }
        if let n = spec["tableRows"] as? Int {
            let got = js("document.querySelectorAll('#doc table tbody tr').length") as? Int ?? 0
            if got != n { problems.append("\(got) table rows") }
        }
        if spec["frontMatter"] as? Bool == true, (js("!!document.querySelector('#doc .frontmatter, #doc .frontmatter-raw')") as? Bool) != true {
            problems.append("no front matter block")
        }
        if let w = spec["width"] as? Int, let h = spec["height"] as? Int, s.view == "image" {
            let dims = js("(() => { const i = document.querySelector('#doc .img-stage img'); return i ? i.naturalWidth + 'x' + i.naturalHeight : ''; })()") as? String
            if dims != "\(w)x\(h)" { problems.append("image \(dims ?? "nil")") }
        }
        if let w = spec["width"] as? Int, let h = spec["height"] as? Int, s.view == "bitmap", !p.head.contains("\(w) × \(h)") { problems.append("caption '\(p.head)'") }
        if s.view == "archive" {
            spin(until: 8) { (js("document.querySelectorAll('#doc .arc-row, #doc .arc-dir, #doc .arc-file').length") as? Int ?? 0) > 0
                || (js("document.querySelector('#doc .viewer-note') ? 1 : 0") as? Int ?? 0) > 0 }
            let arc = jsJSON("return { rows: document.querySelectorAll('#doc [data-path]').length, text: document.getElementById('doc').textContent.slice(0, 400), notes: [...document.querySelectorAll('#doc .viewer-note')].map((n) => n.textContent) };")
            let notes = arc["notes"] as? [String] ?? []
            if notes.contains(where: { $0.contains("can’t be listed") }) { problems.append("archive not listed: \(notes)") }
            if spec["truncated"] as? Bool == true, !notes.contains(where: { $0.contains("5,000") || $0.lowercased().contains("first") }) {
                problems.append("no note that only the first 5,000 entries are listed: \(notes)")
            }
            if (arc["rows"] as? Int ?? 0) == 0 { problems.append("no entries listed") }
        }
        if name == ".env", UTType(filenameExtension: "env")?.identifier == "md.spacebar.type.env", (js("current.canOpen === true") as? Bool) != false {
            problems.append("offered to another app, though .env often holds secrets")
        }
        if name == "comments.jsonc" {
            let pressed = js("(document.querySelector('#doc .json-tree') ? 'tree' : document.querySelector('#doc .notebook') ? 'notebook' : 'raw')") as? String
            known("BUG-jsonc", "4: comments.jsonc (JSON with comments) opens as a tree", pressed == "tree" && !p.notes.contains { $0.contains("Not valid") },
                  "mode \(pressed ?? "nil"), notes \(p.notes)")
        }
        check(String(format: "4: %@ -> %@ (%@)%@", name.count > 60 ? String(name.prefix(57)) + "…" : name, s.view, p.kindName,
                     s.painted.map { String(format: ", %.0f ms", $0) } ?? ""), problems.isEmpty, problems.joined(separator: "; "))
        prevMarker = marker(of: url)
        close()
    }
    // A folder of 5,000 files.
    let many = corpus.appendingPathComponent("many")
    let m = space([many], any: true, settle: 0.5, timeout: 10)
    let listed = js("+(document.querySelector('#side-list a.row') || { getAttribute: () => 0 }).getAttribute('aria-setsize')") as? Int ?? 0
    info(String(format: "a folder of 5,000 files: %@ in %.0f ms, %d entries in the sidebar (%d rows drawn), more: '%@'", m.view, m.painted ?? .nan, listed, page().rows.count, page().more))
    check("4: a folder of 5,000 files opens on its overview and lists all 5,000", m.view == "overview" && listed == 5000 && page().errs.isEmpty, "\(m.view) \(listed) entries")
    close()
}

// ================= 5. the video-tests folder =================
if flows.contains("5") {
    print("\n== 5. video and audio formats: each plays or shows its info card")
    if let dir = videoDir, let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter({ !$0.hasPrefix(".") && $0 != "README.md" }).sorted(), !names.isEmpty {
        let dims: [String: (Int, Int)] = ["mp4-h264.mp4": (1280, 720), "mp4-hevc.mp4": (1280, 720), "mov-prores422.mov": (1280, 720), "mov-h264.mov": (1280, 720),
                                          "m4v-h264.m4v": (1280, 720), "3gp-h264.3gp": (352, 288), "mpg-mpeg2.mpg": (720, 480), "m2v-mpeg2.m2v": (720, 480),
                                          "portrait-9x16.mp4": (720, 1280), "4k-hevc.mov": (3840, 2160)]
        for name in names {
            let url = dir.appendingPathComponent(name)
            let ext = url.pathExtension.lowercased()
            let want = FileTypes.videoExtensions.contains(ext) ? "video" : FileTypes.audioExtensions.contains(ext) ? "audio" : "info"
            let s = space([url], settle: 0.2, timeout: 10)
            var problems: [String] = []
            var facts = ""
            if want == "info" {
                if s.view != "info" { problems.append("view \(s.view)") }
                if s.natives.player != nil { problems.append("a player is up") }
                facts = "info card: \(s.page.kindName)"
                if !s.page.notes.contains(where: { $0.contains("can’t play this format") }) { problems.append("no note that macOS can’t play it: \(s.page.notes)") }
                if s.page.kindName == "Document" { problems.append("named only \"Document\"") }
            } else {
                var item: AVPlayerItem?
                spin(until: 8) {
                    item = natives().player?.player?.currentItem
                    return item?.status == .readyToPlay || item?.status == .failed || rec.renders.last?.view == "info"
                }
                let final = rec.renders.last { $0.path == url.path }?.view ?? s.view
                if final != want { problems.append("view \(final)\(final == "info" ? " (" + page().notes.joined(separator: " ") + ")" : "")") }
                if let item, item.status == .readyToPlay, let player = natives().player?.player {
                    let d = item.duration.seconds
                    // An MPEG-2 elementary stream has no container clock: its length is estimated from the bit rate.
                    if !(abs(d - 6) < (ext == "m2v" ? 0.5 : 0.2)) { problems.append(String(format: "duration %.2f s", d)) }
                    facts = String(format: "%.2f s", d)
                    if want == "video" {
                        let sz = item.presentationSize
                        facts += " \(Int(sz.width))×\(Int(sz.height))"
                        if let e = dims[name], Int(sz.width) != e.0 || Int(sz.height) != e.1 { problems.append("size \(Int(sz.width))×\(Int(sz.height)), expected \(e.0)×\(e.1)") }
                    }
                    player.isMuted = true
                    player.play()
                    spin(1.2)
                    let t = player.currentTime().seconds
                    player.pause()
                    facts += String(format: ", played to %.2f s", t)
                    if !(t > 0.5) { problems.append(String(format: "did not play (at %.2f s after 1.2 s)", t)) }
                } else if final == want {
                    problems.append("the player never became ready (\(item.map { "\($0.status.rawValue) \($0.error?.localizedDescription ?? "")" } ?? "no item"))")
                }
            }
            check("5: \(name) -> \(want): \(facts)", problems.isEmpty, problems.joined(separator: "; "))
            close()
        }
    } else {
        print("SKIP 5: no video-tests folder (make_media.sh needs ffmpeg)")
    }
}

// ================= 6. a selection of 5 mixed files =================
if flows.contains("6") {
    print("\n== 6. a selection of 5 files: the sidebar shows exactly those")
    let picks = ["front-matter.md", "semicolon-decimal.csv", "shot.png", "anchors.yaml", "broken.json"].map { corpus.appendingPathComponent($0) }
    let s = space(picks, expect: picks[0], settle: 0.5)
    let rows = Set(s.page.rows.map { ($0 as NSString).lastPathComponent })
    check("6: the first of the selection is shown", s.page.path == picks[0].path && s.view == "markdown", s.page.path)
    check("6: the sidebar lists exactly the 5 selected files", rows == Set(picks.map(\.lastPathComponent)) && s.page.rows.count == 5,
          "\(s.page.rows.count) rows: \(rows.sorted())")
    spin(until: 5) { viewer.keys.session != nil }
    var seen: [String] = [s.page.path]
    for key in ["down", "down", "down", "down", "up", "up", "up", "up", "up", "up"] {
        let from = rec.renders.count
        DispatchQueue.global().async { viewer.key(key, isRepeat: false) }
        spin(until: 2) { rec.renders.count > from && rec.renders.last?.view != "loading" }
        spin(0.2)
        seen.append(page().path)
    }
    let outside = seen.filter { p in !picks.contains { $0.path == p } }
    check("6: ↓ and ↑ walk the selection and never leave it", outside.isEmpty && Set(seen).count == 5, "\(seen.map { ($0 as NSString).lastPathComponent })")
    noErrors("6", page())
    close()

    // Finder's list view with folders expanded: a selection across folders lists every item, under the folder holding them all.
    let sel = out.appendingPathComponent("sel")
    for (name, text) in [("a.md", "# A\n"), ("sub/b.md", "# B\n"), ("sub/other.md", "# Not selected\n"), ("sub/deeper/c.txt", "c\n")] {
        let u = sel.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! text.write(to: u, atomically: true, encoding: .utf8)
    }
    let across = ["a.md", "sub/b.md", "sub/deeper/c.txt"].map { sel.appendingPathComponent($0) }
    let a = space(across, expect: across[0], settle: 0.8)
    spin(until: 3) { (js("document.querySelectorAll('#side-list a.row.file').length") as? Int ?? 0) >= 3 }
    let fileRows = page().fileRows, files = Set(fileRows.map { String($0.dropFirst(sel.resolvingSymlinksInPath().path.count + 1)) })
    check("6: a selection across folders lists each selected file and no other", files == ["a.md", "sub/b.md", "sub/deeper/c.txt"], "\(files.sorted())")
    let head = js("[$('side-title').textContent, $('selpos').textContent].join('|')") as? String ?? ""
    let at = (fileRows.firstIndex(of: a.page.path) ?? -1) + 1
    check("6: the sidebar says how many are selected, and the toolbar where this one is", head == "3 Selected|\(at) of 3", head)
    noErrors("6 across", a.page)
    close()
    let far = space([across[0], URL(fileURLWithPath: "/etc/hosts")], expect: across[0], settle: 0.8)
    let note = js("[...document.querySelectorAll('#side-list .row-note')].map((n) => n.textContent).join('|')") as? String ?? ""
    check("6: a selected item too far away to list is counted in a note", note == "1 more selected item is in other folders", note)
    noErrors("6 far", far.page)
    close()
}

// ================= 7. hostile files =================
if flows.contains("7") {
    print("\n== 7. hostile files: an SVG with script, a symlink loop, unreadable files")
    rec.messages = []
    let svg = space([corpus.appendingPathComponent("script.svg")], settle: 1.0)
    let links = rec.messages.filter { $0["type"] as? String == "link" }
    check("7: an SVG with script is drawn as an image, its script inert", svg.view == "image" && svg.page.pwned == nil && links.isEmpty,
          "view \(svg.view), pwned \(svg.page.pwned ?? "nil"), links \(links)")
    close()
    rec.messages = []
    let md = space([corpus.appendingPathComponent("svg-embed.md")], settle: 1.0)
    let objects = js("document.querySelectorAll('#doc object, #doc embed, #doc iframe, #doc script').length") as? Int ?? -1
    check("7: the SVG embedded in Markdown (img, object, embed) runs nothing", md.page.pwned == nil && objects == 0
          && rec.messages.filter { $0["type"] as? String == "link" }.isEmpty, "pwned \(md.page.pwned ?? "nil"), \(objects) active elements")
    close()
    // The symlink loop, alone and in its folder.
    for name in ["loop-a"] {
        let url = corpus.appendingPathComponent(name)
        request += 1
        let id = request, from = rec.renders.count, t0 = now()
        mark("show symlink loop")
        DispatchQueue.global().async { viewer.show([url.path], requestID: id) { _ in } }
        spin(until: 6) { viewer.panel.alphaValue > 0 || rec.renders.count > from }
        spin(0.5)
        let p = page(), elapsed = ms(t0, now())
        let said = p.status + " " + p.text
        info(String(format: "symlink loop: %.0f ms, panel %@, page %@, status '%@'", elapsed, viewer.panel.alphaValue > 0 ? "shown" : "not shown",
                    p.blank ? "blank" : "'\(p.text.prefix(80))'", p.status))
        check("7: a symlink loop does not hang the viewer", elapsed < 6000 && (js("1") as? Int) == 1)
        known("BUG-loop", "7: a symlink loop says, visibly, that it cannot be opened", !p.blank && (said.lowercased().contains("can’t") || said.lowercased().contains("cannot")),
              p.blank ? "the panel is shown blank: the page is still hidden from the last close, the status '\(p.status)' with it" : "the panel shows '\(said.prefix(160))'")
        // The stub writer answers every reveal with false, so the status says so only when the reveal reached it.
        _ = js("post({ type: 'reveal', path: current.path }); 0")
        spin(0.5)
        check("7: the symlink loop's card can reveal the link in Finder", page().status.contains("could not show \(name) in Finder"), page().status)
        close()
    }
    let folder = space([corpus], any: true, settle: 0.8, timeout: 10)
    info(String(format: "the corpus folder (with a symlink loop and a link to itself): %@ in %.0f ms, %d sidebar rows", (folder.page.path as NSString).lastPathComponent, folder.painted ?? .nan, folder.page.rows.count))
    let loopListed = folder.page.rows.contains { $0.hasSuffix("/loop-a") }
    let loopRow = js("(() => { const r = [...document.querySelectorAll('#side-list a.row')].find((a) => a.dataset.path.endsWith('/loop-a')); return r ? [r.classList.contains('broken'), r.title].join('|') : ''; })()") as? String ?? ""
    check("7: the symlink loop is listed greyed, as a broken link", loopListed && loopRow.hasPrefix("true|") && loopRow.contains("Broken link"), loopRow)
    check("7: the folder holding a symlink loop and a link to itself opens and lists at once", folder.page.rows.count > 40 && (folder.painted ?? 9999) < 3000,
          "\(folder.page.rows.count) rows in \(Int(folder.painted ?? -1)) ms")
    close()
    // Unreadable files.
    let txt = space([corpus.appendingPathComponent("unreadable.txt")], settle: 0.5)
    let txtSays = (txt.page.notes + [txt.page.status]).joined(separator: " ")
    let offers = js("current.canOpen === true") as? Bool ?? true
    check("7: an unreadable (chmod 000) text file says it has no permission, and offers no app", txt.view == "info" && txtSays.contains("don’t have permission") && !offers,
          "view \(txt.view), card says '\(txt.page.text.replacingOccurrences(of: "\n", with: " ").prefix(160))'")
    close()
    let mdu = corpus.appendingPathComponent("unreadable.md")
    request += 1
    let id = request, from = rec.renders.count
    DispatchQueue.global().async { viewer.show([mdu.path], requestID: id) { _ in } }
    spin(until: 6) { firstRender(mdu.path, from: from) != nil }
    spin(0.5)
    let mp = page()
    check("7: an unreadable Markdown file says why it cannot be read", (mp.notes + [mp.status]).joined().contains("don’t have permission") || mp.text.contains("don’t have permission"),
          "view \(mp.view), notes \(mp.notes), status '\(mp.status)'")
    close()

    // A file that goes while it is on screen: deleted, renamed, or replaced by a save.
    let live = out.appendingPathComponent("live")
    try? FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
    let doomed = live.appendingPathComponent("doomed.md")
    try! "# Doomed\n\nText.\n".write(to: doomed, atomically: true, encoding: .utf8)
    _ = space([doomed], settle: 0.5)
    try! FileManager.default.removeItem(at: doomed)
    spin(2)
    let g = jsJSON("return { gone: document.documentElement.hasAttribute('data-gone'), open: $('edit').disabled, status: $('status').textContent, text: $('doc').textContent }")
    check("7: a file deleted while open says so, stays dimmed, and cannot be opened",
          g["gone"] as? Bool == true && g["open"] as? Bool == true && g["status"] as? String == "doomed.md was moved or deleted" && (g["text"] as? String ?? "").contains("Doomed"), "\(g)")
    try! "# Doomed again\n".write(to: doomed, atomically: true, encoding: .utf8)
    spin(until: 3) { (js("document.documentElement.hasAttribute('data-gone')") as? Bool) == false }
    let back = jsJSON("return { gone: document.documentElement.hasAttribute('data-gone'), status: $('status').textContent, text: $('doc').textContent }")
    check("7: the file coming back clears it", back["gone"] as? Bool == false && back["status"] as? String == "" && (back["text"] as? String ?? "").contains("again"), "\(back)")
    close()
    let before = live.appendingPathComponent("before.md"), after = live.appendingPathComponent("after.md")
    try! "# Renamed\n".write(to: before, atomically: true, encoding: .utf8)
    _ = space([before], settle: 0.5)
    try! FileManager.default.moveItem(at: before, to: after)
    spin(until: 4) { page().path == after.path }
    check("7: a file renamed while open is followed", page().path == after.path && (js("document.documentElement.hasAttribute('data-gone')") as? Bool) == false, page().path)
    close()
    let saved = live.appendingPathComponent("saved.txt")
    try! "one\n".write(to: saved, atomically: true, encoding: .utf8)
    _ = space([saved], settle: 0.5)
    try! "two\n".write(to: saved, atomically: true, encoding: .utf8)
    spin(2)
    check("7: a save that replaces the file is not taken for a deletion", (js("document.documentElement.hasAttribute('data-gone')") as? Bool) == false && page().text.contains("two"), page().text)
    close()
    let putBack = live.appendingPathComponent("put-back.txt"), aside = out.appendingPathComponent("put-back.txt")
    try! "kept\n".write(to: putBack, atomically: true, encoding: .utf8)
    _ = space([putBack], settle: 0.5)
    try! FileManager.default.moveItem(at: putBack, to: aside)
    spin(2)
    let wentAway = (js("document.documentElement.hasAttribute('data-gone')") as? Bool) == true
    try! FileManager.default.moveItem(at: aside, to: putBack)
    spin(until: 3) { (js("document.documentElement.hasAttribute('data-gone')") as? Bool) == false }
    let backState = js("[document.documentElement.hasAttribute('data-gone'), $('edit').disabled, $('status').textContent].join('|')") as? String ?? ""
    check("7: a file put back unchanged (Finder's Put Back) is no longer shown as gone", wentAway && backState.hasPrefix("false|false"), "went away \(wentAway), then \(backState)")
    close()
    let vanished = live.appendingPathComponent("vanished.md")
    let v = space([vanished], settle: 0.5)
    let vs = jsJSON("return { note: (document.querySelector('#doc .viewer-note') || {}).textContent, open: $('edit').textContent, action: $('edit').dataset.action }")
    check("7: a file missing at open says it is no longer there, and offers its folder", vs["note"] as? String == "This file is no longer there. It may have been moved or deleted."
          && vs["open"] as? String == "Show Folder" && vs["action"] as? String == "revealFolder", "\(vs)")
    noErrors("7 gone", v.page)
    close()
}

// ================= 8. missing images in Markdown =================
if flows.contains("8") {
    print("\n== 8. missing images in Markdown show the placeholder")
    let s = space([corpus.appendingPathComponent("missing-images.md")], settle: 0.5)
    var box: [String: Any] = [:]
    spin(until: 5) {
        box = jsJSON("""
          const boxes = [...document.querySelectorAll('#doc .img-missing')];
          return { n: boxes.length, alts: boxes.map((b) => (b.querySelector('.img-missing-alt') || {}).textContent),
            paths: boxes.map((b) => (b.querySelector('.img-missing-path') || {}).textContent),
            why: boxes.map((b) => [...b.querySelectorAll('.img-missing-why > *')].map((n) => n.textContent).join(' ')),
            present: [...document.querySelectorAll('#doc img')].map((i) => i.naturalWidth) };
          """)
        return box["n"] as? Int == 2
    }
    check("8: both missing images show a placeholder with their alt text and path", box["n"] as? Int == 2
          && (box["alts"] as? [String] ?? []).contains("Architecture diagram") && (box["paths"] as? [String] ?? []).contains("img/architecture.png"), "\(box)")
    check("8: the image that is there still renders", (box["present"] as? [Int] ?? []).contains(40), "\(box)")
    noErrors("8", s.page)
    close()
}

// ================= 10. typing a space in an edit keeps the panel open =================
// The writer's panel gets the keys, but the window server annotates them with Finder's pid, so the helper decides by the text
// session the viewer reports. The stub writer types "a b" in-process into the writer's edit text view, then Esc.
if flows.contains("10") {
    print("\n== 10. an edit in the panel: Space types a space and the panel stays open")
    let dir = out.appendingPathComponent("typing")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let f = dir.appendingPathComponent("type-a-b.txt")
    try! "hello\n".write(to: f, atomically: true, encoding: .utf8)
    let finderPid: Int32 = 583
    var route = KeyRoute()
    func helperRoutes(_ code: Int64) -> Route {
        let r = route.route(KeyEvent(code: code, targetPid: finderPid), panel: PanelContext(open: viewer.panel.isVisible, finderPid: finderPid,
                                                                                               viewerPid: getpid(), textSession: viewer.textSession))
        if r == .close { close() }
        return r
    }
    let s = space([f], settle: 0.4)
    check("10: the text file is shown", s.view == "text" && s.page.text.contains("hello"), "\(s.view) \(s.page.text.prefix(40))")
    check("10: no text session before the click", !viewer.textSession)
    _ = js("""
      { const p = document.querySelector('#doc pre.code[data-file-text]'), r = p.getBoundingClientRect();
        p.dispatchEvent(new MouseEvent('click', { bubbles: true, detail: 1, clientX: r.left + 2, clientY: r.top + 4 })); } 0
      """)
    spin(until: 3) { viewer.textSession }
    check("10: the click starts an edit and the viewer reports a text session", viewer.textSession)
    check("10: the helper passes the Space typed into the edit", helperRoutes(KeyCode.space) == .pass)
    check("10: and passes Esc, ↓ and ⌘W to the edit too", helperRoutes(KeyCode.escape) == .pass && helperRoutes(KeyCode.down) == .pass
          && route.route(KeyEvent(code: 13, chars: "w", mods: .command, targetPid: finderPid),
                         panel: PanelContext(open: true, finderPid: finderPid, viewerPid: getpid(), textSession: viewer.textSession)) == .pass)
    var saved = ""
    spin(until: 5) { saved = (try? String(contentsOf: f, encoding: .utf8)) ?? ""; return saved.contains("a b") }
    check("10: \"a b\" is typed and saved", saved.contains("a b") && saved.contains("hello"), saved)
    check("10: the page shows it", page().text.contains("a b"), String(page().text.prefix(60)))
    check("10: the panel stays open", viewer.panel.isVisible && viewer.panel.alphaValue > 0)
    spin(until: 4) { !viewer.textSession }
    check("10: Esc ends the edit, and the text session with it", !viewer.textSession)
    check("10: the next Space closes the panel", helperRoutes(KeyCode.space) == .close)
    spin(until: 2) { !viewer.panel.isVisible }
    check("10: closed", !viewer.panel.isVisible)
}

// ================= 9. screenshots of the top-left controls (FLOWS=9 SCEN_SHOTS=<dir>) =================
if flows.contains("9"), let dir = env["SCEN_SHOTS"] {
    print("\n== 9. the panel's top-left controls, light and dark, to \(dir)")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    func shot(_ name: String) {
        spin(0.4)
        guard let img = CGWindowListCreateImage(.null, .optionIncludingWindow, CGWindowID(viewer.panel.windowNumber), [.boundsIgnoreFraming]) else { return info("no image for \(name)") }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name).png"))
    }
    let reset = "document.getElementById('side-pop').hidden || document.getElementById('side-menu').click(); window.getSelection().removeAllRanges(); document.activeElement && document.activeElement.blur(); 0"
    for mode in ["light", "dark"] {
        NSApp.appearance = NSAppearance(named: mode == "dark" ? .darkAqua : .aqua)
        _ = space([corpus.appendingPathComponent("front-matter.md")], settle: 0.6)
        shot("panel-\(mode)-1-markdown")
        // WebKit takes no synthetic mouse-moved event off screen: the page's own :hover rules, applied to the folder name, with no
        // transition (a page off screen gets no rendering updates).
        _ = js("""
          { const rules = [], walk = (list) => { for (const r of list) {
              if (r instanceof CSSStyleRule) { if (r.selectorText.includes(':hover')) rules.push(r.cssText.replaceAll(':hover', '.sb-hover')); }
              else if (r instanceof CSSImportRule) { if (r.styleSheet) walk(r.styleSheet.cssRules); } else if (r.cssRules) walk(r.cssRules); } };
            for (const s of document.styleSheets) { try { walk(s.cssRules); } catch (e) {} }
            const sheet = new CSSStyleSheet(); sheet.replaceSync('* { transition: none !important; }\\n' + rules.join('\\n')); document.adoptedStyleSheets = [sheet];
            for (let e = document.getElementById('side-title'); e; e = e.parentElement) e.classList.add('sb-hover'); } 0
          """)
        shot("panel-\(mode)-1b-header-hover")
        _ = js("document.adoptedStyleSheets = []; document.querySelectorAll('.sb-hover').forEach((e) => e.classList.remove('sb-hover')); 0")
        _ = js("document.getElementById('side-title').click(); 0")
        spin(0.6)
        shot("panel-\(mode)-1c-title-clicked")
        _ = js("document.getElementById('side-menu').click(); 0")
        shot("panel-\(mode)-2-sort-menu")
        _ = js(reset)
        _ = js("{ const q = document.getElementById('side-q'); q.focus(); q.value = 'no'; q.dispatchEvent(new Event('input')); } 0")
        shot("panel-\(mode)-3-filter")
        _ = js("{ const q = document.getElementById('side-q'); q.value = ''; q.dispatchEvent(new Event('input')); q.blur(); } 0")
        _ = js("window.getSelection().selectAllChildren(document.body); 0")
        shot("panel-\(mode)-4-select-all")
        _ = js(reset)
        _ = js("document.getElementById('find-btn').click(); 0")
        shot("panel-\(mode)-5-find")
        _ = js("document.getElementById('find-close').click(); 0")
        // Applied in the page only: the stub writer saves no setting, so a click's change would be sent back undone.
        _ = js("sb.applySettings({ ...settings, sidebarCollapsed: true }); 0")
        shot("panel-\(mode)-6-sidebar-hidden")
        _ = js("sb.applySettings({ ...settings, sidebarCollapsed: false }); 0")
        close()
        _ = space([corpus.appendingPathComponent("anchors.yaml").deletingLastPathComponent().appendingPathComponent("analysis.ipynb")], settle: 0.6)
        shot("panel-\(mode)-7-notebook-seg")
        close()
        _ = space([corpus.appendingPathComponent("big-50k.csv")], settle: 0.6)
        shot("panel-\(mode)-11-csv-copy")
        close()
        _ = space([corpus.appendingPathComponent("big.swift")], settle: 0.6)
        _ = js("document.getElementById('copy').classList.add('done'); 0")
        shot("panel-\(mode)-12-code-copy")
        close()
        _ = space([corpus.appendingPathComponent("pages-500.pdf")], settle: 1.0)
        shot("panel-\(mode)-8-pdf")
        _ = js("document.getElementById('side-menu').click(); 0")
        shot("panel-\(mode)-9-pdf-sort-menu")
        _ = js(reset)
        _ = js("document.getElementById('aa').click(); 0")
        shot("panel-\(mode)-10-pdf-aa")
        _ = js("document.getElementById('aa').click(); 0")
        close()
    }
    NSApp.appearance = nil
}

// ================= 11. documents drawn natively take the panel's keys =================
if flows.contains("11") {
    print("\n== 11. PDF and RTF: page counter, go to page, find, zoom, paging and copy reach the document")
    func press(_ key: String, settle: Double = 0.3) { DispatchQueue.global().async { viewer.key(key, isRepeat: false) }; spin(settle) }
    let pdf = space([corpus.appendingPathComponent("pages-500.pdf")], settle: 1.0)
    let counter = { js("(document.querySelector('#kind .pdf-page') || {}).textContent || ''") as? String ?? "" }
    check("11: a PDF shows its page counter", counter() == "1 / 500", counter())
    press("pagedown", settle: 0.5)
    press("pagedown", settle: 0.5)
    check("11: Page Down moves the PDF, and the counter follows", counter() != "1 / 500" && counter().hasSuffix("/ 500"), counter())
    let z0 = web.pageZoom, s0 = natives().pdf?.scaleFactor ?? 0
    press("zoomIn")
    check("11: ⌘+ zooms the PDF, not the toolbar", web.pageZoom == z0 && (natives().pdf?.scaleFactor ?? 0) > s0, "page zoom \(web.pageZoom), pdf \(s0) -> \(natives().pdf?.scaleFactor ?? 0)")
    press("zoomReset")
    press("find")
    _ = js("findField.value = 'Page 42'; findInput('Page 42'); 0")
    spin(1)
    let found = js("[$('find').hidden, $('find-count').textContent].join('|')") as? String ?? ""
    check("11: ⌘F finds in the PDF and shows the count", found == "false|1 of 11", found)
    check("11: the first match is on screen", counter() == "42 / 500", counter())
    _ = js("findStep(1); 0")
    spin(0.5)
    check("11: ↵ goes to the next match", counter() == "420 / 500" && (js("$('find-count').textContent") as? String) == "2 of 11", counter())
    _ = js("closeFind(); 0")
    _ = js("document.querySelector('#kind .pdf-page').click(); 0")
    let gotoBar = js("[$('find').hidden, $('find-q').placeholder, $('find-count').textContent].join('|')") as? String ?? ""
    check("11: a click on the counter asks for a page", gotoBar == "false|Go to page|of 500", gotoBar)
    _ = js("findField.value = '250'; findInput('250'); findStep(1); 0")
    spin(0.5)
    check("11: go to page", counter() == "250 / 500" && (js("$('find').hidden") as? Bool) == true, counter())
    if let v = natives().pdf, let pg = v.currentPage, let sel = pg.selection(for: pg.bounds(for: .mediaBox)) {
        v.setCurrentSelection(sel, animate: false)
        press("copy", settle: 0.5)
        let st = page().status
        check("11: ⌘C with text selected in the PDF copies the text, not the file", st.contains("selection") || st == "Could not copy", st)
    }
    noErrors("11 pdf", pdf.page)
    close()
    let rtf = space([corpus.appendingPathComponent("letter.rtf")], settle: 0.8)
    let m0 = natives().text?.enclosingScrollView?.magnification ?? 0
    press("zoomIn")
    check("11: ⌘+ zooms the RTF document, not the toolbar", web.pageZoom == z0 && (natives().text?.enclosingScrollView?.magnification ?? 0) > m0)
    check("11: an RTF document has Find and Copy", (js("[$('find-btn').hidden, $('copy').hidden].join('|')") as? String) == "false|false")
    press("find")
    _ = js("findField.value = 'italics'; findInput('italics'); 0")
    spin(0.5)
    check("11: ⌘F finds in the RTF document", (js("$('find-count').textContent") as? String) == "1 of 1" && natives().text?.selectedRange().length == 7,
          js("$('find-count').textContent") as? String ?? "")
    _ = js("closeFind(); 0")
    noErrors("11 rtf", rtf.page)
    close()
}

if let e = js("(() => { const e = window.__errs || []; window.__errs = []; return e; })()") as? [String] { closingErrors += e }
check("no page errors while panels closed and reopened", closingErrors.isEmpty, closingErrors.joined(separator: " | "))
print("\n" + (failures == 0 ? "scenarios: all passed" : "scenarios: \(failures) failed") + (knownBugs.isEmpty ? "" : "; known bugs seen: \(Set(knownBugs).sorted().joined(separator: ", "))"))
exit(failures == 0 ? 0 : 1)
