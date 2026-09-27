import AppKit
import PDFKit

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
check("the reads leave this thread's policy as it was",
      getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD) == IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT)
if ran == 0 { print("SKIP no dataless file to read: nothing was checked") }
print(failures == 0 ? "ok" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
