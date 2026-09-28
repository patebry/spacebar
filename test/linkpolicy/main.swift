// Checks Shared/LinkPolicy.swift on files in a fresh temp folder: build and run with test/linkpolicy/run.sh. Opens nothing.
import AppKit
import UniformTypeIdentifiers

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-linkpolicy-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
func file(_ name: String, _ text: String = "x\n", mode: Int = 0o644) -> URL {
    let u = dir.appendingPathComponent(name)
    FileManager.default.createFile(atPath: u.path, contents: Data(text.utf8), attributes: [.posixPermissions: mode])
    return u
}

for name in ["a.zip", "a.tar", "a.tar.gz", "a.tgz", "a.tar.bz2", "a.tar.xz", "a.7z", "a.tbz", "a.tbz2", "a.txz"] {
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

// Data and property lists open in their default apps; a type that only conforms to a property list does not (a .terminal file
// runs its command in Terminal), nor does XML (a browser would run its stylesheet).
for name in ["data.json", "conf.yaml", "conf.yml", "Info.plist"] { check("allowed \(name)", LinkPolicy.refusal(file(name)) == nil) }
check("refused .terminal and .xml still", LinkPolicy.refusal(file("y.terminal")) != nil && LinkPolicy.refusal(file("y.xml")) != nil)
// An RTFD is a package: the one folder that may open.
let rtfd = dir.appendingPathComponent("doc.rtfd")
try! FileManager.default.createDirectory(at: rtfd, withIntermediateDirectories: true)
FileManager.default.createFile(atPath: rtfd.appendingPathComponent("TXT.rtf").path, contents: Data("{\\rtf1 hi}".utf8))
check("allowed an .rtfd package; a plain folder still refused", LinkPolicy.refusal(rtfd) == nil && LinkPolicy.refusal(dir) != nil)

// Opening in a text editor: a script or an executable file is text there, never run; what a browser or the system would act on
// is still refused, and so is anything that is not one file.
for name in ["run.sh", "tool.py", "run.command", "x.xml", "noextension", "data.json", "notes.txt", "x.scpt", "Makefile"] {
    check("editor: allowed \(name)", LinkPolicy.editorRefusal(file(name)) == nil)
}
check("editor: allowed an executable script", LinkPolicy.editorRefusal(file("exec.sh", mode: 0o755)) == nil)
for name in ["page.html", "page.xhtml", "pic.svg", "go.webloc", "go.inetloc", "go.fileloc", "x.mobileconfig", "x.ics", "x.vcf", "x.terminal",
             "x.pkg", "x.dmg"] {
    check("editor: refused \(name)", LinkPolicy.editorRefusal(file(name)) != nil)
}
check("editor: refused a folder, a package, a missing file, an app", LinkPolicy.editorRefusal(dir) != nil && LinkPolicy.editorRefusal(rtfd) != nil
      && LinkPolicy.editorRefusal(dir.appendingPathComponent("gone.sh")) != nil
      && LinkPolicy.editorRefusal(URL(fileURLWithPath: "/System/Applications/Calculator.app")) != nil)
if UTType(filenameExtension: "env")?.identifier == "md.spacebar.type.env" {
    check("editor: refused .env and .npmrc (spacebar's secret-bearing types stay in the preview)",
          LinkPolicy.editorRefusal(file("a.env")) != nil && LinkPolicy.editorRefusal(file("a.npmrc")) != nil)
} else {
    print("SKIP .env: md.spacebar.type.env is not registered on this Mac")
}
func app(_ path: String) -> URL { URL(fileURLWithPath: path) }
check("text editors: TextEdit is one", LinkPolicy.isTextEditor(app("/System/Applications/TextEdit.app")))
check("text editors: Terminal, Script Editor, Safari, Calculator and spacebar are not",
      !LinkPolicy.isTextEditor(app("/System/Applications/Utilities/Terminal.app")) && !LinkPolicy.isTextEditor(app("/System/Applications/Utilities/Script Editor.app"))
      && !LinkPolicy.isTextEditor(app("/Applications/Safari.app")) && !LinkPolicy.isTextEditor(app("/System/Applications/Calculator.app"))
      && !LinkPolicy.isTextEditor(dir))
let py = file("script.py")
let viaEditor = LinkPolicy.textOpener(for: py, editor: "com.apple.TextEdit")
check("textOpener: a script goes to the chosen text editor", viaEditor?.app.lastPathComponent == "TextEdit.app" && viaEditor?.editor == true)
let viaTerminal = LinkPolicy.textOpener(for: py, editor: "com.apple.Terminal")
print("  a script with Terminal chosen: \(viaTerminal.map { "\($0.app.lastPathComponent) editor=\($0.editor)" } ?? "nil")")
check("textOpener: a terminal named as the editor is never used, and a script never goes to its default app",
      viaTerminal.map { $0.app.lastPathComponent != "Terminal.app" && $0.editor && LinkPolicy.isTextEditor($0.app) } ?? true)
let txt = LinkPolicy.textOpener(for: file("plain.txt"), editor: nil)
check("textOpener: with no editor chosen, text opens in its default app", txt != nil && txt?.editor == false && txt?.app == LinkPolicy.opener(for: file("plain.txt"))?.app)
check("textOpener: nothing for HTML, a folder or a missing file", LinkPolicy.textOpener(for: file("p.html"), editor: "com.apple.TextEdit") == nil
      && LinkPolicy.textOpener(for: dir, editor: "com.apple.TextEdit") == nil && LinkPolicy.textOpener(for: dir.appendingPathComponent("none.py"), editor: nil) == nil)

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
