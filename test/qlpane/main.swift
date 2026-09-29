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

/// Waits for `pane` to show `file` and says what it showed.
func rendered(_ pane: QLFallbackPane, _ file: URL, in web: WKWebView) -> (QLFallbackPane.Shown, [String], [String]) {
    var failed: [String] = []
    pane.onFailed = { failed.append($0) }
    pane.show(file)
    pane.place(message: ["path": file.path, "x": 0, "y": 0, "w": 800, "h": 600], in: web)
    spin(until: QLFallbackPane.failureDelay + 3) { !failed.isEmpty || QLFallbackPane.shown(classNames: QLFallbackPane.classNames(pane.view)) == .preview }
    let tree = QLFallbackPane.classNames(pane.view)
    return (QLFallbackPane.shown(classNames: tree), failed, tree)
}

// Signed with the extension's sandbox entitlements (run.sh): the documents the first run wrote, read only.
if ProcessInfo.processInfo.environment["QLPANE_SANDBOX"] != nil {
    let (window, _, web) = offscreen()
    for (name, what) in [("memo.docx", "the Word document"), ("cert.cer", "a certificate"), ("event.ics", "a calendar event")] {
        let file = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { print("SKIP sandboxed: \(what) (no fixture)"); continue }
        guard let pane = QLFallbackPane() else { print("FAIL QLPreviewView init in the sandbox"); exit(1) }
        let (shown, failed, tree) = rendered(pane, file, in: web)
        check("sandboxed with the extension's entitlements: \(what) renders, no fallback", failed.isEmpty && shown == .preview,
              "\(failed) \(tree.joined(separator: " "))")
        pane.close()
    }
    window.orderOut(nil)
    exit(failures == 0 ? 0 : 1)
}

// ---- no type spacebar claims ever reaches QLPreviewView: it would hand the file back to spacebar ----
FileTypes.quickLookClaims = FileTypes.claims(try! String(contentsOfFile: "scripts/quicklook-types.txt", encoding: .utf8))
let claims = FileTypes.quickLookClaims!
check("claims read from scripts/quicklook-types.txt", claims.contains("net.daringfireball.markdown") && claims.contains("public.zip-archive")
      && claims.contains("md.spacebar.type.toml") && claims.count > 100, "\(claims.count)")
func touch(_ name: String, _ data: Data = Data([0x7f, 0, 1, 2])) -> String {
    let u = dir.appendingPathComponent(name)
    try! data.write(to: u)
    return u.path
}
func payload(_ path: String, quickLook: Bool = true) -> [String: Any] {
    var st = stat()
    _ = stat(path, &st)
    let isDir = st.st_mode & S_IFMT == S_IFDIR
    let kind = FileTypes.kind(name: (path as NSString).lastPathComponent, isDirectory: isDir, isPackage: isDir)
    return FileView.payload(path: path, kind: kind, root: dir.path, reason: "open", canOpen: true, quickLook: quickLook)
}
// A file of each claimed type: named by the type's own extension, a declared one's first, and public.data as a file with none.
var samples: [(String, String)] = []
var untested: [String] = []
let declared = try! String(contentsOfFile: "scripts/quicklook-types.txt", encoding: .utf8).split(separator: "\n")
    .compactMap { l -> (String, String)? in
        let f = l.split(separator: " ")
        return f.count > 1 && f[0] == "declare" ? ("md.spacebar.type." + f[1].split(separator: ",")[0], String(f[1].split(separator: ",")[0])) : nil
    }
for id in claims.sorted() {
    let ext = declared.first { $0.0 == id }?.1 ?? UTType(id)?.preferredFilenameExtension
    if id == "public.data" { samples.append((touch("claimed-data"), id)); continue }
    guard let ext else { untested.append(id); continue }
    samples.append((touch("claimed-\(samples.count).\(ext)"), id))
}
let reached = samples.filter { FileTypes.appleQuickLookType($0.0) != nil || payload($0.0)["view"] as? String == "quicklook" }
check("no file of any claimed type (\(samples.count)) gets Apple's preview", reached.isEmpty, "\(reached.map(\.1))")
check("every claim but the folder and routing types has a sample", Set(untested) == ["md.spacebar.qlmanage", "public.folder", "public.directory"]
      || Set(untested).isSubset(of: ["md.spacebar.qlmanage", "public.folder", "public.directory", "net.daringfireball.markdown", "public.markdown"]),
      "\(untested)")
let allClaimed = claims.compactMap(UTType.init)
check("the rule refuses every claimed type, and every type that conforms to one, even without a file", allClaimed.allSatisfy { !FileTypes.quickLookEligible($0, claims: claims) }
      && ["public.geojson", "com.apple.xcode.strings-text"].compactMap(UTType.init).filter { t in allClaimed.contains { t.conforms(to: $0) && $0 != .data } }
        .allSatisfy { !FileTypes.quickLookEligible($0, claims: claims) })
check("without the claims list nothing is handed to Quick Look", { () -> Bool in
    let saved = FileTypes.quickLookClaims
    FileTypes.quickLookClaims = nil
    defer { FileTypes.quickLookClaims = saved }
    return FileTypes.appleQuickLookType(touch("nolist.docx")) == nil
}())

// ---- which files get the view: any declared type of no kind of spacebar's own, bar folders, packages, apps, archives, disk images ----
let docxData = try! NSAttributedString(string: "spacebar quick look pane\n" + String(repeating: "A paragraph of text.\n", count: 20))
    .data(from: NSRange(location: 0, length: 20), documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
let docx = touch("memo.docx", docxData)
let ics = touch("event.ics", Data(("BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//spacebar//test//EN\r\nBEGIN:VEVENT\r\nUID:1@spacebar.test\r\n"
    + "DTSTAMP:20260929T120000Z\r\nDTSTART:20261001T150000Z\r\nDTEND:20261001T160000Z\r\nSUMMARY:Spacebar review\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n").utf8))
let vcf = touch("person.vcf", Data("BEGIN:VCARD\r\nVERSION:3.0\r\nN:Doe;Jane;;;\r\nFN:Jane Doe\r\nEMAIL:jane@example.com\r\nEND:VCARD\r\n".utf8))
// A self-signed certificate, DER, from the system's openssl.
let cert = dir.appendingPathComponent("cert.cer")
do {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=spacebar test", "-days", "30", "-outform", "DER",
                   "-keyout", dir.appendingPathComponent("cert.key").path, "-out", cert.path]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}
let haveCert = FileManager.default.fileExists(atPath: cert.path)
if !haveCert { print("SKIP certificate fixture: /usr/bin/openssl did not make one") }
var expected: [(String, String)] = [
    (docx, "org.openxmlformats.wordprocessingml.document"), (touch("sheet.xlsx"), "org.openxmlformats.spreadsheetml.sheet"),
    (touch("deck.pptx"), "org.openxmlformats.presentationml.presentation"), (touch("old.doc"), "com.microsoft.word.doc"),
    (touch("old.xls"), "com.microsoft.excel.xls"), (touch("old.ppt"), "com.microsoft.powerpoint.ppt"),
    (touch("flat.pages"), "com.apple.iwork.pages.sffpages"), (touch("flat.numbers"), "com.apple.iwork.numbers.sffnumbers"),
    (touch("flat.key"), "com.apple.iwork.keynote.sffkey"), (touch("font.ttf"), "public.truetype-ttf-font"), (touch("font.otf"), "public.opentype-font"),
    (touch("fonts.ttc"), "public.truetype-collection-font"), (touch("font.dfont"), "com.apple.truetype-datafork-suitcase-font"),
    (touch("model.usdz"), "com.pixar.universal-scene-description-mobile"), (touch("scene.reality"), "com.apple.reality"),
    (touch("pem.crt"), "public.x509-certificate"), (touch("bin.der"), "public.x509-certificate"), (touch("keys.p12"), "com.rsa.pkcs-12"),
    (touch("keys.pfx"), "com.rsa.pkcs-12"), (ics, "com.apple.ical.ics"), (touch("book.epub"), "org.idpf.epub-container"),
    (touch("mesh.obj"), "public.geometry-definition-format"), (touch("mesh.stl"), "public.standard-tesselated-geometry-format"),
    (touch("mesh.glb"), "org.khronos.glb"), (touch("scene.usd"), "com.pixar.universal-scene-description"),
]
if haveCert { expected.append((cert.path, "public.x509-certificate")) }
for (ext, id) in [("pages", "com.apple.iwork.pages.pages"), ("numbers", "com.apple.iwork.numbers.numbers"), ("key", "com.apple.iwork.keynote.key")] {
    let p = dir.appendingPathComponent("bundle.\(ext)")
    try! FileManager.default.createDirectory(at: p, withIntermediateDirectories: true)
    try! Data("<x/>".utf8).write(to: p.appendingPathComponent("index.xml"))
    expected.append((p.path, id))
}
renderCheck("Office, iWork (a file or a package), fonts, 3D, certificates, a calendar and an e-book get Apple's preview") {
    let wrong = expected.filter { FileTypes.appleQuickLookType($0.0) != $0.1 || payload($0.0)["view"] as? String != "quicklook" }
    check("Office, iWork (a file or a package), fonts, 3D, certificates, a calendar and an e-book get Apple's preview (\(expected.count))", wrong.isEmpty,
          wrong.map { "\(($0.0 as NSString).lastPathComponent)=\(FileTypes.appleQuickLookType($0.0) ?? "nil")/\(payload($0.0)["view"] ?? "nil")" }.joined(separator: " "))
}
let appDir = dir.appendingPathComponent("Tool.app/Contents")
try! FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
let others = [touch("notes.md", Data("# hi\n".utf8)), touch("a.zip", Data("PK\u{3}\u{4}".utf8)), touch("doc.rtf", Data("{\\rtf1 hi}".utf8)),
              touch("blob.dat", Data([0, 1, 2])), touch("page.html", Data("<p>".utf8)), touch("script.py", Data("print(1)\n".utf8)),
              touch("noext", Data([0, 1, 2])), touch("disk.dmg"), touch("disk.iso"), touch("disk.sparseimage"), touch("site.webarchive"),
              touch("mail.eml"), touch("font.woff2"), touch("pic.heic"), touch("clip.webm"), touch("tune.ogg"),
              touch("setup.pkg"), touch("installer.mpkg"), touch("tool.xcconfig", Data("A = B\n".utf8)), vcf, appDir.deletingLastPathComponent().path, dir.path]
let leaked = others.filter { FileTypes.appleQuickLookType($0) != nil || payload($0)["view"] as? String == "quicklook" }
check("Markdown, archives, disk images, apps and installers, web archives, mail, images, media, text, dyn types, folders and a vCard never get it",
      leaked.isEmpty, "\(leaked.map { ($0 as NSString).lastPathComponent })")
check("a vCard is shown as its text: Apple's preview of it reads Contacts in the viewer's own process", payload(vcf)["view"] as? String == "text")
check("once Apple's preview showed only an icon, a text file is shown as text and anything else as its info card",
      payload(ics, quickLook: false)["view"] as? String == "text" && payload(touch("dead.docx"), quickLook: false)["view"] as? String == "info")
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

renderCheck("a certificate and a calendar event render through Apple's generators, out of process") {
    for (file, what) in [(cert, "a certificate"), (URL(fileURLWithPath: ics), "a calendar event")] where FileManager.default.fileExists(atPath: file.path) {
        guard let p = QLFallbackPane() else { return check("a second pane", false) }
        let (shown, failed, tree) = rendered(p, file, in: web)
        check("\(what) renders in the pane, no fallback", failed.isEmpty && shown == .preview, "\(failed) \(tree.joined(separator: " "))")
        p.close()
    }
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
