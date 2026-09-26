// Loads Preview/web in an offscreen WKWebView set up like the extension: the real SchemeHandler (spacebar://bundle, file and
// user) and the real document-start settings script (PageSettings.userScript). Built with Shared/Settings.swift and
// Shared/WebShell.swift, Shared/FolderListing.swift and Shared/LinkPolicy.swift; run with SPACEBAR_SUPPORT_DIR set to a scratch folder.
//   webcheck <web dir> <cmd>...   runs each command, prints one JSON line per command
//   webcheck <web dir>            reads commands from stdin, one JSON-encoded string per line, and answers each with a line
// Commands:
//   <file.md>          render it, audit the DOM, click every link and diagram node: {file, clicked, audit, messages}
//   @csp               inject handlers and scripts past the sanitizer; the CSP alone must block them
//   @load:<json>       reload the page with these settings (over the defaults) in the document-start script
//   @render:<file.md>  render it and wait for "rendered" (no audit, no clicks); its folder's list is sent first
//   @renderfile:<file.md>  the same, with the list sent right after the render
//   @apply:<json>      sb.applySettings(payload of these settings over the current ones); waits for "settings applied"
//   @eval:<js>         evaluate; the result is printed as is (return JSON.stringify(...) for objects)
//   @appearance:light|dark|auto   web.appearance = .aqua / .darkAqua / nil
//   @size:<w>x<h>      resize the window and the web view
//   @shot:<path.png>   WKWebView.takeSnapshot of the visible view
//   @wait:<seconds>
//   @pixel:<x>,<y>     the snapshot's colour at that point of the view, as [r, g, b]
//   @nativeclick:<selector>   a real mouse click (NSEvent down/up sent to the harness's own window) at the element's corner
//   @nativedrag:<selector>,<dx>   a real mouse drag in the harness's own window: down in the element, moves in steps, up
//   @remotereset       RemoteImageGate.reset(), as a new preview or another document does
//   @loaddisk          reload the page with settings.json from the scratch folder, as the next preview would
//   @relist            list the root and every folder the page expanded again and send them, as the folder watches do
//   @root:<dir>        the sidebar's root for the renders that follow (a folder preview); empty: each file's own folder
//   @session           a new preview of the same root: the next listings carry a new session number
// Every render sends the sidebar listing of the root first (FolderListing, as the extension does) and renders the file by its
// kind (FileView for anything but Markdown). The page's "list" lists a folder the tree named, "open" renders a listed file,
// "openFile" and "reveal" are recorded as "_openFile" / "_reveal" (or "_openRefused"), each checked as the extension does;
// "setting" goes through the extension's gate (Settings.panelPatch) and the writer's update (SettingsFile.updateFromPanel),
// recorded as "_written" or "_settingRefused". A subframe may load only the PDF on screen (ShellPolicy).
// The page's "loadRemoteImages" message goes to the real RemoteImageGate, as the extension routes it, and a granted request
// re-renders the current file with the gate's payload flag.
// The non-file commands print {cmd, result, messages}; messages are those posted while the command ran, plus "_refused" for
// every URL the scheme handler refused.
import AppKit
import WebKit

final class Recorder: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    var messages: [[String: Any]] = []
    var ready = false
    var onLoadRemoteImages: (String) -> Void = { _ in }
    var onOpen: (String) -> Void = { _ in }
    var onSetting: ([String: Any]) -> Void = { _ in }
    var onMessage: (String, [String: Any]) -> Void = { _, _ in }
    var pdfFrame: URL?
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        var m = (message.body as? [String: Any]) ?? ["raw": String(describing: message.body)]
        m["_mainFrame"] = message.frameInfo.isMainFrame
        m["_origin"] = "\(message.frameInfo.securityOrigin.protocol)://\(message.frameInfo.securityOrigin.host)"
        if m["type"] as? String == "ready" { ready = true }
        messages.append(m)
        if m["type"] as? String == "loadRemoteImages", let p = m["path"] as? String { onLoadRemoteImages(p) }
        if m["type"] as? String == "open", let p = m["path"] as? String { onOpen(p) }
        if m["type"] as? String == "setting", let body = message.body as? [String: Any] { onSetting(body) }
        if message.frameInfo.isMainFrame, let t = m["type"] as? String, let body = message.body as? [String: Any] { onMessage(t, body) }
    }
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let main = action.targetFrame?.isMainFrame ?? true
        let ok = ShellPolicy.allows(action.request.url, mainFrame: main, pdf: pdfFrame)
        if !ok { messages.append(["type": "_navigation", "url": action.request.url?.absoluteString ?? ""]) }
        else if !main { messages.append(["type": "_frame", "url": action.request.url?.absoluteString ?? ""]) }
        decisionHandler(ok ? .allow : .cancel)
    }
}

func spin(_ seconds: Double, until done: () -> Bool = { false }) {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end && !done() { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
}

func eval(_ web: WKWebView, _ js: String) -> Any? {
    var out: Any?, finished = false
    web.evaluateJavaScript(js) { r, e in out = r ?? e.map { "ERR \($0)" }; finished = true }
    spin(10) { finished }
    return out
}

func jsonString(_ obj: Any) -> String {
    String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.fragmentsAllowed]), encoding: .utf8)!
}

func object(_ json: String) -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
}

let args = CommandLine.arguments
let webRoot = URL(fileURLWithPath: args[1])
_ = NSApplication.shared
let rec = Recorder()
let scheme = SchemeHandler(webRoot: webRoot)
scheme.onRefused = { rec.messages.append(["type": "_refused", "msg": $0]) }
let config = WKWebViewConfiguration()
config.setURLSchemeHandler(scheme, forURLScheme: "spacebar")
config.userContentController.add(rec, name: "sb")
let gate = RemoteImageGate(config.userContentController)
var currentFile: String?
let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 2000), configuration: config)
web.navigationDelegate = rec
// With the screen locked the window counts as occluded, and WebKit then stops requestAnimationFrame; the test view should
// behave like a visible one either way (WKWebView SPI, test harness only).
let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
if web.responds(to: occlusion) {
    typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(web.method(for: occlusion), to: SetBool.self)(web, occlusion, false)
}
// requestAnimationFrame (and so the page's "rendered" message and mermaid) only runs for a view in a window: an off-screen one.
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 900, height: 2000), styleMask: [.borderless], backing: .buffered, defer: false)
window.contentView = web
window.orderBack(nil)

// What the page saw at document start and at its first DOMContentLoaded, to show the theme is set before anything paints.
let probe = WKUserScript(source: """
  window.__sbProbe = { start: document.documentElement.getAttribute('data-theme'), head: !!document.head,
    startSidebar: document.documentElement.getAttribute('data-sidebar') };
  document.addEventListener('DOMContentLoaded', () => { const r = document.documentElement;
    Object.assign(window.__sbProbe, { dcl: r.getAttribute('data-theme'), dclFontSize: r.style.getPropertyValue('--font-size'),
      dclWidth: r.getAttribute('data-width'), dclSidebar: r.getAttribute('data-sidebar') }); }, { once: true });
  """, injectionTime: .atDocumentStart, forMainFrameOnly: true)

var settingsDict = Settings().dictionary

func load(_ patch: [String: Any]) -> Bool {
    settingsDict = Settings().dictionary.merging(patch) { _, new in new }
    gate.update(remoteImages: Settings(dictionary: settingsDict).remoteImages)
    let ucc = config.userContentController
    ucc.removeAllUserScripts()
    ucc.addUserScript(PageSettings.userScript(PageSettings.payload(Settings(dictionary: settingsDict)), webRoot: webRoot))
    ucc.addUserScript(probe)
    rec.ready = false
    var inPlace = false
    gate.whenInPlace { inPlace = true }
    spin(10) { inPlace }
    web.load(URLRequest(url: URL(string: "spacebar://bundle/index.html")!))
    spin(10) { rec.ready }
    return rec.ready
}

guard load([:]) else { print("{\"error\":\"page never ready: \(rec.messages.map { "\($0)" }.joined(separator: " | ").replacingOccurrences(of: "\"", with: "'"))\"}"); exit(2) }

let clickAll = """
  (() => { const sel = '#doc a, #doc svg a, #doc .node, #doc [onclick]'; let n = 0;
    // Re-query before every click: a click that starts an edit redraws the document and detaches earlier nodes.
    for (let i = 0; i < 200; i++) { const t = [...document.querySelectorAll(sel)][i]; if (!t) break; n++; const r = t.getBoundingClientRect();
      for (const type of ['mouseover', 'mousedown', 'mouseup', 'click'])
        t.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, clientX: r.left + 1, clientY: r.top + 1 })); }
    return n; })()
  """
let audit = """
  JSON.stringify((() => { const doc = document.getElementById('doc');
    const handlers = [...doc.querySelectorAll('*')].filter((n) => [...n.attributes].some((a) => /^on/i.test(a.name))).length;
    const scriptUrls = [...doc.querySelectorAll('*')].filter((n) => [...n.attributes].some((a) => /^\\s*(javascript|vbscript|data:text\\/html)/i.test(a.value))).length;
    return { pwned: window.__pwned || null, scripts: doc.querySelectorAll('script').length,
      frames: doc.querySelectorAll('iframe, frame, frameset, object, embed').length, handlers, scriptUrls,
      forms: doc.querySelectorAll('form').length, bases: document.querySelectorAll('base').length,
      katex: doc.querySelectorAll('.katex-html').length, hljs: doc.querySelectorAll('[class^=hljs-]').length,
      mermaid: doc.querySelectorAll('pre.mermaid svg').length, tasks: doc.querySelectorAll('input[type=checkbox][data-line]').length,
      blocks: doc.querySelectorAll(':scope > [data-src]').length, hijacked: (() => { const r = doc.getBoundingClientRect(); let bad = 0;
        // A point inside a link must be over that link's own text; anything else means the link reaches over other content.
        for (let x = r.left + 10; x < r.right; x += 40) for (let y = Math.max(r.top, 0) + 10; y < Math.min(r.bottom, innerHeight); y += 40) {
          const el = document.elementFromPoint(x, y); const a = el && el.closest('a'); if (!a) continue;
          const rg = document.createRange(); rg.selectNodeContents(a);
          if (![...rg.getClientRects()].some((q) => x >= q.left - 2 && x <= q.right + 2 && y >= q.top - 2 && y <= q.bottom + 2)) bad++; }
        return bad; })(), overlays: [...document.querySelectorAll('#doc *')].filter((n) => /fixed|absolute/.test(getComputedStyle(n).position) && !n.closest('.katex')).length,
      editHit: document.elementFromPoint(document.getElementById('edit').getBoundingClientRect().left + 3, document.getElementById('edit').getBoundingClientRect().top + 3) === document.getElementById('edit'),
      aligned: [...doc.querySelectorAll('td[style], th[style]')].length, mermaidLib: typeof window.mermaid, mermaidPre: (doc.querySelector('pre.mermaid') || {outerHTML: ''}).outerHTML.slice(0, 160), imgs: [...doc.querySelectorAll('img')].map((i) => i.naturalWidth) }; })())
  """

func messagesJSON() -> String {
    jsonString(rec.messages.map { m in m.mapValues { "\($0)" } })
}

var listings: [String: FolderListing.Listing] = [:]
var knownDirs: Set<String> = []
var rootOverride: String?
var root = ""
var session = 1
var currentKind: FileKind = .markdown
var currentCanOpen = false

func rootFor(_ url: URL) -> String { rootOverride ?? url.deletingLastPathComponent().resolvingSymlinksInPath().path }

/// As the extension: one folder of the tree, listed with the settings and sent with sb.setFiles.
func sendFolder(_ dir: String) {
    let s = Settings(dictionary: settingsDict)
    let l = FolderListing.list(dir, root: root, sort: s.folderSort, readmeFirst: s.folderReadmeFirst, showHidden: s.showHiddenFiles, pinned: currentFile)
    listings[dir] = l
    for f in l.folders { knownDirs.insert(f.path) }
    var p = l.payload(root: root)
    p["session"] = session
    _ = eval(web, "sb.setFiles(\(jsonString(p))); 0")
}

/// `listFirst`: the list reaches the page before the render, as in a folder preview; otherwise after it, as a single file's can.
func renderFile(_ file: String, listFirst: Bool = true) {
    var url = URL(fileURLWithPath: file)
    let newRoot = rootFor(url)
    // As the extension: a single file is named inside its resolved folder, as the sidebar lists it.
    if rootOverride == nil { url = URL(fileURLWithPath: newRoot).appendingPathComponent(url.lastPathComponent) }
    if newRoot != root { root = newRoot; listings = [:]; knownDirs = [root] }
    scheme.fileRoot = root
    currentFile = url.path
    var st = stat()
    _ = stat(url.path, &st)
    currentKind = FileTypes.kind(name: url.lastPathComponent, isDirectory: st.st_mode & S_IFMT == S_IFDIR, isPackage: st.st_mode & S_IFMT == S_IFDIR,
                                 executable: st.st_mode & 0o111 != 0)
    if listFirst { sendFolder(root) }
    var payload: [String: Any]
    if currentKind == .markdown {
        rec.pdfFrame = nil
        scheme.pdf = nil
        currentCanOpen = false
        payload = FileView.base(path: url.path, root: root, reason: "open")
        payload["text"] = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        payload["view"] = "markdown"
        payload["ver"] = 0
        if gate.allowedPath == url.path { payload[RemoteImageGate.payloadKey] = true }
    } else {
        let (p, pdf) = FileView.payload(path: url.path, kind: currentKind, root: root, reason: "open", canOpen: LinkPolicy.fileRefusal(url) == nil)
        payload = p
        rec.pdfFrame = pdf
        scheme.pdf = pdf
        currentCanOpen = p["canOpen"] as? Bool == true
    }
    _ = eval(web, "sb.render(\(jsonString(payload))); 0")
    if !listFirst { sendFolder(root) }
    spin(8) { rec.messages.contains { $0["type"] as? String == "rendered" } }
}

/// As the extension: a path the page names is taken only when plain, inside the root, and a file a listing named.
func listedFile(_ p: String?) -> String? {
    guard let p, FolderListing.isPlainPath(p, under: root),
          listings.values.contains(where: { l in l.entries.contains { $0.path == p && !$0.isDirectory } }),
          FolderListing.isInside(p, root: root) else { return nil }
    return p
}

func snapshot(_ path: String) -> String {
    var result = "failed", done = false
    web.takeSnapshot(with: nil) { image, error in
        if let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]), (try? png.write(to: URL(fileURLWithPath: path))) != nil {
            result = "\(rep.pixelsWide)x\(rep.pixelsHigh)"
        } else if let error { result = "error \(error)" }
        done = true
    }
    spin(10) { done }
    return result
}

// As the extension: a granted request re-renders the file on screen with the gate's flag.
rec.onLoadRemoteImages = { path in
    guard gate.allowOnce(path, current: currentFile), let f = currentFile else { rec.messages.append(["type": "_remoteRefused", "path": path]); return }
    DispatchQueue.main.async { renderFile(f) }
}

// As the extension: only a listed file opens; a setting passes the extension's gate, then the writer's update.
rec.onOpen = { path in
    guard let p = listedFile(path) else { rec.messages.append(["type": "_openRefused", "path": path]); return }
    DispatchQueue.main.async { renderFile(p) }
}
rec.onMessage = { type, body in
    let path = body["path"] as? String
    switch type {
    case "list":
        guard let p = path, knownDirs.contains(p), FolderListing.isPlainPath(p, under: root), FolderListing.isInside(p, root: root, allowRoot: true) else {
            rec.messages.append(["type": "_listRefused", "path": path ?? ""]); return
        }
        DispatchQueue.main.async { sendFolder(p) }
    case "openFile", "reveal":
        let ok = path != nil && path == currentFile && currentKind != .markdown
            && (type == "reveal" || (currentCanOpen && LinkPolicy.fileRefusal(URL(fileURLWithPath: path!)) == nil))
        rec.messages.append(["type": ok ? "_\(type)" : "_openRefused", "path": path ?? ""])
    default: break
    }
}
rec.onSetting = { body in
    guard let key = body["key"] as? String, let value = body["value"], let patch = Settings.panelPatch(key, value) else {
        rec.messages.append(["type": "_settingRefused", "value": "\(body["value"] ?? "nil")"]); return
    }
    switch SettingsFile.updateFromPanel(patch) {
    case .success?: rec.messages.append(["type": "_written", "patch": String(data: patch, encoding: .utf8)!])
    default: rec.messages.append(["type": "_settingRefused", "value": "writer"])
    }
}

func run(_ cmd: String) -> String {
    rec.messages = []
    if cmd == "@csp" {
        // The CSP alone, with the sanitizer bypassed: handlers and frames injected straight into the DOM must not run.
        let pay = "window.__pwned=1;window.webkit.messageHandlers.sb.postMessage({type:'link',href:'https://pwned.invalid/csp'})"
        _ = eval(web, """
            (() => { const d = document.createElement('div'); document.body.appendChild(d);
              d.innerHTML = `<img src="x" onerror="\(pay)"><svg onload="\(pay)"></svg><iframe srcdoc="<script>\(pay)</script>"></iframe>
                <a id="jl" href="javascript:\(pay)">j</a>`;
              const s = document.createElement('script'); s.textContent = "\(pay)"; document.body.appendChild(s);
              const e = document.createElement('script'); e.src = 'spacebar://file/tmp/evil.js'; document.body.appendChild(e);
              return 0; })()
            """)
        spin(1.5)
        let pwned = eval(web, "String(window.__pwned || null)") as? String ?? "?"
        return "{\"file\":\"@csp\",\"clicked\":0,\"audit\":{\"pwned\":\(pwned == "null" ? "null" : "\"\(pwned)\""),\"scripts\":0,\"frames\":0,\"handlers\":0,\"scriptUrls\":0,\"forms\":0,\"bases\":1},\"messages\":\(messagesJSON())}"
    }
    guard cmd.hasPrefix("@") else {
        let url = URL(fileURLWithPath: cmd)
        renderFile(cmd)
        spin(1.0)
        // Audit what rendered before clicking: a click on a block (a mermaid node) opens the inline editor over it.
        let a = (eval(web, audit) as? String) ?? "null"
        let clicked = eval(web, clickAll) ?? 0
        spin(1.0)
        return "{\"file\":\"\(url.lastPathComponent)\",\"clicked\":\(clicked),\"audit\":\(a),\"messages\":\(messagesJSON())}"
    }
    let colon = cmd.firstIndex(of: ":") ?? cmd.endIndex
    let name = String(cmd[..<colon])
    let arg = colon < cmd.endIndex ? String(cmd[cmd.index(after: colon)...]) : ""
    var result: Any = NSNull()
    switch name {
    case "@load":
        result = load(object(arg))
    case "@render", "@renderfile":
        renderFile(arg, listFirst: name == "@render")
        result = rec.messages.contains { $0["type"] as? String == "rendered" }
    case "@apply":
        settingsDict.merge(object(arg)) { _, new in new }
        gate.update(remoteImages: Settings(dictionary: settingsDict).remoteImages)
        let payload = PageSettings.payload(Settings(dictionary: settingsDict))
        _ = eval(web, "sb.applySettings(\(PageSettings.json(payload))); 0")
        spin(5) { rec.messages.contains { ($0["msg"] as? String)?.hasPrefix("settings applied") == true } }
        result = rec.messages.compactMap { $0["msg"] as? String }.last { $0.hasPrefix("settings applied") } ?? NSNull()
    case "@eval":
        result = eval(web, arg) ?? NSNull()
    case "@appearance":
        web.appearance = arg == "dark" ? NSAppearance(named: .darkAqua) : arg == "light" ? NSAppearance(named: .aqua) : nil
        spin(0.3)
        result = arg
    case "@size":
        let p = arg.split(separator: "x").compactMap { Double($0) }
        if p.count == 2 {
            window.setFrame(NSRect(x: -20000, y: -20000, width: p[0], height: p[1]), display: true)
            web.frame = NSRect(x: 0, y: 0, width: p[0], height: p[1])
            spin(0.3)
        }
        result = arg
    case "@shot":
        result = snapshot(arg)
    case "@pixel":
        let p = arg.split(separator: ",").compactMap { Double($0) }
        var rgb: [Int] = [], done = false
        web.takeSnapshot(with: nil) { image, _ in
            if p.count == 2, let image, let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                let sx = Double(rep.pixelsWide) / web.bounds.width, sy = Double(rep.pixelsHigh) / web.bounds.height
                if let c = rep.colorAt(x: Int(p[0] * sx), y: Int(p[1] * sy))?.usingColorSpace(.sRGB) {
                    rgb = [c.redComponent, c.greenComponent, c.blueComponent].map { Int(($0 * 255).rounded()) }
                }
            }
            done = true
        }
        spin(10) { done }
        result = rgb
    case "@wait":
        spin(Double(arg) ?? 1)
        result = arg
    case "@nativeclick":
        let js = "(() => { const t = document.querySelector(\(jsonString(arg))); if (!t) return null; const r = t.getBoundingClientRect(); return [r.left + 3, r.top + 3]; })()"
        if let p = eval(web, js) as? [Double], p.count == 2 {
            let at = NSPoint(x: p[0], y: web.frame.height - p[1])
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                if let e = NSEvent.mouseEvent(with: type, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1) {
                    window.sendEvent(e)
                }
            }
            spin(0.5)
            result = true
        } else { result = false }
    case "@nativedrag":
        let parts = arg.split(separator: ",", omittingEmptySubsequences: false)
        let sel = parts.dropLast().joined(separator: ","), dx = Double(parts.last ?? "") ?? 0
        let js = "(() => { const t = document.querySelector(\(jsonString(sel))); if (!t) return null; const r = t.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; })()"
        if let p = eval(web, js) as? [Double], p.count == 2 {
            func send(_ type: NSEvent.EventType, _ x: Double) {
                if let e = NSEvent.mouseEvent(with: type, location: NSPoint(x: x, y: web.frame.height - p[1]), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                              windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1) {
                    window.sendEvent(e)
                }
                spin(0.03)
            }
            send(.leftMouseDown, p[0])
            for i in 1...10 { send(.leftMouseDragged, p[0] + dx * Double(i) / 10) }
            send(.leftMouseUp, p[0] + dx)
            spin(0.4)
            result = true
        } else { result = false }
    case "@loaddisk":
        result = load(SettingsFile.load().dictionary)
    case "@relist":
        for d in Array(listings.keys) { sendFolder(d) }
        result = listings[root].map { $0.entries.map(\.name) } ?? []
    case "@root":
        rootOverride = arg.isEmpty ? nil : arg
        result = arg
    case "@session":
        session += 1
        result = session
    case "@remotereset":
        gate.reset()
        result = gate.blocking
    default:
        result = "unknown command"
    }
    return "{\"cmd\":\(jsonString(name)),\"result\":\(jsonString(result)),\"messages\":\(messagesJSON())}"
}

if args.count > 2 {
    for cmd in args.dropFirst(2) { print(run(cmd)) }
} else {
    while let line = readLine() {
        guard let cmd = (try? JSONSerialization.jsonObject(with: Data(line.utf8), options: [.fragmentsAllowed])) as? String else { continue }
        print(run(cmd))
        fflush(stdout)
    }
}
