import AppKit
import PDFKit
import WebKit

// Quick Look starts the extension with dataless-file materialization off (the kernel logs "NSPACE process SpacebarPreview is
// decorated as no-materialization"), so a file iCloud has evicted ("Optimize Mac Storage") fails to read with EDEADLK. This
// harness sets the same policy on itself and reads such files through the extension's own read paths.

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}

let SF_DATALESS: UInt32 = 0x4000_0000
func isDataless(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && st.st_flags & SF_DATALESS != 0
}
func size(_ path: String) -> Int {
    var st = stat()
    return lstat(path, &st) == 0 ? Int(st.st_size) : -1
}

/// A plain read with the process policy in force: EDEADLK without downloading anything.
func rawReadErrno(_ path: String) -> Int32 {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return errno }
    defer { close(fd) }
    var b = [UInt8](repeating: 0, count: 1)
    return read(fd, &b, 1) < 0 ? errno : 0
}

let args = CommandLine.arguments
let dir = args.count > 1 ? args[1] : NSHomeDirectory() + "/Desktop/spacebar-film"
let md = dir + "/" + (args.count > 2 ? args[2] : "docs/faq.md")
let csv = dir + "/" + (args.count > 3 ? args[3] : "budget.csv")
let pdf = dir + "/" + (args.count > 4 ? args[4] : "invoice-0042.pdf")
let loadMD = dir + "/" + (args.count > 5 ? args[5] : "vault-demo/Daily/2026-09-25.md")
let image = dir + "/" + (args.count > 6 ? args[6] : "design/wireframe.png")

/// Runs the main run loop until `done` or `timeout`, with a 10 ms main-queue heartbeat: returns the longest gap between beats.
func spinMain(timeout: TimeInterval, until done: () -> Bool) -> (gap: Double, beats: Int) {
    var last = Date(), gap = 0.0, beats = 0
    let t = Timer(timeInterval: 0.01, repeats: true) { _ in
        gap = max(gap, Date().timeIntervalSince(last))
        last = Date()
        beats += 1
    }
    RunLoop.main.add(t, forMode: .default)
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) }
    t.invalidate()
    return (max(gap, Date().timeIntervalSince(last)), beats)
}

/// Records what the scheme handler sends a task, and whether it was sent on the main thread.
final class FakeTask: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var events: [String] = []
    var body = Data()
    var offMain = false
    init(_ url: URL) { request = URLRequest(url: url) }
    private func note(_ e: String) { events.append(e); if !Thread.isMainThread { offMain = true } }
    func didReceive(_ response: URLResponse) { note("response") }
    func didReceive(_ data: Data) { note("data"); body.append(data) }
    func didFinish() { note("finish") }
    func didFailWithError(_ error: Error) { note("fail") }
}

check("process materialization policy set off, as Quick Look sets it",
      setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS, IOPOL_MATERIALIZE_DATALESS_FILES_OFF) == 0
      && getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_PROCESS) == IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

var ran = 0
for (label, path) in [("markdown", md), ("csv", csv), ("pdf", pdf)] {
    guard isDataless(path) else { print("SKIP \(label): \((path as NSString).lastPathComponent) is not dataless (already downloaded, or not in iCloud)"); continue }
    ran += 1
    let e = rawReadErrno(path)
    check("\(label): a plain read of the evicted file fails with EDEADLK (the reported failure)", e == EDEADLK, "errno \(e)")
    let n = size(path)
    switch label {
    case "markdown":
        let text = try? FileView.readDocument(URL(fileURLWithPath: path))
        check("markdown: the sidebar's Markdown read downloads and reads it", text?.utf8.count == n, "got \(text?.utf8.count ?? -1) of \(n) bytes")
    case "csv":
        let p = FileView.payload(path: path, kind: .csv, root: dir, reason: "open", canOpen: true)
        let text = p["text"] as? String
        check("csv: FileView shows the table's text", p["view"] as? String == "csv" && text?.utf8.count == n,
              "view \(p["view"] ?? "nil"), \(text?.utf8.count ?? -1) of \(n) bytes")
    default:
        let r = PDFPane.open(URL(fileURLWithPath: path))
        if case .success(let d) = r { check("pdf: PDFPane opens it", d.pageCount > 0, "no pages") } else { check("pdf: PDFPane opens it", false, "\(r)") }
    }
    check("\(label): the file is on disk now", !isDataless(path))
}
// The extension reads off the main thread (FileLoader, and the file host's image reads), so the panel keeps responding while
// iCloud downloads a file; these read evicted files the same way and keep a main-queue heartbeat going meanwhile.
if isDataless(loadMD) {
    ran += 1
    let n = size(loadMD)
    let loader = FileLoader()
    var got: FileLoader.Outcome<Result<String, Error>>?
    var onMain = true
    loader.load({ () -> Result<String, Error> in onMain = Thread.isMainThread; return Result { try FileView.readDocument(URL(fileURLWithPath: loadMD)) } }) { got = $0 }
    let hb = spinMain(timeout: 30) { got != nil }
    var text: String?
    if case .done(.success(let t))? = got { text = t }
    check("loader: an evicted Markdown file is downloaded and read off the main thread", !onMain && text?.utf8.count == n,
          "onMain \(onMain), got \(String(describing: got))")
    check("loader: the main thread kept beating during the download (longest gap < 100 ms)", hb.gap < 0.1 && hb.beats > 0,
          "gap \(Int(hb.gap * 1000)) ms, \(hb.beats) beats")
    check("loader: the Markdown file is on disk now", !isDataless(loadMD))
} else {
    print("SKIP loader: \((loadMD as NSString).lastPathComponent) is not dataless")
}
if isDataless(image) {
    ran += 1
    let n = size(image)
    let h = SchemeHandler(webRoot: URL(fileURLWithPath: "/nonexistent"))
    h.fileRoot = dir
    let task = FakeTask(FileTypes.fileURL(image)!)
    let web = WKWebView(frame: .zero)
    let t0 = Date()
    h.webView(web, start: task)
    let started = Date().timeIntervalSince(t0)
    let hb = spinMain(timeout: 30) { task.events.last == "finish" || task.events.last == "fail" }
    check("file host: start returns at once for an evicted image (< 50 ms)", started < 0.05, "\(Int(started * 1000)) ms")
    check("file host: the evicted image is downloaded and served, answered on the main thread",
          task.events == ["response", "data", "finish"] && task.body.count == n && !task.offMain, "\(task.events), \(task.body.count) of \(n) bytes")
    check("file host: the main thread kept beating during the download (longest gap < 100 ms)", hb.gap < 0.1 && hb.beats > 0,
          "gap \(Int(hb.gap * 1000)) ms, \(hb.beats) beats")
    check("file host: the image is on disk now", !isDataless(image))
} else {
    print("SKIP file host: \((image as NSString).lastPathComponent) is not dataless")
}

// Cancellation and the timeout, with injected readers (no file involved): a superseded or cancelled load never reports, and a
// load past its timeout reports .timedOut once while its late result is dropped.
do {
    let loader = FileLoader(timeout: 5)
    let gateA = DispatchSemaphore(value: 0)
    var a: [String] = [], b: [String] = []
    loader.load({ () -> String in gateA.wait(); return "A" }) { if case .done(let v) = $0 { a.append(v) } else { a.append("timeout") } }
    loader.load({ "B" }) { if case .done(let v) = $0 { b.append(v) } else { b.append("timeout") } }
    _ = spinMain(timeout: 2) { !b.isEmpty }
    gateA.signal()
    _ = spinMain(timeout: 0.3) { false }
    check("cancel: a newer load supersedes the one in flight; only the newer one reports", a.isEmpty && b == ["B"], "a \(a), b \(b)")

    let gateC = DispatchSemaphore(value: 0)
    var c: [String] = []
    let short = FileLoader(timeout: 0.2)
    let id = short.load({ () -> String in gateC.wait(); return "C" }) { if case .done(let v) = $0 { c.append(v) } else { c.append("timeout") } }
    short.cancel()
    check("cancel: the cancelled load is no longer active", !short.isActive(id))
    gateC.signal()
    _ = spinMain(timeout: 0.5) { false }
    check("cancel: a cancelled load reports nothing, not even its timeout", c.isEmpty, "\(c)")

    var d: [String] = []
    var at = 0.0
    let t0 = Date()
    let slow = FileLoader(timeout: 0.3)
    slow.load({ () -> String in Thread.sleep(forTimeInterval: 1); return "late" }) { o in
        at = Date().timeIntervalSince(t0)
        if case .done(let v) = o { d.append(v) } else { d.append("timeout") }
    }
    let hb = spinMain(timeout: 1.5) { false }
    check("timeout: a stuck read reports .timedOut once, at its timeout, and its late result is dropped",
          d == ["timeout"] && at >= 0.28 && at < 0.8, "\(d) at \(Int(at * 1000)) ms")
    check("timeout: the main thread kept beating while the read was stuck", hb.gap < 0.1, "gap \(Int(hb.gap * 1000)) ms")

    var e: [String] = []
    slow.load(timesOut: false, { () -> String in Thread.sleep(forTimeInterval: 0.5); return "slow" }) { o in
        if case .done(let v) = o { e.append(v) } else { e.append("timeout") }
    }
    _ = spinMain(timeout: 1.5) { !e.isEmpty }
    check("timeout: a load without a timeout (a local file) reports its result however long it takes", e == ["slow"], "\(e)")

    // The read decides what it downloads: FileView.payload leaves an evicted archive or video alone, so the loader itself must
    // not switch downloads on for its thread.
    var policy: Int32 = -2
    loader.load({ getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) }) { if case .done(let v) = $0 { policy = v } }
    _ = spinMain(timeout: 2) { policy != -2 }
    check("loader: a read runs under the process policy (no download unless the read asks for one)", policy == IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT,
          "thread policy \(policy)")
}
check("the reads leave this thread's policy as it was",
      getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
if ran == 0 { print("SKIP no dataless file to read: the iCloud reads were not checked") }
print(failures == 0 ? "ok" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
