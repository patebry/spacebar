// Checks Shared/LinkPolicy.swift on files in a fresh temp folder: build and run with test/linkpolicy/run.sh. Opens nothing.
import AppKit

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-linkpolicy-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func file(_ name: String, _ text: String = "x\n", mode: Int = 0o644) -> URL {
    let u = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: u.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    return u
}

for name in ["a.zip", "a.tar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.tar.xz", "a.7z"] {
    check("archive \(name): refused as a link, allowed for the viewer's Open", LinkPolicy.refusal(file(name)) != nil
          && LinkPolicy.refusal(file(name), allowArchives: true) == nil && LinkPolicy.opener(for: file(name), allowArchives: true) != nil)
}
for name in ["x.jar", "x.epub", "x.ipa", "x.xip", "x.pkg", "x.dmg"] {
    check("refused \(name) even where archives are allowed", LinkPolicy.refusal(file(name), allowArchives: true) != nil)
}
for name in ["notes.txt", "readme.md", "photo.png", "paper.pdf", "data.csv", "clip.mp4", "doc.rtf"] {
    check("allowed \(name)", LinkPolicy.refusal(file(name)) == nil)
}
for name in ["run.command", "run.sh", "tool.py", "page.html", "page.xhtml", "pic.svg", "go.webloc", "go.inetloc", "go.fileloc",
             "go.url", "x.terminal", "x.mobileconfig", "x.configprofile", "x.ics", "x.vcf", "x.pkg", "x.dmg", "x.jar", "x.scpt",
             "x.workflow", "x.shortcut", "x.webarchive", "x.xml", "noextension", "x.epub", "x.ipa", "x.xip", "x.cpio", "x.a"] {
    check("refused \(name)", LinkPolicy.refusal(file(name)) != nil)
}
check("refused executable .zip", LinkPolicy.refusal(file("exec.zip", mode: 0o755), allowArchives: true) != nil)
check("refused executable .txt", LinkPolicy.refusal(file("exec.txt", mode: 0o755)) != nil)
check("refused missing file", LinkPolicy.refusal(dir.appendingPathComponent("gone.pdf")) != nil)
check("refused folder", LinkPolicy.refusal(dir) != nil)
check("refused app bundle", LinkPolicy.refusal(URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
check("refused app binary", LinkPolicy.refusal(URL(fileURLWithPath: "/System/Applications/Calculator.app/Contents/MacOS/Calculator")) != nil)
let link = dir.appendingPathComponent("calc.txt")
try! FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
check("refused .txt symlink to an app", LinkPolicy.refusal(link) != nil)
check("refused javascript:", LinkPolicy.refusal(URL(string: "javascript:alert(1)")!) != nil)
check("refused spacebar:", LinkPolicy.refusal(URL(string: "spacebar://bundle/index.html")!) != nil)
check("refused mailto:", LinkPolicy.refusal(URL(string: "mailto:a@b.c")!) != nil)
check("allowed https", LinkPolicy.refusal(URL(string: "https://example.com/x")!) == nil)
check("refused hostless http", LinkPolicy.refusal(URL(string: "http:///x")!) != nil)

// A per-file Open With binding names Calculator; the opener must use the type's default app instead.
let note = file("openwith.txt")
let plist = try! PropertyListSerialization.data(fromPropertyList: ["bundleidentifier": "com.apple.calculator", "path": "/System/Applications/Calculator.app", "version": 0],
                                                format: .binary, options: 0)
_ = plist.withUnsafeBytes { setxattr(note.path, "com.apple.LaunchServices.OpenWith", $0.baseAddress, plist.count, 0, 0) }
let bound = NSWorkspace.shared.urlForApplication(toOpen: note)
let chosen = LinkPolicy.opener(for: note)?.app
print("  per-file binding resolves to \(bound?.path ?? "nil"); opener picks \(chosen?.path ?? "nil")")
check("opener ignores a per-file Open With binding", chosen != nil && chosen?.lastPathComponent != "Calculator.app")
check("opener resolves symlinks", LinkPolicy.opener(for: link) == nil)

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
