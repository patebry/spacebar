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
    check("editor: refused the dotfiles .env and .npmrc; .editorconfig, a text type, allowed",
          LinkPolicy.editorRefusal(file(".env")) != nil && LinkPolicy.editorRefusal(file(".npmrc")) != nil && LinkPolicy.editorRefusal(file(".editorconfig")) == nil)
} else {
    print("SKIP .env: md.spacebar.type.env is not registered on this Mac")
}
func app(_ path: String) -> URL { URL(fileURLWithPath: path) }
check("text editors: TextEdit is one", LinkPolicy.isTextEditor(app("/System/Applications/TextEdit.app")))
check("text editors: Terminal, Script Editor, Safari, Calculator and spacebar are not",
      !LinkPolicy.isTextEditor(app("/System/Applications/Utilities/Terminal.app")) && !LinkPolicy.isTextEditor(app("/System/Applications/Utilities/Script Editor.app"))
      && !LinkPolicy.isTextEditor(app("/Applications/Safari.app")) && !LinkPolicy.isTextEditor(app("/System/Applications/Calculator.app"))
      && !LinkPolicy.isTextEditor(dir))
// Office suites declare the Editor role for plain text but sniff content and can run macros: never editors.
for path in ["/Applications/LibreOffice.app", "/Applications/OpenOffice.app", "/Applications/Numbers.app", "/Applications/Pages.app",
             "/Applications/Keynote.app", "/Applications/Microsoft Word.app", "/Applications/Microsoft Excel.app", "/Applications/Microsoft PowerPoint.app"]
    where FileManager.default.fileExists(atPath: path) {
    check("text editors: \((path as NSString).lastPathComponent) is not one", !LinkPolicy.isTextEditor(app(path)))
}
check("text editors: office bundle IDs are denied by prefix", ["org.libreoffice.script", "org.openoffice.script", "com.microsoft.Word", "com.microsoft.Excel",
      "com.microsoft.Powerpoint", "com.apple.iWork.Numbers", "com.apple.iWork.Pages", "com.apple.iWork.Keynote"].allSatisfy { id in
    LinkPolicy.notEditorPrefixes.contains { id.lowercased().hasPrefix($0.lowercased()) } })
check("application: TextEdit by bundle ID is the system copy", LinkPolicy.application("com.apple.TextEdit")?.path == "/System/Applications/TextEdit.app")
check("application: an unknown bundle ID is nil", LinkPolicy.application("md.spacebar.test.none-\(UUID().uuidString)") == nil)
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

// Open With: the type's default app first, then the others that claim the type; never an app Open's refusals would not allow.
let bid = { (u: URL) in Bundle(url: u)?.bundleIdentifier ?? "" }
let txtApps = LinkPolicy.openWithApps(for: file("with.txt"))
print("  Open With for a .txt: \(txtApps.map(\.lastPathComponent).joined(separator: ", "))")
check("openWith: a .txt lists its default app first, at most 12", !txtApps.isEmpty && txtApps.first == LinkPolicy.opener(for: file("with.txt"))?.app
      && txtApps.count <= LinkPolicy.maxOpenWith)
check("openWith: no app twice, no terminal or script runner, no spacebar", Set(txtApps.map(bid)).count == txtApps.count
      && !txtApps.contains { LinkPolicy.notEditors.contains(bid($0)) || bid($0).lowercased().hasPrefix("md.spacebar") })
check("openWith: every app is in an Applications folder or the system's", txtApps.allSatisfy { u in
    ["/Applications/", "/System/", FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/"].contains { u.resolvingSymlinksInPath().path.hasPrefix($0) } })
check("openWith: a per-file Open With binding (Calculator) adds nothing", !LinkPolicy.openWithApps(for: note).contains { $0.lastPathComponent == "Calculator.app" }
      && LinkPolicy.openWith(note, app: "com.apple.calculator") == nil)
let browsers = Set(NSWorkspace.shared.urlsForApplications(toOpen: URL(string: "https://example.com")!).compactMap { bid($0) })
for name in ["with.txt", "with.ini", "with.log", "with.png", "with.pdf", "with.docx", "with.csv"] {
    let apps = LinkPolicy.openWithApps(for: file(name))
    check("openWith: \(name): no web browser or office suite beyond the default", apps.dropFirst().allSatisfy { u in
        !browsers.contains(bid(u)) && !LinkPolicy.notEditorPrefixes.contains { bid(u).lowercased().hasPrefix($0.lowercased()) } })
}
check("openWith: a text type offers only text editors beyond the default", txtApps.dropFirst().allSatisfy(LinkPolicy.isTextEditor))
let csvApps = LinkPolicy.openWithApps(for: file("with.csv"))
check("openWith: no office suite for a text type (a CSV)", csvApps.dropFirst().allSatisfy { u in !LinkPolicy.notEditorPrefixes.contains { bid(u).lowercased().hasPrefix($0.lowercased()) } })
for name in ["run.sh", "tool.py", "run.command", "page.html", "pic.svg", "go.webloc", "x.terminal", "x.mobileconfig", "x.ics", "x.pkg", "x.dmg", "x.jar", "x.scpt", "noextension"] {
    check("openWith: nothing for \(name)", LinkPolicy.openWithApps(for: file(name)).isEmpty && LinkPolicy.openWith(file(name), app: "com.apple.TextEdit") == nil)
}
check("openWith: nothing for an executable .txt, a folder, a missing file, an app, a .txt link to an app",
      LinkPolicy.openWithApps(for: file("exec2.txt", mode: 0o755)).isEmpty && LinkPolicy.openWithApps(for: dir).isEmpty
      && LinkPolicy.openWithApps(for: dir.appendingPathComponent("gone.txt")).isEmpty && LinkPolicy.openWithApps(for: app("/System/Applications/Calculator.app")).isEmpty
      && LinkPolicy.openWithApps(for: link).isEmpty)
if UTType(filenameExtension: "env")?.identifier == "md.spacebar.type.env" {
    check("openWith: nothing for .env, .npmrc or the dotfile .env (secret-bearing types stay in the preview)",
          LinkPolicy.openWithApps(for: file("b.env")).isEmpty && LinkPolicy.openWithApps(for: file("b.npmrc")).isEmpty && LinkPolicy.openWithApps(for: file(".env")).isEmpty)
} else {
    print("SKIP openWith .env: md.spacebar.type.env is not registered on this Mac")
}
check("openWith: an archive only where archives are allowed", LinkPolicy.openWithApps(for: file("b.zip")).isEmpty && !LinkPolicy.openWithApps(for: file("b.zip"), allowArchives: true).isEmpty)
if let first = txtApps.first {
    let o = LinkPolicy.openWith(file("with.txt"), app: bid(first))
    check("openWith: a listed app opens the resolved file", o?.app == first && o?.file.path == file("with.txt").resolvingSymlinksInPath().path)
}
check("openWith: an app not listed is refused (Terminal, Script Editor, an unknown ID)", ["com.apple.Terminal", "com.apple.ScriptEditor2", "md.spacebar.none"].allSatisfy {
    LinkPolicy.openWith(file("with.txt"), app: $0) == nil })

let fake: [URL: String] = [app("/Applications/Spacebar.app"): "md.spacebar.viewer", app("/Applications/Other.app"): "com.example.other",
                           app("/System/Applications/Preview.app"): "com.apple.Preview", app("/Applications/Spacebar2.app"): "MD.Spacebar.app",
                           app("/Applications/Chrome.app"): "com.google.Chrome", app("/Applications/Microsoft Word.app"): "com.microsoft.Word",
                           app("/Users/x/Downloads/Evil.app"): "com.example.evil", app("/Applications/Utilities/Terminal.app"): "com.apple.Terminal"]
let fakeID: (URL) -> String? = { fake[$0] }
let sb = app("/Applications/Spacebar.app"), other = app("/Applications/Other.app"), preview = app("/System/Applications/Preview.app")
let fakeBrowsers: Set<String> = ["com.google.chrome"]
func pick(_ def: URL?, _ c: [URL], _ t: UTType) -> URL? { LinkPolicy.notSpacebar(def, candidates: c, type: t, browsers: fakeBrowsers, bundleID: fakeID) }
check("notSpacebar: a default that is not spacebar is kept", pick(other, [preview], .png) == other)
check("notSpacebar: spacebar as an image's default gives Preview", pick(sb, [sb, other, preview], .png) == preview)
check("notSpacebar: a browser listed first is skipped",
      pick(sb, [sb, app("/Applications/Chrome.app"), other], .pdf) == other && pick(sb, [app("/Applications/Chrome.app")], .png) == nil)
check("notSpacebar: an office app, a terminal and an app outside the Applications folders are skipped",
      pick(sb, [app("/Applications/Microsoft Word.app"), app("/Applications/Utilities/Terminal.app"), app("/Users/x/Downloads/Evil.app"), other], .pdf) == other)
check("notSpacebar: spacebar as a text type's default gives nil (textOpener falls back to a text editor)",
      pick(sb, [app("/Applications/Spacebar2.app"), preview, other], .json) == nil && pick(sb, [other], .plainText) == nil)
check("notSpacebar: only spacebar candidates give nil",
      pick(sb, [sb, app("/Applications/Spacebar2.app")], .png) == nil && pick(nil, [], .json) == nil)
check("notSpacebar: real apps by bundle ID",
      LinkPolicy.notSpacebar(nil, candidates: [app("/System/Applications/TextEdit.app"), app("/System/Applications/Preview.app")], type: .png)?.lastPathComponent == "Preview.app")

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
