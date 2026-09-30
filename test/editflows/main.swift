// Realistic editing sessions end to end: the real page, PreviewController and writer (EditSession, EditTextView, the writes),
// with keys typed in-process into the writer's edit text view by test/editflows/driver.swift, and every saved file checked byte
// for byte. Run in either host: "panel" (the Space helper's viewer, parked off screen, with the helper's key routing asked about
// each key with the text session the viewer reports, sampled while the keys are typed) or "quicklook" (the controller in a window off screen, as the extension hosts
// it). No window on screen, no key or mouse event outside the harness's own processes, nothing written outside a temp folder.
//   editflows <panel|quicklook> <work dir>        FLOWS=md,plain,...  CASES=substring   EF_DEBUG=1
import AppKit
import WebKit

let host = CommandLine.arguments[1]
let work = URL(fileURLWithPath: CommandLine.arguments[2]).resolvingSymlinksInPath()
let env = ProcessInfo.processInfo.environment
let only = env["CASES"].map { $0.split(separator: ",").map(String.init) }
let debug = env["EF_DEBUG"] != nil
let docs = work.appendingPathComponent("docs")
try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)

func now() -> Date { Date() }
func turn(_ until: Date) { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: until) } }
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { turn(min(end, Date().addingTimeInterval(0.01))) } }
func spin(until: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { turn(Date().addingTimeInterval(0.005)) } }

var failures = 0, passes = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if ok { passes += 1 } else { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") [\(host)] \(name)\(ok ? "" : ": \(detail())")")
    fflush(stdout)
}
func show(_ s: String) -> String { s.debugDescription.count > 300 ? String(s.debugDescription.prefix(300)) + "…" : s.debugDescription }

// ---- the host ----
WebHost.pageHost = host == "panel" ? "panel" : "quicklook"
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let parked = NSRect(x: -20000, y: -20000, width: 1100, height: 760)
var qlController: PreviewController?
var qlWindow: NSWindow?
if host == "panel" {
    Viewer.parkedFrame = parked
    _ = Viewer.shared
} else {
    let c = PreviewController()
    let w = NSWindow(contentRect: parked, styleMask: [.borderless], backing: .buffered, defer: false)
    w.contentViewController = c
    w.setFrame(parked, display: false)
    w.orderFrontRegardless()
    qlController = c
    qlWindow = w
}

/// Every message the page posts, then on to WebHost.
final class Recorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        WebHost.shared.userContentController(ucc, didReceive: m)
        if let b = m.body as? [String: Any] { messages.append(b) }
    }
}
let rec = Recorder()
let web = WebHost.shared.web
spin(until: 15) { WebHost.shared.ready }
guard WebHost.shared.ready else { print("FAIL the page never became ready"); exit(1) }
web.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
web.configuration.userContentController.add(rec, name: "sb")
web.evaluateJavaScript("""
  if (!window.__errs) { window.__errs = []; addEventListener('error', (e) => window.__errs.push(String(e.message) + ' :' + e.lineno));
    addEventListener('unhandledrejection', (e) => window.__errs.push('rejection: ' + e.reason)); } 0
  """)

func js(_ src: String, timeout: Double = 10) -> Any? {
    var out: Any?, done = false
    web.evaluateJavaScript(src) { r, e in out = r ?? e.map { "ERR \($0)" }; done = true }
    spin(until: timeout) { done }
    return done ? out : "TIMEOUT"
}
func jsJSON(_ body: String) -> [String: Any] {
    guard let s = js("JSON.stringify((() => { \(body) })())") as? String, let d = s.data(using: .utf8),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

// ---- the helper's routing of each key, as the text session really stands (the panel host) ----
let finderPid: Int32 = 583
var route = KeyRoute()
var misrouted: [String] = []
func panelOpen() -> Bool { host == "panel" ? Viewer.shared.panel.isVisible : true }
/// Asks the helper's KeyRoute about a key the user types into the edit, with the text session as the viewer last reported it.
/// Anything but .pass means the key would never reach the writer.
func routeKey(_ name: String, code: Int64, mods: HelperMods = [], chars: String = "") {
    guard host == "panel" else { return }
    let ctx = PanelContext(open: panelOpen(), finderPid: finderPid, viewerPid: getpid(), textSession: Viewer.shared.textSession)
    let down = route.route(KeyEvent(code: code, chars: chars, mods: mods, targetPid: finderPid), panel: ctx)
    _ = route.route(KeyEvent(code: code, chars: chars, down: false, mods: mods, targetPid: finderPid), panel: ctx)
    if down != .pass { misrouted.append("\(name)→\(down)") }
}
let keyCodes: [String: Int64] = ["return": 36, "enter": 76, "tab": 48, "backspace": 51, "delete": 117, "escape": 53, "space": 49,
                                 "left": 123, "right": 124, "down": 125, "up": 126, "home": 115, "end": 119, "pageup": 116, "pagedown": 121]
func routeSteps(_ steps: [[String: Any]]) {
    for s in steps {
        if let t = (s["type"] ?? s["burst"]) as? String {
            for c in t { c == "\n" ? routeKey("return", code: 36) : c == " " ? routeKey("space", code: 49) : routeKey(String(c), code: 0) }
        } else if let k = s["key"] as? String {
            let m = s["mods"] as? [String] ?? []
            var mods: HelperMods = []
            if m.contains("command") { mods.insert(.command) }
            if m.contains("shift") { mods.insert(.shift) }
            if m.contains("option") { mods.insert(.option) }
            if m.contains("control") { mods.insert(.control) }
            for _ in 0..<(s["times"] as? Int ?? 1) { routeKey(k, code: keyCodes[k] ?? 0, mods: mods, chars: k.count == 1 ? k : "") }
        }
    }
}

// ---- opening files ----
var request = 0
func rendered(_ path: String, since: Int) -> Bool {
    rec.messages.dropFirst(since).contains { $0["type"] as? String == "rendered" } && (js("current.path") as? String) == path
}
func open(_ url: URL) {
    let from = rec.messages.count
    if host == "panel" {
        request += 1
        let id = request
        DispatchQueue.global().async { Viewer.shared.show([url.path], requestID: id) { _ in } }
    } else {
        qlController!.start(url: url, reason: "prepare")
        qlController!.hostWillAppear()
        qlController!.hostAppeared()
    }
    spin(until: 8) { rendered(url.path, since: from) }
    spin(0.3)
}
func closeHost() {
    if host == "panel" { Viewer.shared.close() } else { qlController!.hostDisappearing() }
    spin(0.3)
}

// ---- clicks, as the page gets them ----
var cmdN = 0
var lastSession = 0
/// The session a click replaced: keys wait for a newer one.
var sessionFloor = 0
var lastResult: [String: Any] = [:]
/// A click in the page: on block `sel` (a CSS selector, in #doc), at the end of its text on line `line` (the last by default),
/// at its start, or on the `char`-th character's left half. Returns the page's edit state after it.
@discardableResult
func click(_ sel: String, at: String = "end", char: Int = 0) -> [String: Any] {
    // A click in the editor moves the caret in the same session; any other click starts a new one.
    let seqBefore = js("editing ? editing.seq : -1") as? Int ?? -1
    let floorBefore = sessionFloor
    sessionFloor = lastSession
    let r = jsJSON("""
      const b = document.querySelector(\(show(sel))); if (!b) return { error: 'no ' + \(show(sel)) };
      const walk = document.createTreeWalker(b, NodeFilter.SHOW_TEXT); const nodes = [];
      while (walk.nextNode()) if (walk.currentNode.textContent.replace(/[\\u200B\\n]/g, '').length) nodes.push(walk.currentNode);
      let x, y;
      if (!nodes.length) { const r = b.getBoundingClientRect(); x = r.left + 4; y = r.top + r.height / 2; }
      else if (\(show(at)) === 'char') {
        const all = []; const w2 = document.createTreeWalker(b, NodeFilter.SHOW_TEXT); while (w2.nextNode()) all.push(w2.currentNode);
        let n = \(char); let node = null, off = 0;
        for (const t of all) { if (n < t.length) { node = t; off = n; break; } n -= t.length; }
        if (!node) { node = nodes[nodes.length - 1]; off = node.length - 1; }
        const g = document.createRange(); g.setStart(node, off); g.setEnd(node, off + 1);
        const r = g.getBoundingClientRect(); x = r.left + 1; y = (r.top + r.bottom) / 2;
      } else {
        const t = \(show(at)) === 'start' ? nodes[0] : nodes[nodes.length - 1];
        const g = document.createRange(); g.selectNodeContents(t); const rs = [...g.getClientRects()].filter((q) => q.width > 0);
        const r = \(show(at)) === 'start' ? rs[0] : rs[rs.length - 1];
        x = \(show(at)) === 'start' ? r.left + 0.5 : r.right + 3; y = (r.top + r.bottom) / 2;
      }
      window.scrollTo(0, 0);
      const t = document.elementFromPoint(x, y) || b;
      t.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true, detail: 1, clientX: x, clientY: y }));
      return { x, y, editing: !!editing, seq: editing ? editing.seq : -1, caret: editing ? editing.selStart : -1 };
      """)
    if r["seq"] as? Int == seqBefore { sessionFloor = floorBefore }
    if host == "panel", r["editing"] as? Bool == true { spin(until: 2) { Viewer.shared.textSession } }
    spin(0.25)
    return r
}

// ---- keys, through the writer ----
/// Runs `steps` in the writer (see driver.swift) once its session is newer than the last one used, and returns its state.
@discardableResult
func keys(_ steps: [[String: Any]], gap: Double = 30, settle: Double = 350) -> [String: Any] {
    routeSteps(steps)
    cmdN += 1
    let n = cmdN
    let nonce = UUID().uuidString
    var cmd: [String: Any] = ["n": n, "steps": steps, "gap": gap, "settle": settle, "nonce": nonce]
    cmd["afterSession"] = sessionFloor
    try! JSONSerialization.data(withJSONObject: cmd).write(to: work.appendingPathComponent("cmd.json"), options: .atomic)
    let note = "md.spacebar.test.editflows.cmd.\(env["EDITFLOWS_TOKEN"] ?? "")" as CFString
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFNotificationName(note), nil, nil, true)
    var result: [String: Any] = [:]
    var dropped = false
    spin(until: 30) {
        // The text session must hold for every key while they are typed, a split's or merge's hold included.
        if host == "panel", !Viewer.shared.textSession, (js("!!editing") as? Bool) == true { dropped = true }
        guard let d = try? Data(contentsOf: work.appendingPathComponent("result.json")),
              let r = try? JSONSerialization.jsonObject(with: d) as? [String: Any], r["nonce"] as? String == nonce else { return false }
        result = r
        return true
    }
    if result.isEmpty { check("keys \(n): the writer answered", false, "no answer in 30 s") }
    if let e = result["error"] as? String { check("keys \(n): the writer typed them", false, e) }
    if dropped, !(steps.last.map { $0["key"] as? String == "escape" } ?? false) { misrouted.append("the text session dropped while typing") }
    if let s = result["session"] as? Int, s > 0 { lastSession = s }
    lastResult = result
    if debug { print("    keys → \(show(result["text"] as? String ?? "?")) sel \(result["selStart"] ?? "?") session \(result["session"] ?? "?") \(result["error"] ?? "")") }
    return result
}
func t(_ s: String) -> [String: Any] { ["type": s] }
func k(_ name: String, _ mods: String..., times: Int = 1) -> [String: Any] { ["key": name, "mods": mods, "times": times] }

/// The file's bytes once they stop changing and match `want` (or the timeout passes).
func settled(_ url: URL, _ want: Data, timeout: Double = 4) -> Data {
    var got = Data()
    spin(until: timeout) { got = (try? Data(contentsOf: url)) ?? Data(); return got == want }
    return got
}
func bytes(_ s: String) -> Data { Data(s.utf8) }
func pageEdit() -> [String: Any] { jsJSON("return editing ? { text: editing.text, sel: editing.selStart, len: editing.selLen, whole: !!editing.whole } : {}") }
/// The page shows what the writer holds: the editor's text and caret (or selection) are the writer's buffer and selection, and
/// what is on screen in the editor is that text with the caret at that offset.
func mirrored(_ name: String) {
    guard let text = lastResult["text"] as? String, let sel = lastResult["selStart"] as? Int, let len = lastResult["selLen"] as? Int,
          lastResult["session"] as? Int ?? -1 > 0 else { return check("\(name): the writer reported its buffer", false, "\(lastResult)") }
    spin(0.1)
    let p = jsJSON("""
      if (!editing) return { none: true };
      const el = editing.whole ? document.querySelector('#doc pre.text-editing code') || document.querySelector('#doc pre.text-editing') : document.querySelector('#doc > .md-editing');
      if (!el) return { text: editing.text, sel: editing.selStart, len: editing.selLen, noEl: true };
      const mark = el.querySelector('.caret, .sel');
      const pre = document.createRange(); pre.selectNodeContents(el); if (mark) pre.setEndBefore(mark);
      return { text: editing.text, sel: editing.selStart, len: editing.selLen, shown: el.textContent.replace(/\\u200B/g, ''),
               at: mark ? pre.toString().replace(/\\u200B/g, '').length : -1 };
      """)
    if p["none"] as? Bool == true { return check("\(name): the page is still editing", false, "the edit ended on the page") }
    let ok = p["text"] as? String == text && p["sel"] as? Int == sel && p["len"] as? Int == len && p["shown"] as? String == text && p["at"] as? Int == sel
    check("\(name): the page mirrors the writer's text and caret", ok,
          "writer \(show(text)) sel \(sel)+\(len); page \(show(p["text"] as? String ?? "?")) sel \(p["sel"] ?? "?")+\(p["len"] ?? "?"), shown \(show(p["shown"] as? String ?? "?")) caret at \(p["at"] ?? "?")")
}

/// Ends the edit as Esc does and waits for the page and the host to settle.
func escape() {
    keys([k("escape")], settle: 250)
    spin(until: 3) { (js("!!editing") as? Bool) == false }
    spin(0.2)
}

var caseN = 0
/// One case: a fresh file in its own folder, shown, clicked at `sel`, then `run`; the file's bytes must become `want`.
func edit(_ name: String, file: String, _ text: Data, prepare: () -> Void = {}, click sel: String, at: String = "end", char: Int = 0,
          want: Data, pageWants: String? = nil, _ run: () -> Void) {
    if let only, !only.contains(where: { name.contains($0) }) { return }
    caseN += 1
    let dir = docs.appendingPathComponent("c\(caseN)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent(file)
    try! text.write(to: url)
    misrouted = []
    rec.messages.removeAll()
    _ = js("window.__errs = []; 0")
    open(url)
    prepare()
    let c = click(sel, at: at, char: char)
    guard c["editing"] as? Bool == true else {
        check(name, false, "the click did not start an edit: \(c)")
        closeHost()
        return
    }
    lastResult = [:]
    run()
    let got = settled(url, want)
    if (js("!!editing") as? Bool) == true { mirrored(name) }
    let s = (String(data: got, encoding: .utf8) ?? "<\(got.count) bytes>")
    check(name, got == want, "file is \(show(s)), want \(show(String(data: want, encoding: .utf8) ?? "?"))")
    if let pageWants {
        let p = pageEdit()
        check("\(name): the page's editor shows it", p["text"] as? String == pageWants, "page editor \(show(p["text"] as? String ?? "<none>"))")
    }
    if !misrouted.isEmpty { check("\(name): the helper passes every key to the edit", false, misrouted.joined(separator: ", ")) }
    let errs = js("window.__errs") as? [String] ?? []
    if !errs.isEmpty { check("\(name): no page errors", false, errs.joined(separator: " | ")) }
    if (js("!!editing") as? Bool) == true { escape() }
    if got == want {
        let after = settled(url, want, timeout: 1.5)
        check("\(name): the file stays so once the edit ends", after == want, show(String(data: after, encoding: .utf8) ?? "?"))
    }
    closeHost()
}
func md(_ s: String) -> Data { bytes(s) }

/// A snapshot of the page, to EF_SHOTS/<name>.png (for looking at a case, not graded).
func shot(_ name: String) {
    guard let dir = env["EF_SHOTS"] else { return }
    var done = false
    web.takeSnapshot(with: nil) { img, _ in
        if let img, let t = img.tiffRepresentation, let b = NSBitmapImageRep(data: t)?.representation(using: .png, properties: [:]) {
            try? b.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(host)-\(name).png"))
        }
        done = true
    }
    spin(until: 5) { done }
}
/// The raw text view of a formatted file (JSON, CSV): the toolbar's Raw button, as a click.
func raw() {
    guard (js("!!document.querySelector('#doc pre.code[data-file-text]')") as? Bool) != true else { return }
    let from = rec.messages.count
    _ = js("document.getElementById('raw').click(); 0")
    spin(until: 5) { rec.messages.dropFirst(from).contains { $0["type"] as? String == "rendered" } || (js("!!document.querySelector('#doc pre.code[data-file-text]')") as? Bool) == true }
    spin(0.3)
}
func paste(_ s: String) -> [[String: Any]] { [["paste": s], k("v", "command")] }
let code = "#doc pre.code[data-file-text]"

print("editflows [\(host)]: \(work.path)")

// ================= Markdown blocks =================
edit("md: a paragraph typed with Enter between its lines", file: "notes.md", md("Intro\n"), click: "#doc > p",
     want: md("Intro one\n\ntwo\n\nthree\n"), pageWants: "three") {
    keys([t(" one\ntwo\nthree")])
}
edit("md: Enter in the middle of a paragraph", file: "mid.md", md("Hello world\n"), click: "#doc > p", want: md("Hello\n\nbig world\n"), pageWants: "big world") {
    keys([k("left", times: 6), t("\nbig")])
}
edit("md: Enter at the start of a paragraph opens one above", file: "start.md", md("Alpha\n\nBeta\n"), click: "#doc > p:nth-of-type(2)", at: "start",
     want: md("Alpha\n\nNew\n\nBeta\n")) {
    keys([t("\nNew")])
}
edit("md: Enter twice at the end of a paragraph leaves a blank line", file: "twice.md", md("Para\n\nNext\n"), click: "#doc > p",
     want: md("Para\n\n\nx\n\nNext\n"), pageWants: "\nx") {
    keys([t("\n\nx")])
}
edit("md: Enter three times after a heading, then typing", file: "thrice.md", md("# Title\n\nBody\n"), click: "#doc > h1",
     want: md("# Title\n\n\n\nSub\n\nBody\n"), pageWants: "\n\nSub") {
    keys([t("\n\n\nSub")])
    shot("heading-enter-thrice")
}
edit("md: Enter at the end of a heading opens a paragraph below", file: "head.md", md("# Title\n\nBody\n"), click: "#doc > h1",
     want: md("# Title\n\nSub\n\nBody\n"), pageWants: "Sub") {
    keys([t("\nSub")])
    shot("heading-enter")
}
edit("md: Enter at the end of a heading, then Esc, leaves the file as it was", file: "head2.md", md("# Title\n\nBody\n"), click: "#doc > h1",
     want: md("# Title\n\nBody\n")) {
    keys([t("\n")])
    shot("heading-enter-empty")
    escape()
}
edit("md: Enter twice after a paragraph, then Esc, leaves the file as it was", file: "twiceesc.md", md("Para\n\nNext\n"), click: "#doc > p",
     want: md("Para\n\nNext\n")) {
    keys([t("\n\n")])
    escape()
}
edit("md: Backspace in the blank line a second Enter made takes it back", file: "twicebs.md", md("Para\n\nNext\n"), click: "#doc > p",
     want: md("Para\n\nx\n\nNext\n")) {
    keys([t("\n\n"), k("backspace"), t("x")])
}
edit("md: Backspace in the empty paragraph Enter opened joins it back", file: "emptybs.md", md("Para\n\nNext\n"), click: "#doc > p",
     want: md("Para!\n\nNext\n")) {
    keys([t("\n"), k("backspace"), t("!")])
}
edit("md: blank lines typed with Enter stay when that paragraph is split", file: "blanksplit.md", md("Para\n"), click: "#doc > p",
     want: md("Para\n\n\nSub\n\nMore\n")) {
    keys([t("\n\nSub\nMore")])
}
edit("md: a list continues on Enter and ends on Enter in an empty item", file: "list.md", md("- one\n- two\n"), click: "#doc > ul",
     want: md("- one\n- two\n- three\n\nafter\n")) {
    keys([t("\nthree\n\nafter")])
}
edit("md: a numbered list counts on", file: "num.md", md("1. first\n"), click: "#doc > ol", want: md("1. first\n2. second\n3. third\n")) {
    keys([t("\nsecond\nthird")])
}
edit("md: a task list continues with an open box", file: "task.md", md("- [ ] a\n"), click: "#doc > ul", want: md("- [ ] a\n- [ ] b\n")) {
    keys([t("\nb")])
}
edit("md: Enter inside a code fence is a line break", file: "fence.md", md("```js\nlet a = 1\n```\n"), click: "#doc > div.blk",
     want: md("```js\nlet a = 1\nlet b = 2\n```\n")) {
    keys([t("\nlet b = 2")])
}
edit("md: Enter inside a code fence keeps the line's indentation", file: "fence2.md", md("```\nif x {\n    y\n```\n"), click: "#doc > div.blk",
     want: md("```\nif x {\n    y\n    z\n```\n")) {
    keys([t("\nz")])
}
edit("md: Enter at the end of a table opens a paragraph below", file: "table.md", md("| a | b |\n|---|---|\n| 1 | 2 |\n"), click: "#doc > table",
     want: md("| a | b |\n|---|---|\n| 1 | 2 |\n\nafter\n")) {
    keys([t("\nafter")])
}
edit("md: a quote continues on Enter and ends on an empty line", file: "quote.md", md("> quoted\n"), click: "#doc > blockquote",
     want: md("> quoted\n> more\n\nout\n")) {
    keys([t("\nmore\n\nout")])
}
edit("md: Shift-Enter is a line break in the paragraph", file: "soft.md", md("Line one\n"), click: "#doc > p", want: md("Line one\ntwo\n")) {
    keys([k("return", "shift"), t("two")])
}
edit("md: Backspace right after Enter joins the paragraph again", file: "join.md", md("Alpha beta\n"), click: "#doc > p", want: md("Alpha beta!\n")) {
    keys([k("return"), k("backspace"), t("!")])
}
edit("md: Backspace at the start of a paragraph joins it to the one above", file: "merge.md", md("Alpha\n\nBeta\n"), click: "#doc > p:nth-of-type(2)",
     at: "start", want: md("Alpha-Beta\n")) {
    keys([k("backspace"), t("-")])
}
edit("md: forward delete in a line", file: "fdel.md", md("Alpha\n"), click: "#doc > p", want: md("Alha\n")) {
    keys([k("left", times: 3), k("delete")])
}
edit("md: ⌥⌫ deletes a word and ⌘⌫ to the line's start", file: "wdel.md", md("one two three\n"), click: "#doc > p", want: md("x\n")) {
    keys([k("backspace", "option")])
    keys([k("backspace", "command"), t("x")])
}
edit("md: ⌥← ⌘← ⌘→ move by word and line", file: "arrows.md", md("one two three\n"), click: "#doc > p", want: md("Sone two XthreeE\n")) {
    keys([k("left", "option"), t("X"), k("left", "command"), t("S"), k("right", "command"), t("E")])
}
edit("md: ⌥→ moves past a word", file: "arrows2.md", md("one two\n"), click: "#doc > p", at: "start", want: md("one, two\n")) {
    keys([k("right", "option"), t(",")])
}
edit("md: ⌘A selects the block, typing replaces it", file: "all.md", md("Some text\n\nOther\n"), click: "#doc > p", want: md("New\n\nOther\n")) {
    keys([k("a", "command"), t("New")])
}
edit("md: ⇧⌥← selects a word, typing replaces it", file: "sel.md", md("Hello world\n"), click: "#doc > p", want: md("Hello there\n")) {
    keys([k("left", "shift", "option"), t("there")])
}
edit("md: ⇧← twice then typing replaces two characters", file: "sel2.md", md("abcdef\n"), click: "#doc > p", want: md("abcdX\n")) {
    keys([k("left", "shift", times: 2), t("X")])
}
edit("md: pasting several lines", file: "paste.md", md("Start\n"), click: "#doc > p", want: md("Starta\nb\n")) {
    keys(paste("a\nb"))
}
edit("md: cut, then paste at the start", file: "cut.md", md("alpha beta\n"), click: "#doc > p", want: md("betaalpha \n")) {
    let r = keys([k("left", "shift", "option"), k("x", "command"), k("left", "command"), k("v", "command")])
    check("md: cut puts the word on the pasteboard", r["board"] as? String == "beta", "\(r["board"] ?? "nil")")
}
edit("md: copy leaves the text", file: "copy.md", md("alpha beta\n"), click: "#doc > p", want: md("alpha betabeta\n")) {
    let r = keys([k("left", "shift", "option"), k("c", "command"), k("right"), k("v", "command")])
    check("md: copy puts the word on the pasteboard", r["board"] as? String == "beta", "\(r["board"] ?? "nil")")
}
edit("md: undo and redo typing", file: "undo.md", md("Para\n"), click: "#doc > p", want: md("Para x\n")) {
    keys([t(" x"), k("z", "command")])
    check("md: ⌘Z takes the typing back", settled(docs.appendingPathComponent("c\(caseN)/undo.md"), md("Para\n")) == md("Para\n"))
    keys([k("z", "command", "shift")])
}
edit("md: undo after Enter takes back what was typed in the new paragraph", file: "undo2.md", md("Para\n"), click: "#doc > p", want: md("Para x\n\nz\n")) {
    keys([t(" x\ny"), k("z", "command"), t("z")])
}
edit("md: a dead key composes é", file: "ime.md", md("caf\n"), click: "#doc > p", want: md("café\n")) {
    keys([["marked": "´"], ["commit": "é"]])
}
edit("md: emoji, and Backspace takes the whole emoji", file: "emoji.md", md("Hi\n"), click: "#doc > p", want: md("Hi !\n")) {
    keys([["commit": " 👍🏽"]])
    check("md: the emoji is saved", settled(docs.appendingPathComponent("c\(caseN)/emoji.md"), md("Hi 👍🏽\n")) == md("Hi 👍🏽\n"))
    keys([k("backspace"), t("!")])
}
edit("md: a CRLF file keeps CRLF through Enter", file: "crlf.md", md("A\r\n\r\nB\r\n"), click: "#doc > p", want: md("A\r\n\r\nx\r\n\r\nB\r\n")) {
    keys([t("\nx")])
}
edit("md: a file without a final newline stays without one", file: "nofinal.md", md("Para"), click: "#doc > p", want: md("Para\n\nx")) {
    keys([t("\nx")])
}
edit("md: Esc, then a click back in, keeps typing", file: "esc.md", md("Note\n"), click: "#doc > p", want: md("Note one two\n")) {
    keys([t(" one")])
    escape()
    click("#doc > p")
    keys([t(" two")])
}
edit("md: typing fast, Enter included, in one run-loop turn", file: "fast.md", md("Para\n"), click: "#doc > p", want: md("Para quick\n\nfox jumps\n")) {
    keys([["burst": " quick\nfox jumps"]], gap: 0)
}
edit("md: typing fast in a list", file: "fastlist.md", md("- a\n"), click: "#doc > ul", want: md("- a\n- b\n- c\n")) {
    keys([["burst": "\nb\nc"]], gap: 0)
}

let agents = "# AGENTS.md\n\nInstructions for Codex and other coding agents.\n\n## Setup\n```bash\nnpm install\nnpm test\n```\n\n## Rules\n- Run `npm test` before every commit.\n- Keep PRs under 300 lines.\n"
edit("md: a real AGENTS.md: type after the heading, Enter, a new paragraph", file: "AGENTS.md", md(agents), click: "#doc > h1",
     want: md(agents.replacingOccurrences(of: "# AGENTS.md\n", with: "# AGENTS.md for agents\n\nRead this first.\n"))) {
    keys([t(" for agents\nRead this first.")])
}
edit("md: a real AGENTS.md: Enter at the end of a list item in it", file: "AGENTS.md", md(agents), click: "#doc > ul",
     want: md(agents.replacingOccurrences(of: "300 lines.\n", with: "300 lines.\n- Ask first.\n"))) {
    keys([t("\nAsk first.")])
}
edit("md: a real AGENTS.md: Enter in its code fence", file: "AGENTS.md", md(agents), click: "#doc > div.blk",
     want: md(agents.replacingOccurrences(of: "npm test\n```", with: "npm test\nnpm run lint\n```"))) {
    keys([t("\nnpm run lint")])
}

for gap in [4.0, 12.0, 25.0] {
    edit("md: a paragraph with Enters typed \(Int(gap)) ms apart", file: "gap\(Int(gap)).md", md("# Notes\n\nFirst\n"), click: "#doc > p",
         want: md("# Notes\n\nFirst line\n\nsecond line\n\n- a\n- b\n\nend\n")) {
        keys([t(" line\nsecond line\n- a\nb\n\nend")], gap: gap)
    }
}
if only == nil || only!.contains(where: { "md: switching files mid-edit saves what was typed".contains($0) }) {
    caseN += 1
    let dir = docs.appendingPathComponent("c\(caseN)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("first.md"), b = dir.appendingPathComponent("second.md")
    try! md("First\n").write(to: a)
    try! md("Second\n").write(to: b)
    open(a)
    click("#doc > p")
    keys([["burst": " typed\nfast"]], gap: 0, settle: 0)
    open(b)
    check("md: switching files mid-edit saves what was typed", settled(a, md("First typed\n\nfast\n")) == md("First typed\n\nfast\n"),
          show(String(data: (try? Data(contentsOf: a)) ?? Data(), encoding: .utf8) ?? ""))
    check("md: and the next file is shown, not edited", (js("current.path") as? String) == b.path && (js("!!editing") as? Bool) == false)
    closeHost()
}
if only == nil || only!.contains(where: { "txt: switching files mid-edit saves what was typed".contains($0) }) {
    caseN += 1
    let dir = docs.appendingPathComponent("c\(caseN)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let a = dir.appendingPathComponent("first.txt"), b = dir.appendingPathComponent("second.txt")
    try! md("one\n").write(to: a)
    try! md("two\n").write(to: b)
    open(a)
    click(code, at: "start")
    keys([["burst": "zero\n"]], gap: 0, settle: 0)
    open(b)
    check("txt: switching files mid-edit saves what was typed", settled(a, md("zero\none\n")) == md("zero\none\n"),
          show(String(data: (try? Data(contentsOf: a)) ?? Data(), encoding: .utf8) ?? ""))
    closeHost()
}

edit("md: after Enter, a click in the new paragraph moves the caret there", file: "clickin.md", md("Alpha beta\n"), click: "#doc > p",
     want: md("Alpha beta\n\noneX two\n"), pageWants: "oneX two") {
    keys([t("\none two")])
    click("#doc > .md-editing", at: "char", char: 3)
    keys([t("X")])
}

// ================= whole text files (plain mode) =================
edit("txt: Enter at the end of a line", file: "a.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\nnew\nline2\n")) {
    keys([k("right", "command"), t("\nnew")])
}
edit("txt: Enter at the start of a line", file: "b.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\n\nxline2\n")) {
    keys([k("down"), t("\nx")])
}
edit("txt: Enter in the middle of a line", file: "c.txt", md("line1\nline2\n"), click: code, at: "start", want: md("lin\ne1\nline2\n")) {
    keys([k("right", times: 3), t("\n")])
}
edit("txt: Enter twice makes a blank line", file: "d.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\n\nx\nline2\n")) {
    keys([k("right", "command"), t("\n\nx")])
}
edit("txt: Backspace joins a line to the one above", file: "e.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1line2\n")) {
    keys([k("down"), k("backspace")])
}
edit("txt: forward delete joins the next line", file: "f.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1line2\n")) {
    keys([k("right", "command"), k("delete")])
}
edit("txt: Shift-Enter is a newline", file: "g.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\nx\nline2\n")) {
    keys([k("right", "command"), k("return", "shift"), t("x")])
}
edit("txt: ⌥⌫ deletes a word and ⌘⌫ to the line's start", file: "h.txt", md("alpha beta gamma\nnext\n"), click: code, at: "start", want: md("z\nnext\n")) {
    keys([k("right", "command"), k("backspace", "option")])
    check("txt: ⌥⌫ deleted one word", settled(docs.appendingPathComponent("c\(caseN)/h.txt"), md("alpha beta \nnext\n")) == md("alpha beta \nnext\n"))
    keys([k("backspace", "command"), t("z")])
}
edit("txt: ⌥→ and ⌘←/⌘→ move by word and line", file: "i.txt", md("one two three\n"), click: code, at: "start", want: md(">one two! three?\n")) {
    keys([k("right", "option", times: 2), t("!"), k("right", "command"), t("?"), k("left", "command"), t(">")])
}
edit("txt: ⌘↑ and ⌘↓ go to the start and end of the file", file: "j.txt", md("a\nb\nc\n"), click: code, at: "start", want: md("[a\nb\nc\n]")) {
    keys([k("down", "command"), t("]"), k("up", "command"), t("[")])
}
edit("txt: ⌘A then typing replaces the file", file: "k.txt", md("line1\nline2\n"), click: code, at: "start", want: md("new\n")) {
    keys([k("a", "command"), t("new\n")])
}
edit("txt: ⇧→ selection then typing replaces it", file: "l.txt", md("line1\nline2\n"), click: code, at: "start", want: md("first\nline2\n")) {
    keys([k("right", "shift", times: 5), t("first")])
}
edit("txt: ⇧↓ selects a whole line, typing replaces it", file: "m.txt", md("line1\nline2\n"), click: code, at: "start", want: md("Xline2\n")) {
    keys([k("down", "shift"), t("X")])
}
edit("txt: pasting several lines", file: "n.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\na\n  b\nline2\n")) {
    keys([k("right", "command")] + paste("\na\n  b"))
}
edit("txt: copy a line and paste it below", file: "o.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\nline1\nline2\n")) {
    keys([k("right", "shift", "command"), k("c", "command"), k("right"), t("\n"), k("v", "command")])
}
edit("txt: cut a line and paste it at the end", file: "p.txt", md("line1\nline2\n"), click: code, at: "start", want: md("\nline2\nline1")) {
    keys([k("right", "shift", "command"), k("x", "command"), k("down", "command"), k("v", "command")])
}
edit("txt: undo and redo across newlines", file: "q.txt", md("line1\nline2\n"), click: code, at: "start", want: md("line1\nab\ncd\nline2\n")) {
    keys([k("right", "command"), t("\nab\ncd"), k("z", "command", times: 4)])
    let url = docs.appendingPathComponent("c\(caseN)/q.txt")
    check("txt: ⌘Z takes back every typed line", settled(url, md("line1\nline2\n")) == md("line1\nline2\n"),
          String(data: (try? Data(contentsOf: url)) ?? Data(), encoding: .utf8)?.debugDescription ?? "")
    keys([k("z", "command", "shift", times: 4)])
}
edit("txt: after Enter, a click on another line moves the caret there", file: "clickin.txt", md("one\ntwo\n"), click: code, at: "start",
     want: md("one\nnew\ntXwo\n")) {
    keys([k("right", "command"), t("\nnew")])
    click(code, at: "char", char: 9)
    keys([t("X")])
}
edit("swift: Tab types a tab, Shift-Tab takes one back", file: "tab.swift", md("func f() {\n    let x = 1\n}\n"), click: code, at: "start",
     want: md("func f() {\n\t    let x = 1\n}\n")) {
    keys([k("down"), k("left", "command"), k("tab"), k("tab"), k("tab", "shift")])
}
edit("swift: Enter keeps the line's indentation", file: "ind.swift", md("func f() {\n    let x = 1\n}\n"), click: code, at: "start",
     want: md("func f() {\n    let x = 1\n    let y = 2\n}\n")) {
    keys([k("down"), k("right", "command"), t("\nlet y = 2")])
}
edit("swift: Enter after { indents one level", file: "brace.swift", md("func f() {\n}\n"), click: code, at: "start",
     want: md("func f() {\n    return\n}\n")) {
    keys([k("right", "command"), t("\nreturn")])
}
edit("swift: Enter between { and } puts the } on its own line", file: "brace2.swift", md("let a = {}\n"), click: code, at: "start",
     want: md("let a = {\n    x\n}\n")) {
    keys([k("right", "command"), k("left"), t("\nx")])
}
edit("json: Enter after { indents by the file's own step", file: "a.json", md("{\n  \"a\": 1\n}\n"), prepare: raw, click: code, at: "start",
     want: md("{\n  \"b\": 2,\n  \"a\": 1\n}\n")) {
    keys([k("right", "command"), t("\n\"b\": 2,")])
}
edit("json: Enter after [ on an indented line", file: "b.json", md("{\n  \"a\": [\n  ]\n}\n"), prepare: raw, click: code, at: "start",
     want: md("{\n  \"a\": [\n    1\n  ]\n}\n")) {
    keys([k("down"), k("right", "command"), t("\n1")])
}
edit("yaml: Enter keeps a list's indentation", file: "a.yaml", md("items:\n  - one\n"), click: code, at: "start", want: md("items:\n  - one\n  - two\n")) {
    keys([k("down"), k("right", "command"), t("\n- two")])
}
edit("txt: a CRLF file keeps CRLF", file: "crlf.txt", md("a\r\nb\r\n"), click: code, at: "start", want: md("a\r\nc\r\nb\r\n")) {
    keys([k("right", "command"), t("\nc")])
}
edit("txt: no final newline stays without one", file: "nofinal.txt", md("abc"), click: code, at: "start", want: md("abc\nd")) {
    keys([k("right", "command"), t("\nd")])
}
edit("txt: typing fast, lines included, in one run-loop turn", file: "fast.txt", md("\n"), click: code, at: "start", want: md("one\n  two\n  three\n")) {
    keys([["burst": "one\n  two\nthree"]], gap: 0)
}
edit("txt: a dead key and an emoji", file: "ime.txt", md("caf\n"), click: code, at: "start", want: md("café 👍🏽\n")) {
    keys([k("right", "command"), ["marked": "´"], ["commit": "é"], ["commit": " 👍🏽"]])
}
edit("txt: Esc, then a click back in, keeps typing", file: "esc.txt", md("abc\n"), click: code, at: "start", want: md("12abc\n")) {
    keys([t("1")])
    escape()
    click(code, at: "start")
    keys([k("right"), t("2")])
}
edit("csv: Enter adds a row in the raw text", file: "a.csv", md("a,b\n1,2\n"), prepare: raw, click: code, at: "start", want: md("a,b\n1,2\n3,4\n")) {
    keys([k("down", "command"), t("3,4\n")])
}

// Near the 2 MB cap: typing up to it is saved; past it the save is refused and said so, and nothing is lost on disk.
let bigLine = String(repeating: "x", count: 99) + "\n"
let bigText = String(repeating: bigLine, count: (2 << 20) / 100 - 1)
let bigRoom = (2 << 20) - bigText.utf8.count
edit("txt: typing near the 2 MB cap", file: "big.txt", md(bigText), click: code, at: "start", want: md("ab\n" + bigText)) {
    keys([t("ab\n")])
}
edit("txt: past the 2 MB cap the save is refused and the file kept", file: "big2.txt", md(bigText), click: code, at: "start",
     want: md(String(repeating: "y", count: bigRoom) + bigText)) {
    keys([["paste": String(repeating: "y", count: bigRoom)], k("v", "command")])
    _ = settled(docs.appendingPathComponent("c\(caseN)/big2.txt"), md(String(repeating: "y", count: bigRoom) + bigText))
    let url = docs.appendingPathComponent("c\(caseN)/big2.txt")
    keys([t("z")])
    spin(1)
    let st = js("document.getElementById('status').textContent") as? String ?? ""
    check("txt: past the cap the page says it is not saved", st.contains("NOT SAVED") && st.contains("2 MB"), st)
    check("txt: past the cap the file is as last saved", (try? Data(contentsOf: url)) == md(String(repeating: "y", count: bigRoom) + bigText))
    check("txt: past the cap the edit stays open", (js("!!editing") as? Bool) == true)
    keys([k("backspace"), k("backspace")])
    let back = md(String(repeating: "y", count: bigRoom - 1) + bigText)
    check("txt: back under the cap it is saved again", settled(url, back) == back)
    spin(0.5)
    let st2 = js("document.getElementById('status').textContent") as? String ?? ""
    check("txt: and the NOT SAVED status clears", !st2.contains("NOT SAVED"), st2)
    keys([t("y")])
}

if failures > 0 { print("\n\(failures) FAILED, \(passes) passed [\(host)]") } else { print("\nall \(passes) edit flow checks passed [\(host)]") }
closeHost()
exit(failures == 0 ? 0 : 1)
