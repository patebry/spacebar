// The preview extension's own controller (PreviewViewController, as Quick Look calls it) in a process signed as build.sh signs
// the extension: its entitlements, the sandbox and the hardened runtime, with the real writer beside it under the runtime too.
// Each file goes through preparePreviewOfFile and must be shown: Markdown and JSON by the page, a zip listed by the writer, a
// PDF in the PDF view, an image decoded. Off screen; nothing written outside a temp folder.
//   hardened <files dir>
import AppKit
import PDFKit
import WebKit

let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
func turn(_ until: Date) { autoreleasepool { _ = RunLoop.main.run(mode: .default, before: until) } }
func spin(until: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { turn(Date().addingTimeInterval(0.01)) } }

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
    fflush(stdout)
}

var code: SecCode?
var info: CFDictionary?
_ = SecCodeCopySelf([], &code)
if let code { _ = SecCodeCopySigningInformation(unsafeBitCast(code, to: SecStaticCode.self), SecCSFlags(rawValue: kSecCSDynamicInformation), &info) }
let status = (info as? [String: Any])?[kSecCodeInfoStatus as String] as? UInt32 ?? 0
check("this process runs under the hardened runtime", status & SecCodeSignatureFlags.runtime.rawValue != 0, String(status, radix: 16))
check("and in the app sandbox", ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil)

WebHost.pageHost = "quicklook"
_ = NSApplication.shared
NSApp.setActivationPolicy(.accessory)
let parked = NSRect(x: -20000, y: -20000, width: 1000, height: 700)
let controller = PreviewViewController()
let window = NSWindow(contentRect: parked, styleMask: [.borderless], backing: .buffered, defer: false)
window.contentViewController = controller
window.setFrame(parked, display: false)
window.orderFrontRegardless()

final class Recorder: NSObject, WKScriptMessageHandler {
    var messages: [[String: Any]] = []
    func userContentController(_ ucc: WKUserContentController, didReceive m: WKScriptMessage) {
        WebHost.shared.userContentController(ucc, didReceive: m)
        if let b = m.body as? [String: Any] { messages.append(b) }
    }
}
let rec = Recorder()
let web = WebHost.shared.web
spin(until: 20) { WebHost.shared.ready }
check("the page loads", WebHost.shared.ready)
guard WebHost.shared.ready else { exit(1) }
web.configuration.userContentController.removeScriptMessageHandler(forName: "sb")
web.configuration.userContentController.add(rec, name: "sb")

func js(_ src: String) -> Any? {
    var out: Any?, done = false
    web.evaluateJavaScript(src) { r, e in out = r ?? e.map { "ERR \($0)" }; done = true }
    spin(until: 10) { done }
    return out
}
func views<T: NSView>(_ type: T.Type, in v: NSView) -> [T] { ((v as? T).map { [$0] } ?? []) + v.subviews.flatMap { views(type, in: $0) } }

/// preparePreviewOfFile as Quick Look calls it; the completion's error, or "timeout".
func prepare(_ url: URL) -> String? {
    var result: String??
    controller.preparePreviewOfFile(at: url) { error in result = .some(error.map { "\($0)" }) }
    controller.viewWillAppear()
    controller.viewDidAppear()
    spin(until: 15) { result != nil }
    return result ?? "timeout"
}
func shown(_ url: URL, text: String) -> Bool {
    let from = rec.messages.count
    let error = prepare(url)
    check("\(url.lastPathComponent): Quick Look's completion has no error", error == nil, error ?? "")
    spin(until: 15) {
        rec.messages.dropFirst(from).contains { $0["type"] as? String == "rendered" }
            && (js("document.body.innerText.includes(\(String(reflecting: text)))") as? Bool) == true
    }
    return (js("document.body.innerText.includes(\(String(reflecting: text)))") as? Bool) == true
}

let md = dir.appendingPathComponent("note.md")
check("Markdown is rendered by the page", shown(md, text: "hardened marker 7f3a"), "\(js("document.body.innerText.slice(0, 300)") ?? "")")
check("its table and code block are drawn", (js("document.querySelectorAll('table td').length") as? Int ?? 0) >= 2
      && (js("document.querySelectorAll('pre code').length") as? Int ?? 0) >= 1)
check("JSON is rendered by the page", shown(dir.appendingPathComponent("data.json"), text: "hardenedKey"))
check("a zip is listed by the writer", shown(dir.appendingPathComponent("bundle.zip"), text: "inside-the-zip.txt"),
      "\(js("document.body.innerText.slice(0, 300)") ?? "")")

let pdfError = prepare(dir.appendingPathComponent("doc.pdf"))
check("doc.pdf: Quick Look's completion has no error", pdfError == nil, pdfError ?? "")
// In this host the page posts no pdfRect, so the PDFView is never laid over it: the page's view (as test/bigfiles checks
// it) and PDFKit reading the file in this process are checked instead.
spin(until: 10) { (js("current && current.view") as? String) == "pdf" }
check("a PDF opens in the PDF view", (js("current && current.view") as? String) == "pdf", "\(js("current && current.view") ?? "none")")
check("PDFKit reads it in this process", (PDFDocument(url: dir.appendingPathComponent("doc.pdf"))?.pageCount ?? 0) == 1)

let pngError = prepare(dir.appendingPathComponent("image.png"))
check("image.png: Quick Look's completion has no error", pngError == nil, pngError ?? "")
spin(until: 10) { views(NSImageView.self, in: controller.view).contains { $0.image != nil } || (js("document.querySelector('img') && document.querySelector('img').naturalWidth") as? Int ?? 0) > 0 }
check("an image is decoded", views(NSImageView.self, in: controller.view).contains { $0.image != nil }
      || (js("document.querySelector('img') && document.querySelector('img').naturalWidth") as? Int ?? 0) > 0)

controller.viewWillDisappear()
print(failures == 0 ? "hardened: all passed" : "hardened: \(failures) failed")
exit(failures == 0 ? 0 : 1)
