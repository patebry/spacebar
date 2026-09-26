// Checks Shared/Settings.swift: tolerant decoding, clamping, the allow-list, merge-preserving writes. Build and run with
// test/settings/run.sh, which points SPACEBAR_SUPPORT_DIR at a temp folder.
import Foundation

if CommandLine.arguments.count > 1 {
    for i in 0..<100 { _ = SettingsFile.update([CommandLine.arguments[1] == "a" ? "fontSize" : "lineHeight": CommandLine.arguments[1] == "a" ? 12 + i % 12 : 1.2 + Double(i % 8) / 10]) }
    exit(0)
}
let exe = CommandLine.arguments[0]
var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }
func obj(_ json: String) -> [String: Any] { (try! JSONSerialization.jsonObject(with: Data(json.utf8))) as! [String: Any] }
func decode(_ json: String) -> Settings? { try? JSONDecoder().decode(Settings.self, from: Data(json.utf8)) }

let dir = SettingsFile.supportDir
check("support dir comes from SPACEBAR_SUPPORT_DIR", dir.path == ProcessInfo.processInfo.environment["SPACEBAR_SUPPORT_DIR"])
check("support dir is not the real one", !dir.path.contains("/Library/Application Support/"))

// Decoding
check("empty object gives defaults", Settings(dictionary: [:]) == Settings())
check("Codable empty object gives defaults", decode("{}") == Settings())
check("remote images are off by default", !Settings().remoteImages && decode("{}")?.remoteImages == false && !Settings(dictionary: ["remoteImages": "yes"]).remoteImages)
check("remote images can be turned on", Settings(dictionary: ["remoteImages": true]).remoteImages)
let s1 = Settings(dictionary: obj(#"{"theme":"nord","fontSize":18,"width":"wide","stats":false,"userTheme":"dracula.css"}"#))
check("valid values taken", s1.theme == "nord" && s1.fontSize == 18 && s1.width == "wide" && !s1.stats && s1.userTheme == "dracula.css")
let s2 = Settings(dictionary: obj(#"{"theme":"hacker","fontSize":"big","width":7,"stats":"no","math":1,"bogus":true}"#))
check("invalid values fall back to defaults", s2 == Settings())
check("font size clamped high", Settings(dictionary: ["fontSize": 99]).fontSize == 24)
check("font size clamped low", Settings(dictionary: ["fontSize": -3]).fontSize == 12)
check("font size rounded", Settings(dictionary: ["fontSize": 16.6]).fontSize == 17)
check("line height clamped", Settings(dictionary: ["lineHeight": 9.5]).lineHeight == 2.0 && Settings(dictionary: ["lineHeight": 0]).lineHeight == 1.2)
check("bool is not a number", Settings(dictionary: ["fontSize": true]).fontSize == 15)
check("number is not a bool", Settings(dictionary: ["stats": 0]).stats == true)
check("NaN-free: huge number clamps", Settings(dictionary: ["fontSize": 1e300]).fontSize == 24)
check("rawHTML on is refused", Settings(dictionary: ["rawHTML": "on"]).rawHTML == "sanitized")
check("rawHTML off accepted", Settings(dictionary: ["rawHTML": "off"]).rawHTML == "off")
check("Codable tolerant of wrong types", decode(#"{"theme":5,"fontSize":"x","toc":"on","lineHeight":1.8}"#).map { $0.theme == "apple" && $0.fontSize == 15 && $0.toc == "on" && $0.lineHeight == 1.8 } == true)
check("Codable clamps", decode(#"{"fontSize":40}"#)?.fontSize == 24)
check("null clears an optional", Settings(dictionary: ["userTheme": NSNull()]).userTheme == nil)

// Path-like values
for bad in ["../x.css", "/etc/passwd", "a/b.css", ".hidden.css", "x.js", "x.css/..", "..css", "x\u{0}.css", String(repeating: "a", count: 80) + ".css", "c:\\x.css"] {
    check("user theme refused: \(bad.prefix(24))", Settings(dictionary: ["userTheme": bad]).userTheme == nil)
}
for good in ["dracula.css", "My Theme-2.css", "a.b.css"] { check("user theme allowed: \(good)", Settings.validUserTheme(good)) }
check("bundle id validated", Settings(dictionary: ["editorBundleID": "com.microsoft.VSCode"]).editorBundleID == "com.microsoft.VSCode"
      && Settings(dictionary: ["editorBundleID": "../../bin/sh"]).editorBundleID == nil && Settings(dictionary: ["editorBundleID": "x"]).editorBundleID == nil)

// Round trip
var custom = Settings(); custom.theme = "paper"; custom.userTheme = "t.css"; custom.fontSize = 20; custom.lineHeight = 1.75
check("dictionary round trip", Settings(dictionary: custom.dictionary) == custom)
check("json has every key", Set(obj(custom.json).keys) == Settings.allKeys.union(["version"]))

// Files
let fm = FileManager.default
check("load with no file gives defaults", SettingsFile.load() == Settings())
check("ensure creates the folder and a default file", SettingsFile.ensure() == nil && fm.fileExists(atPath: SettingsFile.url.path) && fm.fileExists(atPath: SettingsFile.themesDir.path))
check("default file loads as defaults", SettingsFile.load() == Settings())
try! Data(#"{"theme":"nord","futureKey":{"a":1}}"#.utf8).write(to: SettingsFile.url)
check("ensure leaves an existing file alone", SettingsFile.ensure() == nil && SettingsFile.load().theme == "nord")
if case .success(let s) = SettingsFile.update(["fontSize": 30, "theme": "github"]) {
    check("update merges and clamps", s.fontSize == 24 && s.theme == "github")
} else { check("update merges and clamps", false) }
let rawAfter = obj(String(data: fm.contents(atPath: SettingsFile.url.path)!, encoding: .utf8)!)
check("update keeps unknown keys", (rawAfter["futureKey"] as? [String: Any])?["a"] as? Int == 1)
check("update wrote version", rawAfter["version"] as? Int == 1)

// Allow-list
_ = SettingsFile.update(["theme": "solarized", "userTheme": "evil.css", "editorBundleID": "com.evil.app", "customCSS": false,
                         "inlineEditing": false, "rawHTML": "off", "remoteImages": true], allowed: Settings.panelKeys)
let afterPanel = SettingsFile.load()
check("panel allow-list takes theme", afterPanel.theme == "solarized")
check("panel allow-list drops userTheme/editor/customCSS/editing/rawHTML/remoteImages",
      afterPanel.userTheme == nil && afterPanel.editorBundleID == nil && afterPanel.customCSS && afterPanel.inlineEditing
      && afterPanel.rawHTML == "sanitized" && !afterPanel.remoteImages)
check("panel keys are cosmetic only", Settings.panelKeys.isSubset(of: ["theme", "appearance", "fontSize", "width", "bodyFont", "lineHeight", "sidebarCollapsed"]))

// sidebarCollapsed: the sidebar button's state, a panel key that takes a JSON boolean only.
check("sidebar open by default", !Settings().sidebarCollapsed && decode("{}")?.sidebarCollapsed == false)
check("sidebarCollapsed true taken", Settings(dictionary: ["sidebarCollapsed": true]).sidebarCollapsed && decode(#"{"sidebarCollapsed":true}"#)?.sidebarCollapsed == true)
check("sidebarCollapsed non-bool falls back", [1, 0, "true", "yes", NSNull(), [true]].allSatisfy { !Settings(dictionary: ["sidebarCollapsed": $0]).sidebarCollapsed }
      && decode(#"{"sidebarCollapsed":1}"#)?.sidebarCollapsed == false && decode(#"{"sidebarCollapsed":"true"}"#)?.sidebarCollapsed == false)
check("sidebarCollapsed is a panel key", Settings.panelKeys.contains("sidebarCollapsed"))
check("panel patch takes a bool", Settings.panelPatch("sidebarCollapsed", NSNumber(value: true)).map { obj(String(data: $0, encoding: .utf8)!)["sidebarCollapsed"] as? Bool } == true)
check("panel patch refuses a number, string, null or array for it", [NSNumber(value: 1), NSNumber(value: 0), "true", NSNull(), [true]].allSatisfy { Settings.panelPatch("sidebarCollapsed", $0) == nil })
check("panel patch refuses keys outside the panel", ["folderMode", "inlineEditing", "remoteImages", "editorBundleID", "bogus"].allSatisfy { Settings.panelPatch($0, true) == nil })
try? fm.removeItem(at: SettingsFile.url)
_ = SettingsFile.update(["folderMode": true, "theme": "nord"])
let writerPatch = try! JSONSerialization.data(withJSONObject: ["sidebarCollapsed": true, "folderMode": false, "remoteImages": true])
if case .success(let s)? = SettingsFile.updateFromPanel(writerPatch) {
    check("writer patch persists sidebarCollapsed and drops the rest", s.sidebarCollapsed && s.folderMode && !s.remoteImages && s.theme == "nord"
          && SettingsFile.load().sidebarCollapsed)
} else { check("writer patch persists sidebarCollapsed and drops the rest", false) }
_ = SettingsFile.updateFromPanel(Data(#"{"sidebarCollapsed":1}"#.utf8))
check("writer ignores a non-bool sidebarCollapsed", SettingsFile.load().sidebarCollapsed)
check("writer refuses a non-object or oversized patch", SettingsFile.updateFromPanel(Data("[true]".utf8)) == nil
      && SettingsFile.updateFromPanel(Data(#"{"theme":"nord","x":"\#(String(repeating: "a", count: 5000))"}"#.utf8)) == nil)
_ = SettingsFile.updateFromPanel(Data(#"{"sidebarCollapsed":false}"#.utf8))
check("writer patch turns it back off", !SettingsFile.load().sidebarCollapsed)

// Data safety: a file that is not a JSON object is never overwritten.
try! Data("{ this is not json".utf8).write(to: SettingsFile.url)
if case .failure(.notAnObject) = SettingsFile.update(["theme": "nord"]) { check("malformed file refused", true) } else { check("malformed file refused", false) }
check("malformed file left untouched", String(data: fm.contents(atPath: SettingsFile.url.path)!, encoding: .utf8) == "{ this is not json")
check("malformed file loads as defaults", SettingsFile.load() == Settings())
try! Data("[1,2]".utf8).write(to: SettingsFile.url)
if case .failure(.notAnObject) = SettingsFile.update(["theme": "nord"]) { check("array file refused", true) } else { check("array file refused", false) }
try! fm.removeItem(at: SettingsFile.url)
try! fm.createSymbolicLink(atPath: SettingsFile.url.path, withDestinationPath: "/etc/hosts")
if case .failure = SettingsFile.update(["theme": "nord"]) { check("symlinked settings refused", true) } else { check("symlinked settings refused", false) }
try! fm.removeItem(at: SettingsFile.url)
let real = dir.appendingPathComponent("real-settings.json")
try! Data(#"{"theme":"paper"}"#.utf8).write(to: real)
try! fm.createSymbolicLink(atPath: SettingsFile.url.path, withDestinationPath: real.path)
check("symlink to own regular file is read", SettingsFile.load().theme == "paper")
if case .failure = SettingsFile.update(["theme": "nord"]) { check("but never written through", String(data: fm.contents(atPath: real.path)!, encoding: .utf8) == #"{"theme":"paper"}"#) } else { check("but never written through", false) }
try! fm.removeItem(at: SettingsFile.url)
try! fm.createSymbolicLink(atPath: SettingsFile.url.path, withDestinationPath: "/etc/hosts")
check("symlink target untouched", (try? fm.destinationOfSymbolicLink(atPath: SettingsFile.url.path)) == "/etc/hosts")
try! fm.removeItem(at: SettingsFile.url)
try! Data(repeating: 0x20, count: Settings.maxFileBytes + 1).write(to: SettingsFile.url)
if case .failure(.tooLarge) = SettingsFile.update(["theme": "nord"]) { check("oversized file refused", true) } else { check("oversized file refused", false) }
try! fm.removeItem(at: SettingsFile.url)

// Concurrent updates from two processes (the app and a writer) both land.
try? fm.removeItem(at: SettingsFile.url)
_ = SettingsFile.update(["theme": "nord"])
let procs = ["a", "b"].map { arg -> Process in let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = [arg]; try! p.run(); return p }
procs.forEach { $0.waitUntilExit() }
let merged = SettingsFile.load()
check("concurrent updates keep each other's keys", merged.theme == "nord" && merged.fontSize == 12 + 99 % 12 && abs(merged.lineHeight - (1.2 + Double(99 % 8) / 10)) < 0.001)

// User themes
try! Data("/* spacebar-theme name=\"Dracula Night\" appearance=dark */\n:root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("dracula.css"))
try! Data(":root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("plain.css"))
try! Data("x".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("script.js"))
try! Data("x".utf8).write(to: SettingsFile.themesDir.appendingPathComponent(".hidden.css"))
let themes = UserTheme.list()
check("user themes listed (.css only, no hidden)", themes.map(\.file) == ["dracula.css", "plain.css"])
check("header parsed", themes.first == UserTheme(file: "dracula.css", name: "Dracula Night", appearance: "dark"))
check("headerless theme named by file", themes.last == UserTheme(file: "plain.css", name: "plain", appearance: "auto"))

// Support folder rename: spacebar.md/ moves to spacebar/ once; the new one wins when both exist.
let base = dir.appendingPathComponent("appsupport", isDirectory: true)
let newDir = base.appendingPathComponent("spacebar", isDirectory: true), oldDir = base.appendingPathComponent("spacebar.md", isDirectory: true)
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
check("migrate: no folders, nothing moves", !SettingsFile.migrateLegacySupportDir(in: base) && SettingsFile.supportDir(in: base) == newDir)
try! fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
try! Data("old".utf8).write(to: oldDir.appendingPathComponent("settings.json"))
check("migrate: legacy read in place before migration", SettingsFile.supportDir(in: base) == oldDir)
check("migrate: only legacy exists, it moves", SettingsFile.migrateLegacySupportDir(in: base) && !fm.fileExists(atPath: oldDir.path)
      && (try? String(contentsOf: newDir.appendingPathComponent("settings.json"))) == "old" && SettingsFile.supportDir(in: base) == newDir)
check("migrate: second run is a no-op", !SettingsFile.migrateLegacySupportDir(in: base))
try! fm.createDirectory(at: oldDir, withIntermediateDirectories: true)
try! Data("stale".utf8).write(to: oldDir.appendingPathComponent("settings.json"))
check("migrate: both exist, new wins and legacy untouched", !SettingsFile.migrateLegacySupportDir(in: base)
      && SettingsFile.supportDir(in: base) == newDir && (try? String(contentsOf: oldDir.appendingPathComponent("settings.json"))) == "stale"
      && (try? String(contentsOf: newDir.appendingPathComponent("settings.json"))) == "old")
try! fm.removeItem(at: newDir)
try! fm.createDirectory(at: newDir, withIntermediateDirectories: true)
check("migrate: an empty new folder is never replaced", !SettingsFile.migrateLegacySupportDir(in: base) && fm.fileExists(atPath: oldDir.appendingPathComponent("settings.json").path))
check("migrate: skipped under SPACEBAR_SUPPORT_DIR", !SettingsFile.migrateLegacySupportDir())
try! fm.removeItem(at: base)

// Sidebar listing (Shared/FolderListing.swift)
let ld = dir.appendingPathComponent("listing", isDirectory: true)
let outside = dir.appendingPathComponent("outside", isDirectory: true)
try? fm.removeItem(at: ld); try? fm.removeItem(at: outside)
try! fm.createDirectory(at: ld.appendingPathComponent("sub.md", isDirectory: true), withIntermediateDirectories: true)
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
func touch(_ name: String, _ age: Double, in d: URL = ld) {
    let u = d.appendingPathComponent(name)
    try! Data("# \(name)\n".utf8).write(to: u)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
}
touch("b.md", 30); touch("a.markdown", 10); touch("README.md", 50); touch("c10.md", 20); touch("c9.MD", 40)
touch("notes.txt", 0); touch(".hidden.md", 0); touch("flagged.md", 0); touch("secret.md", 0, in: outside)
chflags(ld.appendingPathComponent("flagged.md").path, UInt32(UF_HIDDEN))
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("inside-link.md").path, withDestinationPath: "b.md")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("outside-link.md").path, withDestinationPath: outside.appendingPathComponent("secret.md").path)
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("dangling.md").path, withDestinationPath: "nowhere.md")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("etc.md").path, withDestinationPath: "/etc/hosts")
mkfifo(ld.appendingPathComponent("pipe.md").path, 0o600)
let names = { (l: FolderListing.Listing) in l.files.map(\.name) }
let byName = FolderListing.list(ld.path, sort: "name", readmeFirst: true)
check("listing: README first, then names in Finder order", names(byName) == ["README.md", "a.markdown", "b.md", "c9.MD", "c10.md", "inside-link.md"])
check("listing: hidden, flagged hidden, non-Markdown, folders, FIFOs skipped", !names(byName).contains { [".hidden.md", "flagged.md", "notes.txt", "sub.md", "pipe.md"].contains($0) })
check("listing: links out of the folder or dangling skipped", !names(byName).contains { ["outside-link.md", "dangling.md", "etc.md"].contains($0) })
check("listing: a link inside the folder resolves to its target", byName.files.last?.resolved == (FolderListing.realPath(ld.path)! + "/b.md")
      && byName.files.last?.path == ld.path + "/inside-link.md")
check("listing: README not first when that is off", names(FolderListing.list(ld.path, sort: "name", readmeFirst: false)).first == "a.markdown")
check("listing: by date modified, newest first, README still first",
      names(FolderListing.list(ld.path, sort: "modified", readmeFirst: true)) == ["README.md", "a.markdown", "c10.md", "b.md", "inside-link.md", "c9.MD"])
let capped = FolderListing.list(ld.path, sort: "name", readmeFirst: true, cap: 2)
check("listing: capped, with a count of the rest", names(capped) == ["README.md", "a.markdown"] && capped.more == 4)
let pinned = FolderListing.list(ld.path, sort: "name", readmeFirst: true, cap: 2, pinned: ld.path + "/c10.md")
check("listing: the document on screen is listed past the cap", names(pinned) == ["README.md", "a.markdown", "c10.md"] && pinned.more == 3)
check("listing: the entry of the document on screen", byName.entry(resolving: ld.path + "/c9.MD")?.name == "c9.MD" && byName.entry(resolving: ld.path + "/notes.txt") == nil)
let payload = byName.payload(active: ld.path + "/b.md")
check("listing: payload names the folder and the active file", payload["dirName"] as? String == "listing" && payload["more"] as? Int == 0
      && (payload["files"] as? [[String: String]])?.first == ["name": "README.md", "path": ld.path + "/README.md"] && payload["active"] as? String == ld.path + "/b.md")
check("listing: a missing folder lists nothing", FolderListing.list(ld.path + "/nope", sort: "name", readmeFirst: true).files.isEmpty)
let big = dir.appendingPathComponent("big", isDirectory: true)
try! fm.createDirectory(at: big, withIntermediateDirectories: true)
for i in 0..<620 { fm.createFile(atPath: big.appendingPathComponent(String(format: "note-%04d.md", i)).path, contents: Data()) }
let t0 = Date()
let bigList = FolderListing.list(big.path, sort: "modified", readmeFirst: true)
check("listing: 620 files cap at 500 with 120 more (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)", bigList.files.count == FolderListing.cap && bigList.more == 120)
try! fm.removeItem(at: big); try! fm.removeItem(at: ld); try! fm.removeItem(at: outside)

// The folder watch behind the sidebar's live list
let wd = dir.appendingPathComponent("watched", isDirectory: true)
try! fm.createDirectory(at: wd, withIntermediateDirectories: true)
var fired = 0
let spin = { (s: Double) in RunLoop.main.run(until: Date(timeIntervalSinceNow: s)) }
let watch = FolderWatch(path: wd.path) { fired += 1 }
for i in 0..<3 { fm.createFile(atPath: wd.appendingPathComponent("n\(i).md").path, contents: Data("x".utf8)) }
spin(0.4)
let afterAdd = fired
try! fm.removeItem(at: wd.appendingPathComponent("n0.md"))
spin(0.4)
let afterRemove = fired
try! fm.moveItem(at: wd.appendingPathComponent("n1.md"), to: wd.appendingPathComponent("renamed.md"))
spin(0.4)
check("folder watch: a burst of adds is one change, then a removal and a rename each one more", watch != nil && afterAdd == 1 && afterRemove == 2 && fired == 3)
try! fm.removeItem(at: wd)
spin(0.3)
check("folder watch: a deleted folder is no longer watched", fired <= 4 && FolderWatch(path: wd.path) {} == nil)
withExtendedLifetime(watch) {}

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") settings checks")
exit(failures == 0 ? 0 : 1)
