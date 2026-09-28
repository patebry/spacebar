import AppKit
import Quartz
import UniformTypeIdentifiers
import WebKit
import os

let log = Logger(subsystem: "md.spacebar.test", category: "qlpane")
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func spin(until: Double = 10, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { spin(0.02) } }
/// QLPANE_RENDER=0 (CI): the checks that need Apple's generators to answer, or this Mac's type declarations, print SKIP.
let render = ProcessInfo.processInfo.environment["QLPANE_RENDER"] != "0"
func renderCheck(_ name: String, _ body: () -> Void) { if render { body() } else { print("SKIP \(name)") } }

_ = NSApplication.shared
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()

func offscreen() -> (NSWindow, NSView, WKWebView) {
    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
    let web = WKWebView(frame: container.bounds)
    web.autoresizingMask = [.width, .height]
    container.addSubview(web)
    window.contentView = container
    window.orderBack(nil)
    return (window, container, web)
}

// Signed with the extension's sandbox entitlements (run.sh): the document the first run wrote, read only.
if ProcessInfo.processInfo.environment["QLPANE_SANDBOX"] != nil {
    let (window, _, web) = offscreen()
    let memo = dir.appendingPathComponent("memo.docx")
    guard let pane = QLFallbackPane() else { print("FAIL QLPreviewView init in the sandbox"); exit(1) }
    var failed: [String] = []
    pane.onFailed = { failed.append($0) }
    pane.show(memo)
    pane.place(message: ["path": memo.path, "x": 0, "y": 0, "w": 800, "h": 600], in: web)
    spin(until: QLFallbackPane.failureDelay + 1.5) { !failed.isEmpty || QLFallbackPane.shown(classNames: QLFallbackPane.classNames(pane.view)) == .preview }
    let tree = QLFallbackPane.classNames(pane.view)
    check("sandboxed with the extension's entitlements: the Word document renders, no fallback",
          failed.isEmpty && QLFallbackPane.shown(classNames: tree) == .preview, "\(failed) \(tree.joined(separator: " "))")
    pane.close()
    window.orderOut(nil)
    exit(failures == 0 ? 0 : 1)
}
let allow = FileTypes.appleQuickLookTypes

// ---- the allowlist never names a type spacebar claims: QLPreviewView would hand the file back to spacebar ----
var claims: Set<String> = ["md.spacebar.qlmanage", "public.folder", "public.directory"]
for line in try! String(contentsOfFile: "scripts/quicklook-types.txt", encoding: .utf8).split(separator: "\n") {
    let f = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    if f.first == "claim", f.count > 1 { claims.insert(f[1]) }
    if f.first == "declare", f.count > 1 { claims.insert("md.spacebar.type." + f[1].split(separator: ",")[0]) }
}
check("claims read from scripts/quicklook-types.txt", claims.contains("net.daringfireball.markdown") && claims.contains("public.zip-archive") && claims.count > 40,
      "\(claims.count)")
check("the allowlist and spacebar's claims share no type", allow.isDisjoint(with: claims), "\(allow.intersection(claims).sorted())")
let zipLike = allow.filter { id in
    guard let t = UTType(id) else { return false }
    return t.conforms(to: .zip) || t.conforms(to: .archive) || ["com.apple.package", "public.data", "public.content", "public.font"].contains(id)
}
check("no generic zip, archive or parent type", zipLike.isEmpty, "\(zipLike.sorted())")
check("RTF is not in it (it has its own view)", !allow.contains("public.rtf") && !allow.contains("com.apple.rtfd"))
renderCheck("every type is declared on this Mac") {
    let undeclared = allow.filter { UTType($0)?.isDeclared != true }
    check("every type is declared on this Mac", undeclared.isEmpty, "\(undeclared.sorted())")
}

// ---- which files get the view: by exact type, never a type spacebar claims ----
func touch(_ name: String, _ data: Data = Data()) -> String {
    let u = dir.appendingPathComponent(name)
    try! data.write(to: u)
    return u.path
}
let docxData = try! NSAttributedString(string: "spacebar quick look pane\n" + String(repeating: "A paragraph of text.\n", count: 20))
    .data(from: NSRange(location: 0, length: 20), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
let docx = touch("memo.docx", docxData)
let expected: [(String, String)] = [
    (docx, "org.openxmlformats.wordprocessingml.document"), (touch("sheet.xlsx"), "org.openxmlformats.spreadsheetml.sheet"),
    (touch("deck.pptx"), "org.openxmlformats.presentationml.presentation"), (touch("old.doc"), "com.microsoft.word.doc"),
    (touch("old.xls"), "com.microsoft.excel.xls"), (touch("old.ppt"), "com.microsoft.powerpoint.ppt"),
    (touch("flat.pages"), "com.apple.iwork.pages.sffpages"), (touch("flat.numbers"), "com.apple.iwork.numbers.sffnumbers"),
    (touch("flat.key"), "com.apple.iwork.keynote.sffkey"), (touch("font.ttf"), "public.truetype-ttf-font"), (touch("font.otf"), "public.opentype-font"),
    (touch("fonts.ttc"), "public.truetype-collection-font"), (touch("font.dfont"), "com.apple.truetype-datafork-suitcase-font"),
    (touch("model.usdz"), "com.pixar.universal-scene-description-mobile"), (touch("scene.reality"), "com.apple.reality"),
]
var pkgs: [(String, String)] = []
for (ext, id) in [("pages", "com.apple.iwork.pages.pages"), ("numbers", "com.apple.iwork.numbers.numbers"), ("key", "com.apple.iwork.keynote.key")] {
    let p = dir.appendingPathComponent("bundle.\(ext)")
    try! FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    try! Data("<x/>".utf8).write(to: p.appendingPathComponent("index.xml"))
    pkgs.append((p.path, id))
}
func payload(_ path: String) -> [String: Any] {
    var st = stat()
    _ = stat(path, &st)
    let isDir = st.st_mode & S_IFMT == S_IFDIR
    let kind = FileTypes.kind(name: (path as NSString).lastPathComponent, isDirectory: isDir, isPackage: isDir)
    return FileView.payload(path: path, kind: kind, root: dir.path, reason: "open", canOpen: true)
}
let wrong = (expected + pkgs).filter { FileTypes.appleQuickLookType($0.0) != $0.1 || payload($0.0)["view"] as? String != "quicklook" }
check("each allowlisted type, a file or an iWork package, resolves to its exact type and the quicklook view (\(expected.count + pkgs.count))", wrong.isEmpty,
      wrong.map { "\(($0.0 as NSString).lastPathComponent)=\(FileTypes.appleQuickLookType($0.0) ?? "nil")/\(payload($0.0)["view"] ?? "nil")" }.joined(separator: " "))
check("every allowlisted type is covered by a sample", Set((expected + pkgs).map(\.1)) == allow, "\(allow.subtracting((expected + pkgs).map(\.1)).sorted())")
let others = [touch("notes.md", Data("# hi\n".utf8)), touch("a.zip", Data("PK\u{3}\u{4}".utf8)), touch("doc.rtf", Data("{\\rtf1 hi}".utf8)),
              touch("blob.dat", Data([0, 1, 2])), touch("page.html", Data("<p>".utf8)), touch("script.py", Data("print(1)\n".utf8)),
              touch("noext", Data([0, 1, 2]))]
let leaked = others.filter { FileTypes.appleQuickLookType($0) != nil || payload($0)["view"] as? String == "quicklook" }
check("Markdown, a zip, RTF, HTML, code and unknown data never get it", leaked.isEmpty, "\(leaked)")
let big = dir.appendingPathComponent("huge.docx")
FileManager.default.createFile(atPath: big.path, contents: nil)
let h = try! FileHandle(forWritingTo: big)
try! h.truncate(atOffset: UInt64(FileTypes.maxFileBytes) + 1)
try! h.close()
check("a file past the size cap gets the info card", payload(big.path)["view"] as? String == "info")
check("the payload names the file's kind", payload(docx)["kindName"] as? String == UTType("org.openxmlformats.wordprocessingml.document")?.localizedDescription)

// ---- the generic icon, from the view trees the spike measured (spike/qlpreview/results) ----
let icon = ["QLPreviewView", "QLPreviewContainerView", "QLDisplayBundleContainerView", "QLLayerBasedPreviewContainerView"]
check("an empty layer-based container is the generic icon", QLFallbackPane.shown(classNames: icon) == .genericIcon)
check("Office/iWork web view, PowerPoint PDF view and font remote view are previews",
      QLFallbackPane.shown(classNames: ["QLPreviewView", "QLPreviewContainerView", "QLDisplayBundleContainerView", "QLWeb2CenteringView", "QLWeb2View", "WKFlippedView"]) == .preview
      && QLFallbackPane.shown(classNames: ["QLPreviewView", "QLPreviewContainerView", "QLDisplayBundleContainerView", "QLPDFContainerView"]) == .preview
      && QLFallbackPane.shown(classNames: ["QLPreviewView", "QLPreviewContainerView", "NSRemoteView"]) == .preview)
check("still loading (Quick Look's spinner, or no container yet) is neither, so it is looked at again",
      QLFallbackPane.shown(classNames: ["QLPreviewView", "QLPreviewContainerView", "QLLoadingView", "NSProgressIndicator", "NSImageView"]) == .loading
      && QLFallbackPane.shown(classNames: ["QLPreviewView", "QLPreviewContainerView"]) == .loading)

// ---- the pane in a real (off-screen) window above a WKWebView, as in the extension ----
let (window, container, web) = offscreen()

guard let pane = QLFallbackPane() else { print("FAIL QLPreviewView init"); exit(1) }
var failed: [String] = []
pane.onFailed = { failed.append($0) }
check("created hidden, closed by the pane rather than the window", pane.view.isHidden && !pane.view.shouldCloseWithWindow)
pane.show(URL(fileURLWithPath: docx))
check("show: not in the container until the page places it", pane.view.superview == nil && !pane.placed && pane.path == docx
      && (pane.view.previewItem as? URL)?.path == docx)
pane.place(message: ["path": "/elsewhere.docx", "x": 0, "y": 0, "w": 10, "h": 10], in: web)
check("place: a message for another file is ignored", pane.view.superview == nil && !pane.placed)
let msg: [String: Any] = ["path": docx, "x": 240, "y": 100, "w": 700, "h": 600, "hide": false, "bg": [30, 30, 32], "dark": true, "radius": 8]
pane.place(message: msg, in: web)
check("place: at the page's area, above the web view, dark, corners rounded",
      !pane.view.isHidden && pane.placed && pane.view.frame == NSRect(x: 240, y: 100, width: 700, height: 600)
      && pane.view.superview === container && container.subviews.last === pane.view && pane.view.layer?.cornerRadius == 8
      && pane.view.appearance?.name == .darkAqua, "\(pane.view.frame)")
pane.place(message: msg.merging(["hide": true]) { _, n in n }, in: web)
check("place: hide keeps the frame, hidden", pane.view.isHidden && pane.view.frame.width == 700)
pane.place(message: ["path": docx, "hide": true], in: web)
check("place: hide with no rect conceals", pane.view.isHidden)
pane.place(message: msg.merging(["dark": false, "radius": 0, "x": "x"]) { _, n in n }, in: web)
check("place: a bad number is ignored", pane.view.isHidden)
pane.place(message: msg.merging(["dark": false, "radius": 0]) { _, n in n }, in: web)
check("place: light again", !pane.view.isHidden && pane.view.appearance?.name == .aqua && pane.view.layer?.masksToBounds == false)

// Unsandboxed here, so Apple's generator answers: the document renders and the fallback does not fire.
renderCheck("a Word document renders in the pane (off screen), no fallback") {
    spin(until: QLFallbackPane.failureDelay + 1.5) { false }
    let tree = QLFallbackPane.classNames(pane.view)
    check("a Word document renders in the pane (off screen), no fallback", failed.isEmpty && QLFallbackPane.shown(classNames: tree) == .preview
          && tree.contains("QLWeb2View"), tree.joined(separator: " "))
}

// A second file in the same pane (the sidebar), then a damaged one: the generic icon, and the owner is told.
renderCheck("a document Quick Look cannot read: the pane reports it once, for that file") {
    let junk = touch("junk.docx", Data((0..<4096).map { _ in UInt8.random(in: 0...255) }))
    pane.show(URL(fileURLWithPath: junk))
    spin(until: QLFallbackPane.failureGiveUp) { !failed.isEmpty }
    spin(1)
    check("a document Quick Look cannot read: the pane reports it once, for that file", failed == [junk],
          "\(failed) \(QLFallbackPane.classNames(pane.view).joined(separator: " "))")
    // The same file changing on disk: read again in place, and looked at again.
    failed = []
    try! Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: URL(fileURLWithPath: junk))
    pane.show(URL(fileURLWithPath: junk))
    spin(until: QLFallbackPane.failureGiveUp) { !failed.isEmpty }
    check("the same file changed on disk: the check runs again", failed == [junk], "\(failed)")
}

// A generator slower than the first look: still loading at 1.5 s, the generic icon at 2.2 s (a damaged 2 MB document, measured).
do {
    let slow = QLFallbackPane()!
    var slowFailed: [(String, Double)] = []
    let start = Date()
    slow.inspect = { _ in Date().timeIntervalSince(start) < 2.2
        ? ["QLPreviewView", "QLPreviewContainerView", "QLLoadingView", "NSProgressIndicator", "NSImageView"] : icon }
    slow.onFailed = { slowFailed.append(($0, Date().timeIntervalSince(start))) }
    slow.show(URL(fileURLWithPath: docx))
    slow.place(message: ["path": docx, "x": 0, "y": 0, "w": 800, "h": 600], in: web)
    spin(until: 5) { !slowFailed.isEmpty }
    spin(0.6)
    check("still loading at the first look: looked at again until the icon shows, then reported once",
          slowFailed.count == 1 && slowFailed[0].0 == docx && slowFailed[0].1 >= 2.2 && slowFailed[0].1 < 3.0, "\(slowFailed)")
    slow.close()
}

// The same with a real damaged document: a 2.6 MB Word file cut in half. Here it showed the icon within 1.5 s; the reviewer's
// Mac showed the spinner until 2.2 s.
renderCheck("a large document cut short: reported") {
    var words = ""
    var g = SystemRandomNumberGenerator()
    for _ in 0..<1_200_000 { words += String((0..<Int.random(in: 3...9, using: &g)).map { _ in "abcdefghijklmnopqrstuvwxyz".randomElement(using: &g)! }) + " " }
    let whole = try! NSAttributedString(string: words).data(from: NSRange(location: 0, length: (words as NSString).length),
                                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
    let cut = touch("cut.docx", whole.prefix(whole.count / 2))
    guard let slow = QLFallbackPane() else { return check("a second pane", false) }
    var slowFailed: [String] = []
    slow.onFailed = { slowFailed.append($0) }
    var sawLoading = false
    slow.show(URL(fileURLWithPath: cut))
    slow.place(message: ["path": cut, "x": 0, "y": 0, "w": 800, "h": 600], in: web)
    let start = Date()
    spin(until: QLFallbackPane.failureGiveUp) {
        if Date().timeIntervalSince(start) > QLFallbackPane.failureDelay, QLFallbackPane.shown(classNames: QLFallbackPane.classNames(slow.view)) == .loading { sawLoading = true }
        return !slowFailed.isEmpty
    }
    slow.close()
    failed = slowFailed
    check("a large document cut short (\(whole.count / 2) bytes): reported", failed == [cut],
          "\(failed) after \(Date().timeIntervalSince(start)) s, loading seen: \(sawLoading)")
}

pane.show(URL(fileURLWithPath: docx))
pane.close()
failed = []
spin(until: QLFallbackPane.failureDelay + 0.5) { false }
check("close: out of the container, no file, no late report", pane.view.superview == nil && pane.path == nil && !pane.placed && failed.isEmpty)

window.orderOut(nil)
print(failures == 0 ? "qlpane: all passed" : "qlpane: \(failures) failed")
exit(failures == 0 ? 0 : 1)
