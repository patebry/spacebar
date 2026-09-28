import Foundation

// The welcome sheet's "Try it" folder, made in a scratch SPACEBAR_SUPPORT_DIR: every sample file, valid JSON, nothing overwritten.
var failed = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failed += 1 }
}

let fm = FileManager.default
let dir = SampleFolder.url
check("the sample folder is in the support folder", dir.deletingLastPathComponent().path == SettingsFile.supportDir.path && dir.lastPathComponent == "Sample Folder")
guard case .success(let made) = SampleFolder.create() else { check("created", false); exit(1) }
let names = SampleFolder.files.map(\.0)
check("created with every sample file", made == dir && names.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) })
check("mixed kinds: Markdown, CSV, JSON, a notebook, code, text and an image",
      Set(names.map { ($0 as NSString).pathExtension }) == ["md", "csv", "json", "ipynb", "py", "txt", "svg"])
for n in names where n.hasSuffix(".json") || n.hasSuffix(".ipynb") {
    let data = fm.contents(atPath: dir.appendingPathComponent(n).path) ?? Data()
    check("\(n) is valid JSON", (try? JSONSerialization.jsonObject(with: data)) != nil)
}
let readme = dir.appendingPathComponent("README.md")
try! Data("# mine\n".utf8).write(to: readme)
try! fm.removeItem(at: dir.appendingPathComponent("data.csv"))
guard case .success = SampleFolder.create() else { check("made again", false); exit(1) }
check("made again: an edited file is kept, a deleted one comes back",
      String(data: fm.contents(atPath: readme.path)!, encoding: .utf8) == "# mine\n" && fm.fileExists(atPath: dir.appendingPathComponent("data.csv").path))
let blocked = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-welcome-\(getpid())")
try! Data("a file, not a folder".utf8).write(to: blocked)
if case .failure = SampleFolder.create(in: blocked) { check("a path it cannot use is an error, not a crash", true) } else { check("a path it cannot use is an error, not a crash", false) }
try? fm.removeItem(at: blocked)
check("welcomeShown starts off", !SettingsFile.load().welcomeShown)
_ = SettingsFile.update(["welcomeShown": true])
check("welcomeShown is saved", SettingsFile.load().welcomeShown)
print(failed == 0 ? "\nall welcome checks" : "\n\(failed) welcome checks failed")
exit(failed == 0 ? 0 : 1)
