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
check("update wrote version", rawAfter["version"] as? Int == Settings.currentVersion)

// Allow-list
_ = SettingsFile.update(["theme": "solarized", "userTheme": "evil.css", "editorBundleID": "com.evil.app", "customCSS": false,
                         "inlineEditing": false, "rawHTML": "off", "remoteImages": true], allowed: Settings.panelKeys)
let afterPanel = SettingsFile.load()
check("panel allow-list takes theme", afterPanel.theme == "solarized")
check("panel allow-list drops userTheme/editor/customCSS/editing/rawHTML/remoteImages",
      afterPanel.userTheme == nil && afterPanel.editorBundleID == nil && afterPanel.customCSS && afterPanel.inlineEditing
      && afterPanel.rawHTML == "sanitized" && !afterPanel.remoteImages)
check("panel keys are cosmetic only", Settings.panelKeys.isSubset(of: ["theme", "appearance", "fontSize", "width", "bodyFont", "lineHeight", "sidebarCollapsed", "sidebarWidth", "folderSort"]))
check("folderSort: a panel key, name or modified only", Settings.panelPatch("folderSort", "modified").map { obj(String(data: $0, encoding: .utf8)!)["folderSort"] as? String } == "modified"
      && [NSNumber(value: 1), "size", NSNull(), ["name"]].allSatisfy { Settings.panelPatch("folderSort", $0) == nil })
check("welcomeShown: off by default, a bool only, not a panel key, kept by the file", !Settings().welcomeShown && Settings(dictionary: ["welcomeShown": true]).welcomeShown
      && [1, "true", NSNull()].allSatisfy { !Settings(dictionary: ["welcomeShown": $0]).welcomeShown } && decode(#"{"welcomeShown":true}"#)?.welcomeShown == true
      && Settings.allKeys.contains("welcomeShown") && Settings.panelPatch("welcomeShown", true) == nil)
check("spaceHelper and helperOffered: off by default, bools only, never panel keys",
      !Settings().spaceHelper && !Settings().helperOffered && Settings(dictionary: ["spaceHelper": true, "helperOffered": true]).helperOffered
      && [1, "true", NSNull()].allSatisfy { !Settings(dictionary: ["spaceHelper": $0, "helperOffered": $0]).spaceHelper && !Settings(dictionary: ["helperOffered": $0]).helperOffered }
      && decode(#"{"helperOffered":true,"spaceHelper":true}"#).map { $0.helperOffered && $0.spaceHelper } == true
      && Settings.panelPatch("spaceHelper", true) == nil && Settings.panelPatch("helperOffered", true) == nil)
do {
    // The settings app restarts the helper only for spaceHelper as settings.json has it: a hand-edited non-bool is off.
    let gate = { (raw: [String: Any]) in HelperState.shouldReregister(enabled: Settings(dictionary: raw).spaceHelper, agent: .enabled, answering: false, misses: 3) }
    check("spaceHelper gates the automatic reregister", gate(["spaceHelper": true]) && !gate([:]) && !gate(["spaceHelper": false])
          && !gate(["spaceHelper": 1]) && !gate(["spaceHelper": "true"]))
    _ = SettingsFile.update(["spaceHelper": true])
    _ = SettingsFile.updateFromPanel(Data(#"{"spaceHelper":false}"#.utf8))
    check("the preview panel cannot turn the helper (and so its reregister) off", SettingsFile.load().spaceHelper)
    _ = SettingsFile.update(["spaceHelper": false])
}
check("minimal chrome: off by default, a bool only, not a panel key", !Settings().minimalChrome && Settings(dictionary: ["minimalChrome": true]).minimalChrome
      && !Settings(dictionary: ["minimalChrome": 1]).minimalChrome && decode(#"{"minimalChrome":true}"#)?.minimalChrome == true
      && !Settings.panelKeys.contains("minimalChrome") && Settings.panelPatch("minimalChrome", true) == nil && Settings.allKeys.contains("minimalChrome"))
check("sidebar keys on by default, a bool only, not a panel key", Settings().sidebarKeys && !Settings(dictionary: ["sidebarKeys": false]).sidebarKeys
      && [0, "false", NSNull()].allSatisfy { Settings(dictionary: ["sidebarKeys": $0]).sidebarKeys } && decode(#"{"sidebarKeys":false}"#)?.sidebarKeys == false
      && Settings.allKeys.contains("sidebarKeys") && Settings.panelPatch("sidebarKeys", false) == nil)
check("hidden files off by default, a bool only, not a panel key", !Settings().showHiddenFiles && Settings(dictionary: ["showHiddenFiles": true]).showHiddenFiles
      && [1, "true", NSNull()].allSatisfy { !Settings(dictionary: ["showHiddenFiles": $0]).showHiddenFiles } && decode(#"{"showHiddenFiles":true}"#)?.showHiddenFiles == true
      && Settings.allKeys.contains("showHiddenFiles") && Settings.panelPatch("showHiddenFiles", true) == nil)
check("sidebar width: default 240, clamped to 160...480, rounded", Settings().sidebarWidth == 240 && Settings(dictionary: ["sidebarWidth": 90]).sidebarWidth == 160
      && Settings(dictionary: ["sidebarWidth": 9999]).sidebarWidth == 480 && Settings(dictionary: ["sidebarWidth": 301.6]).sidebarWidth == 302
      && decode(#"{"sidebarWidth":1000}"#)?.sidebarWidth == 480 && decode(#"{"sidebarWidth":"wide"}"#)?.sidebarWidth == 240
      && Settings(dictionary: ["sidebarWidth": true]).sidebarWidth == 240)
check("sidebar width: a panel key, clamped in the patch, a number only",
      Settings.panelPatch("sidebarWidth", 5000).map { obj(String(data: $0, encoding: .utf8)!)["sidebarWidth"] as? Int } == 480
      && Settings.panelPatch("sidebarWidth", 12).map { obj(String(data: $0, encoding: .utf8)!)["sidebarWidth"] as? Int } == 160
      && Settings.panelPatch("sidebarWidth", "300") == nil && Settings.panelPatch("sidebarWidth", NSNumber(value: true)) == nil && Settings.panelPatch("sidebarWidth", NSNull()) == nil)

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

// Sidebar tree listing (Shared/FolderListing.swift)
let ld = dir.appendingPathComponent("listing", isDirectory: true)
let outside = dir.appendingPathComponent("outside", isDirectory: true)
try? fm.removeItem(at: ld); try? fm.removeItem(at: outside)
for d in ["sub.md", "Zeta", "alpha", "alpha/deep", ".hiddendir", "Tool.app/Contents"] {
    try! fm.createDirectory(at: ld.appendingPathComponent(d, isDirectory: true), withIntermediateDirectories: true)
}
try! fm.createDirectory(at: outside, withIntermediateDirectories: true)
func touch(_ name: String, _ age: Double, in d: URL = ld) {
    let u = d.appendingPathComponent(name)
    try! Data("# \(name)\n".utf8).write(to: u)
    try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path)
}
touch("b.md", 30); touch("a.markdown", 10); touch("README.md", 50); touch("c10.md", 20); touch("c9.MD", 40)
touch("notes.txt", 5); touch("photo.png", 6); touch("paper.pdf", 7); touch("data.csv", 8); touch("main.ts", 9); touch("run.sh", 11)
touch(".hidden.md", 0); touch("flagged.md", 0); touch("secret.md", 0, in: outside); touch("inner.md", 0, in: ld.appendingPathComponent("alpha"))
chflags(ld.appendingPathComponent("flagged.md").path, UInt32(UF_HIDDEN))
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("inside-link.md").path, withDestinationPath: "b.md")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("inside-dir").path, withDestinationPath: "alpha")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("outside-link.md").path, withDestinationPath: outside.appendingPathComponent("secret.md").path)
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("outside-dir").path, withDestinationPath: outside.path)
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("etc").path, withDestinationPath: "/etc")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("up").path, withDestinationPath: "..")
try! fm.createSymbolicLink(atPath: ld.appendingPathComponent("dangling.md").path, withDestinationPath: "nowhere.md")
mkfifo(ld.appendingPathComponent("pipe.md").path, 0o600)
let names = { (l: FolderListing.Listing) in l.entries.map(\.name) }
let byName = FolderListing.list(ld.path, sort: "name", readmeFirst: true)
check("tree: folders first, then README, then files in Finder order",
      names(byName) == ["alpha", "inside-dir", "sub.md", "Zeta", "README.md", "a.markdown", "b.md", "c9.MD", "c10.md", "data.csv", "inside-link.md",
                        "main.ts", "notes.txt", "paper.pdf", "photo.png", "run.sh", "Tool.app"])
check("tree: folders are marked, a package is one item", byName.folders.map(\.name) == ["alpha", "inside-dir", "sub.md", "Zeta"]
      && byName.entries.first { $0.name == "Tool.app" }.map { !$0.isDirectory && $0.kind == .app } == true)
check("tree: hidden, flagged hidden, FIFOs skipped", !names(byName).contains { [".hidden.md", ".hiddendir", "flagged.md", "pipe.md"].contains($0) })
check("tree: links out of the root, to /etc, to the parent, or dangling are skipped",
      !names(byName).contains { ["outside-link.md", "outside-dir", "etc", "up", "dangling.md"].contains($0) })
let hidden = FolderListing.list(ld.path, sort: "name", readmeFirst: true, showHidden: true)
check("tree: showHidden lists dot files, flagged files and hidden folders", [".hidden.md", ".hiddendir", "flagged.md"].allSatisfy(names(hidden).contains)
      && !names(hidden).contains("pipe.md") && !names(hidden).contains("outside-link.md"))
check("tree: README not first when that is off", names(FolderListing.list(ld.path, sort: "name", readmeFirst: false))[4] == "a.markdown")
let byDate = FolderListing.list(ld.path, sort: "modified", readmeFirst: true).files.map(\.name)
check("tree: files by date modified, newest first, README still first", Array(byDate.prefix(5)) == ["README.md", "Tool.app", "notes.txt", "photo.png", "paper.pdf"])
let sub = FolderListing.list(ld.path + "/alpha", root: ld.path, sort: "name", readmeFirst: true)
check("tree: a subfolder of the root lists its own entries", names(sub) == ["deep", "inner.md"] && sub.entries.last?.path == ld.path + "/alpha/inner.md")
check("tree: a folder outside the root lists nothing", FolderListing.list(outside.path, root: ld.path, sort: "name", readmeFirst: true).entries.isEmpty
      && FolderListing.list(ld.path + "/outside-dir", root: ld.path, sort: "name", readmeFirst: true).entries.isEmpty
      && FolderListing.list(ld.path + "/..", root: ld.path, sort: "name", readmeFirst: true).entries.isEmpty
      && FolderListing.list("/etc", root: ld.path, sort: "name", readmeFirst: true).entries.isEmpty)
check("tree: a link to a folder inside the root lists it", names(FolderListing.list(ld.path + "/inside-dir", root: ld.path, sort: "name", readmeFirst: true)) == ["deep", "inner.md"])
let capped = FolderListing.list(ld.path, sort: "name", readmeFirst: true, cap: 2)
check("tree: capped, with a count of the rest", names(capped) == ["alpha", "inside-dir"] && capped.more == 15)
let pinned = FolderListing.list(ld.path, sort: "name", readmeFirst: true, cap: 2, pinned: ld.path + "/c10.md")
check("tree: the document on screen is listed past the cap", names(pinned) == ["alpha", "inside-dir", "c10.md"] && pinned.more == 14)
let payload = byName.payload(root: ld.path)
let pe = payload["entries"] as? [[String: Any]] ?? []
check("tree: payload names the root, the folder and each entry's icon", payload["rootName"] as? String == "listing" && payload["dir"] as? String == ld.path
      && payload["more"] as? Int == 0 && pe.first?["dir"] as? Bool == true && pe.first?["icon"] as? String == "folder"
      && pe.first { $0["name"] as? String == "data.csv" }?["icon"] as? String == "data" && pe.first { $0["name"] as? String == "Tool.app" }?["icon"] as? String == "app"
      && pe.first { $0["name"] as? String == "data.csv" }?["size"] is Int64 && pe.first?["size"] == nil
      && pe.first { $0["name"] as? String == "Tool.app" }.map { $0["size"] == nil } == true && (pe.first?["modified"] as? Double ?? 0) > 1e12)
check("tree: a missing folder lists nothing", FolderListing.list(ld.path + "/nope", sort: "name", readmeFirst: true).entries.isEmpty)
check("tree: a folder preview opens its README, else its first Markdown file, else nothing (the scan takes over)",
      FolderListing.firstDocument(byName)?.name == "README.md"
      && FolderListing.firstDocument(FolderListing.list(ld.path, sort: "name", readmeFirst: false))?.name == "README.md"
      && FolderListing.firstDocument(FolderListing.list(ld.path + "/alpha", root: ld.path, sort: "name", readmeFirst: true))?.name == "inner.md"
      && FolderListing.firstDocument(FolderListing.list(ld.path + "/alpha/deep", root: ld.path, sort: "name", readmeFirst: true)) == nil)
check("paths: inside the root, symlinks resolved", FolderListing.isInside(ld.path + "/b.md", root: ld.path) && FolderListing.isInside(ld.path + "/inside-link.md", root: ld.path)
      && !FolderListing.isInside(ld.path + "/outside-link.md", root: ld.path) && !FolderListing.isInside(ld.path + "/etc/hosts", root: ld.path)
      && !FolderListing.isInside(ld.path + "/../outside/secret.md", root: ld.path) && !FolderListing.isInside(ld.path, root: ld.path)
      && FolderListing.isInside(ld.path, root: ld.path, allowRoot: true) && !FolderListing.isInside(ld.path + "/up", root: ld.path, allowRoot: true))
check("paths: only plain spellings under the root", FolderListing.isPlainPath(ld.path + "/alpha/inner.md", under: ld.path)
      && !FolderListing.isPlainPath(ld.path + "/../outside/secret.md", under: ld.path) && !FolderListing.isPlainPath(ld.path + "/./b.md", under: ld.path)
      && !FolderListing.isPlainPath(ld.path + "//b.md", under: ld.path) && !FolderListing.isPlainPath(ld.path + "x/b.md", under: ld.path)
      && !FolderListing.isPlainPath("/etc/hosts", under: ld.path) && !FolderListing.isPlainPath(ld.path + "/alpha/..", under: ld.path))
let big = dir.appendingPathComponent("big", isDirectory: true)
try! fm.createDirectory(at: big, withIntermediateDirectories: true)
for i in 0..<5100 { fm.createFile(atPath: big.appendingPathComponent(String(format: "note-%04d.txt", i)).path, contents: Data()) }
for i in 0..<20 { try! fm.createDirectory(at: big.appendingPathComponent("dir-\(i)"), withIntermediateDirectories: true) }
let t0 = Date()
let bigList = FolderListing.list(big.path, sort: "modified", readmeFirst: true)
check("tree: 5,120 entries cap at 5,000 with 120 more, folders kept first (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)",
      FolderListing.cap == 5_000 && bigList.entries.count == FolderListing.cap && bigList.more == 120 && bigList.folders.count == 20 && bigList.entries[20].name.hasPrefix("note-"))
try! fm.removeItem(at: big); try! fm.removeItem(at: ld); try! fm.removeItem(at: outside)

// Type detection and the content-type map (Shared/FolderListing.swift, FileTypes)
let kinds: [(String, FileKind)] = [("a.md", .markdown), ("A.MARKDOWN", .markdown), ("p.png", .image), ("p.JPG", .image), ("p.jpeg", .image),
    ("p.gif", .image), ("p.webp", .image), ("p.heic", .image), ("x.svg", .image), ("d.pdf", .pdf), ("d.json", .json), ("d.csv", .csv),
    ("d.tsv", .csv), ("t.txt", .text), ("t.log", .text), ("s.js", .code), ("s.ts", .code), ("s.tsx", .code), ("s.jsx", .code), ("s.py", .code),
    ("s.rb", .code), ("s.go", .code), ("s.rs", .code), ("s.swift", .code), ("s.sh", .code), ("s.zsh", .code), ("s.c", .code), ("s.h", .code),
    ("s.cpp", .code), ("s.java", .code), ("s.kt", .code), ("s.css", .code), ("s.scss", .code), ("page.html", .html), ("page.htm", .html), ("page.xhtml", .code), ("s.xml", .code),
    ("s.yaml", .code), ("s.yml", .code), ("s.toml", .code), ("s.ini", .code), ("s.sql", .code), ("Dockerfile", .code), ("Makefile", .code),
    ("Gemfile", .code), (".env.example", .text), ("env.example", .text), ("LICENSE", .text), ("x.zip", .archive), ("x.bin", .app), ("noext", .other),
    ("v.mp4", .video), ("v.M4V", .video), ("v.mov", .video), ("v.webm", .other), ("a.mp3", .audio), ("a.m4a", .audio), ("a.aac", .audio),
    ("a.wav", .audio), ("a.aif", .audio), ("a.AIFF", .audio), ("a.flac", .audio), ("a.caf", .audio), ("a.ogg", .other)]
let wrong = kinds.filter { FileTypes.kind(name: $0.0) != $0.1 }.map { "\($0.0)=\(FileTypes.kind(name: $0.0))" }
check("types: every listed kind detected by name (\(wrong.joined(separator: " ")))", wrong.isEmpty)
// Every extension spacebar takes Space for (scripts/quicklook-types.txt, and the system types it claims) has a kind of its own.
let claimed: [(String, FileKind)] = [("s.rbw", .code), ("s.phtml", .code), ("s.php4", .code), ("x.tool", .code), ("s.cp", .code), ("s.c++", .code),
    ("s.hp", .code), ("s.h++", .code), ("s.ipp", .code), ("s.jav", .code), ("s.jscript", .code), ("s.mak", .code), ("s.make", .code), ("s.gmk", .code),
    ("s.proto", .code), ("s.applescript", .code), ("s.r", .code), ("x.command", .code), ("s.ksh", .code), ("s.mm", .code), ("s.patch", .code),
    ("d.geojson", .json), ("d.ipynb", .json), ("d.plist", .code), ("d.vtt", .text), ("a.tar", .archive), ("a.tar.gz", .archive), ("a.tgz", .archive),
    ("a.tar.bz2", .archive), ("a.bz2", .archive), ("a.tar.xz", .archive), ("a.7z", .archive), ("a.rar", .archive), ("a.tar.zst", .archive),
    ("n.txt.gz", .archive), ("w.dockerfile", .code), ("Dockerfile.dev", .code)]
let claimedWrong = claimed.filter { FileTypes.kind(name: $0.0) != $0.1 }.map { "\($0.0)=\(FileTypes.kind(name: $0.0))" }
check("types: every claimed system extension has its kind (\(claimedWrong.joined(separator: " ")))", claimedWrong.isEmpty)
let declared = try! String(contentsOfFile: "scripts/quicklook-types.txt", encoding: .utf8).split(separator: "\n")
    .filter { $0.hasPrefix("declare ") }.flatMap { $0.split(separator: " ")[1].split(separator: ",").map(String.init) }
let unmapped = declared.filter { FileTypes.kind(name: "f.\($0)") == .other }
check("types: all \(declared.count) declared extensions have a kind (\(unmapped.joined(separator: " ")))", declared.count > 60 && unmapped.isEmpty)
let langs: [(String, String?)] = [("a.toml", "ini"), ("a.go", "go"), ("a.rs", "rust"), ("a.kt", "kotlin"), ("a.cs", "csharp"), ("a.scss", "scss"),
    ("a.lua", "lua"), ("a.sql", "sql"), ("a.graphql", "graphql"), ("a.vb", "vbnet"), ("a.wat", "wasm"), ("a.gradle", "java"), ("a.vue", "xml"),
    ("a.xsd", "xml"), ("a.fish", "bash"), ("a.mak", "makefile"), ("a.phtml", "php"), ("a.hpp", "cpp"), ("a.dart", nil), ("a.zig", nil),
    ("a.scala", nil), ("a.dockerfile", nil)]
let langWrong = langs.filter { FileTypes.language(name: $0.0) != $0.1 }.map { "\($0.0)=\(FileTypes.language(name: $0.0) ?? "nil")" }
check("types: highlight.js languages for the new extensions, plain text where none is bundled (\(langWrong.joined(separator: " ")))", langWrong.isEmpty)
check("types: the writer lists exactly the extensions the viewer calls archives", ArchiveListing.extensions == FileTypes.archiveExtensions)
do {
    // 40 levels of [a, a] over one object: 2^40 nodes written out, from a few hundred bytes.
    // Written by hand: the serializer would write every copy out.
    var bomb = Data("bplist00".utf8) + Data([0x51, 0x78])
    var offsets: [UInt8] = [8]
    for i in 0..<40 { offsets.append(UInt8(bomb.count)); bomb += Data([0xA2, UInt8(i), UInt8(i)]) }
    let table = bomb.count
    let trailer: [UInt8] = [0, 0, 0, 0, 0, 0, 1, 1, 0, 0, 0, 0, 0, 0, 0, 41, 0, 0, 0, 0, 0, 0, 0, 40, 0, 0, 0, 0, 0, 0, 0, UInt8(table)]
    bomb += Data(offsets)
    bomb += Data(trailer)
    check("binary plist: the hand-made bomb is a valid plist", (try? PropertyListSerialization.propertyList(from: bomb, options: [], format: nil)) != nil)
    let t0 = Date()
    let converted = FileView.binaryPlistAsXML(bomb)
    check("binary plist: a small file that names one object over and over is not converted (\(bomb.count) bytes, \(Int(Date().timeIntervalSince(t0) * 1000)) ms)",
          converted == nil && Date().timeIntervalSince(t0) < 2)
}
do {
    // 119 KB: one 20 KB blob named 99,000 times, under the node limit; written out it would be 2.7 GB of XML.
    let bomb = try! Data(contentsOf: URL(fileURLWithPath: "test/settings/fixtures/blob-bomb.plist"))
    let t0 = Date()
    let converted = FileView.binaryPlistAsXML(bomb)
    check("binary plist: one large blob named over and over is not converted (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)",
          converted == nil && Date().timeIntervalSince(t0) < 2)
}
check("types: archives use the other icon and bucket", FileKind.archive.icon == "other" && FolderScan.bucket(.archive) == "other")
do {
    let d = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spacebar-plist-\(getpid())")
    try! fm.createDirectory(at: d, withIntermediateDirectories: true)
    let bin = d.appendingPathComponent("Info.plist"), xml = d.appendingPathComponent("x.plist"), zip = d.appendingPathComponent("a.zip")
    try! PropertyListSerialization.data(fromPropertyList: ["Name": "spacebar", "List": [1, 2]], format: .binary, options: 0).write(to: bin)
    try! Data("<?xml version=\"1.0\"?><plist version=\"1.0\"><string>hi</string></plist>\n".utf8).write(to: xml)
    try! Data("PK\u{5}\u{6}".utf8 + Data(count: 18)).write(to: zip)
    let b = FileView.payload(path: bin.path, kind: .code, root: d.path, reason: "open", canOpen: true)
    let x = FileView.payload(path: xml.path, kind: .code, root: d.path, reason: "open", canOpen: true)
    let z = FileView.payload(path: zip.path, kind: .archive, root: d.path, reason: "open", canOpen: true)
    check("binary plist: shown as XML text, highlighted as XML, named for what it is",
          b["view"] as? String == "code" && (b["text"] as? String ?? "").contains("<key>Name</key>") && b["lang"] as? String == "xml"
          && (b["kindName"] as? String ?? "").contains("Binary"))
    check("XML plist: shown as it is", x["view"] as? String == "code" && (x["text"] as? String ?? "").hasPrefix("<?xml") && !(x["kindName"] as? String ?? "").contains("Binary"))
    check("archive: its own view, with no contents until the writer lists them", z["view"] as? String == "archive" && z["text"] == nil && z["entries"] == nil)
    let locked = d.appendingPathComponent("locked.txt")
    try! Data("secret".utf8).write(to: locked)
    chmod(locked.path, 0)
    let l = FileView.payload(path: locked.path, kind: .text, root: d.path, reason: "open", canOpen: true)
    check("unreadable (chmod 000) text: the info card says it couldn’t be read, and offers no app",
          geteuid() == 0 || (l["view"] as? String == "info" && l["note"] as? String == "This file couldn’t be read." && l["canOpen"] as? Bool == false))
    try? fm.removeItem(at: d)
}
check("claims summary names archives and Markdown", QuickLookClaims.summary.contains("archives") && QuickLookClaims.summary.hasPrefix("Markdown"))
do {
    // The claims by group, from scripts/quicklook-types.txt as the app carries it, and how another extension's claims overlap them.
    let text = try! String(contentsOf: URL(fileURLWithPath: "scripts/quicklook-types.txt"), encoding: .utf8)
    let claims = QuickLookClaims.parse(text)
    let lines = text.split(separator: "\n").filter { $0.hasPrefix("claim ") || $0.hasPrefix("declare ") }
    let group = { (t: String) in claims.first { $0.type == t }?.group }
    check("claims: every claim and declaration parsed, once", claims.count == lines.count && Set(claims.map(\.type)).count == claims.count)
    check("claims: grouped by the section they are listed in",
          group("net.daringfireball.markdown") == .markdown && group("public.markdown") == .markdown && group("public.swift-source") == .code
          && group("md.spacebar.type.go") == .code && group("public.json") == .data && group("com.apple.log") == .data
          && group("md.spacebar.type.ipynb") == .data && group("public.zip-archive") == .archives && group("public.data") == .other
          && group("md.spacebar.type.toml") == .text && group("md.spacebar.type.env") == .text)
    check("claims: only public.data is in the no-extension group", claims.filter { $0.group == .other }.map(\.type) == ["public.data"])
    check("claims: a declaration keeps its extensions", claims.first { $0.type == "md.spacebar.type.kt" }?.extensions == ["kt", "kts"])
    let exts: [String: [String]] = ["public.swift-source": ["swift"], "com.vendor.swift": ["swift"], "dyn.go": ["go"], "public.json": ["json"],
                                    "public.plain-text": ["txt", "text"], "public.png": ["png"]]
    let o = QuickLookClaims.overlap(ours: claims, theirs: ["public.swift-source", "com.vendor.swift", "dyn.go", "public.json", "public.json",
                                                            "public.plain-text", "public.source-code", "public.png", "com.acme.markdown",
                                                            "md.spacebar.type.rs"], extensions: { exts[$0] ?? [] })
    check("overlap: the same type, a vendor or dyn type for the same extension, any Markdown type; not a parent, Apple's own or spacebar's IDs",
          o == [.code: ["com.vendor.swift", "dyn.go", "public.swift-source"], .data: ["public.json"], .markdown: ["com.acme.markdown"]])
    check("overlap: none for an image previewer", QuickLookClaims.overlap(ours: claims, theirs: ["public.png", "public.jpeg"], extensions: { exts[$0] ?? [] }).isEmpty)
    check("overlap: described Markdown first, then the largest group", QuickLookClaims.describe(o) == "Markdown (1 type), code (3 types), data (1 type)")
}
check("types: an executable with no extension is an app; a folder a folder; a package an item",
      FileTypes.kind(name: "tool", executable: true) == .app && FileTypes.kind(name: "src", isDirectory: true) == .folder
      && FileTypes.kind(name: "X.app", isDirectory: true, isPackage: true) == .app && FileTypes.kind(name: "d.pages", isDirectory: true, isPackage: true) == .other
      && FileTypes.kind(name: "d.rtfd", isDirectory: true, isPackage: true) == .rtf)
check("types: video and audio share the media icon and overview bucket; HTML is listed as code",
      FileKind.video.icon == "media" && FileKind.audio.icon == "media" && FolderScan.bucket(.video) == "media" && FolderScan.bucket(.audio) == "media"
      && FileKind.html.icon == "code" && FolderScan.bucket(.html) == "code")
do {
    let media = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spacebar-media-\(getpid())")
    try! fm.createDirectory(at: media, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: media) }
    let clip = media.appendingPathComponent("clip.mp4"), song = media.appendingPathComponent("song.wav"), huge = media.appendingPathComponent("huge.mov")
    try! Data(count: 4096).write(to: clip)
    try! Data(count: 2048).write(to: song)
    fm.createFile(atPath: huge.path, contents: nil)
    truncate(huge.path, off_t(FileTypes.maxFileBytes + 1))
    let v = FileView.payload(path: clip.path, kind: .video, root: media.path, reason: "open", canOpen: true)
    let a = FileView.payload(path: song.path, kind: .audio, root: media.path, reason: "open", canOpen: true)
    let h = FileView.payload(path: huge.path, kind: .video, root: media.path, reason: "open", canOpen: true)
    let d = FileView.payload(path: media.path, kind: .video, root: media.path, reason: "open", canOpen: true)
    check("payload: a video or audio file is played natively, with its kind and size; one past 512 MB or not a file is its info card",
          v["view"] as? String == "video" && v["size"] as? Int64 == 4096 && (v["kindName"] as? String)?.isEmpty == false && v["icon"] as? String == "video" && a["icon"] as? String == "audio"
          && a["view"] as? String == "audio" && a["size"] as? Int64 == 2048 && h["view"] as? String == "info" && d["view"] as? String == "info")
}
check("types: highlight.js languages", FileTypes.language(name: "a.ts") == "typescript" && FileTypes.language(name: "a.tsx") == "typescript"
      && FileTypes.language(name: "page.html") == "xml" && FileTypes.language(name: "Makefile") == "makefile" && FileTypes.language(name: "Dockerfile") == nil
      && FileTypes.language(name: "a.sh") == "bash" && FileTypes.language(name: "a.toml") == "ini")
check("types: icons", [FileKind.json, .csv].allSatisfy { $0.icon == "data" } && FileKind.app.icon == "other" && FileKind.code.icon == "code")
let glyphs: [(String, FileKind, String)] = [("a.ttf", .other, "font"), ("a.docx", .other, "doc"), ("a.XLSX", .other, "sheet"), ("a.key", .other, "slides"),
    ("a.usdz", .other, "model"), ("a.webm", .other, "video"), ("a.ogg", .other, "audio"), ("a.zip", .archive, "archive"), ("Tool.app", .app, "app"),
    ("a.mp4", .video, "video"), ("a.wav", .audio, "audio"), ("a.json", .json, "data"), ("a.html", .html, "code"), ("a.dat", .other, "other"), ("sub", .folder, "folder")]
check("types: the sidebar's finer icons, by kind and then extension", glyphs.allSatisfy { FileTypes.glyph(name: $0.0, kind: $0.1) == $0.2 })
check("content types: images and PDF by the map, SVG as an image",
      FileTypes.contentType(forPath: "/a/b.PNG") == "image/png" && FileTypes.contentType(forPath: "/a/b.jpg") == "image/jpeg"
      && FileTypes.contentType(forPath: "/a/b.svg") == "image/svg+xml" && FileTypes.contentType(forPath: "/a/b.pdf") == "application/pdf")
check("content types: anything else is octet-stream, never HTML or script", ["/a/b.html", "/a/b.htm", "/a/b.js", "/a/b.xhtml", "/a/b.xml", "/a/b.md",
      "/a/b.txt", "/a/b", "/a/b.css", "/a/b.json", "/a/b.svgz", "/a/b.php"].allSatisfy { FileTypes.contentType(forPath: $0) == FileTypes.octetStream })
check("text sniff: text yes, NUL or invalid UTF-8 no, a cut character yes", FileTypes.looksLikeText(Data("héllo\n".utf8))
      && !FileTypes.looksLikeText(Data([0x41, 0x00, 0x42])) && !FileTypes.looksLikeText(Data([0xff, 0xfe, 0x41, 0x80]))
      && FileTypes.looksLikeText(Data("ab".utf8) + Data([0xc3])))

// Folder previews (Shared/FolderScan.swift): which folders are taken, what each opens on, the overview, the wikilink index
let fx = dir.appendingPathComponent("folders", isDirectory: true)
func put(_ rel: String, _ text: String = "x\n", age: Double = 0) {
    let u = fx.appendingPathComponent(rel)
    try! fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(text.utf8).write(to: u)
    if age > 0 { try! fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -age)], ofItemAtPath: u.path) }
}
func mkdir(_ rel: String) { try! fm.createDirectory(at: fx.appendingPathComponent(rel), withIntermediateDirectories: true) }
let vault = fx.path + "/Vault"
put("Vault/.obsidian/app.json", "{}"); put("Vault/.obsidian/workspace.md", "# not a note\n")
put("Vault/Daily/2026-09-20.md", "# Old day\n", age: 5000); put("Vault/Daily/2026-09-25.md", "# Day\n\nSee [[Projects/Plan]] and [[Ideas#Later|ideas]].\n", age: 100)
put("Vault/Projects/Plan.md", "# Plan\n\n![[diagram.png]] ![[Ideas]]\n", age: 3000); put("Vault/Notes/Ideas.md", "# Ideas\n\n## Later\n", age: 4000)
put("Vault/Archive/Old/Ideas.md", "# Old ideas\n", age: 9000); put("Vault/Attachments/diagram.png", "png")
put("Vault/Projects/Deep/a/b/c/d/far.md", "# far\n")
check("folder rules: a vault whose notes are all in subfolders is previewed (it was declined: no top-level Markdown)",
      FolderRules.declineReason(vault) == nil && FolderListing.firstDocument(FolderListing.list(vault, sort: "name", readmeFirst: true)) == nil)
let vs = FolderScan.scan(vault)
check("finder: the vault opens on its newest note nearest the top, never inside .obsidian",
      vs.bestMarkdown?.rel == "Daily/2026-09-25.md" && !vs.files.contains { $0.rel.hasPrefix(".obsidian") } && vs.hasObsidian && vs.complete)
check("finder: depth stops at 3", !vs.files.contains { $0.rel.hasSuffix("far.md") } && vs.files.allSatisfy { $0.depth <= FolderScan.maxDepth })
check("finder: a preferred name wins at the same depth", {
    put("Vault/Projects/Index.md", "# index\n", age: 99999)
    defer { try? fm.removeItem(atPath: vault + "/Projects/Index.md") }
    put("Vault/Home.md", "# home\n", age: 99999)
    defer { try? fm.removeItem(atPath: vault + "/Home.md") }
    return FolderListing.firstDocument(FolderListing.list(vault, sort: "name", readmeFirst: true))?.name == "Home.md"
        && FolderScan.scan(vault).bestMarkdown?.rel == "Home.md"
}())
let idx = LinkIndex.build(root: vault)
check("wikilinks: by name anywhere under the root, the current folder first, then the shallowest",
      idx.resolve("Ideas", from: vault + "/Daily/2026-09-25.md") == vault + "/Notes/Ideas.md"
      && idx.resolve("Ideas", from: vault + "/Archive/Old/x.md") == vault + "/Archive/Old/Ideas.md"
      && idx.resolve("ideas.md", from: nil) == vault + "/Notes/Ideas.md" && idx.resolve("diagram.png", from: nil) == vault + "/Attachments/diagram.png")
check("wikilinks: a path from the root, or a partial path", idx.resolve("Projects/Plan", from: nil) == vault + "/Projects/Plan.md"
      && idx.resolve("Old/Ideas", from: nil) == vault + "/Archive/Old/Ideas.md" && idx.resolve("Archive/Old/Ideas.md", from: nil) == vault + "/Archive/Old/Ideas.md" && idx.resolve("/Projects/Plan.md", from: nil) == vault + "/Projects/Plan.md")
check("wikilinks: never outside the root, never .obsidian, never a dot step",
      [ "../secret", "Vault/../../x", "./Ideas", "Projects/../Ideas", "workspace", ".obsidian/workspace", "app.json", "", "a\u{0}b", String(repeating: "a", count: 500)]
        .allSatisfy { idx.resolve($0, from: nil) == nil })
put("outside/secret.md", "# secret\n")
try! fm.createSymbolicLink(atPath: vault + "/secret.md", withDestinationPath: fx.path + "/outside/secret.md")
try! fm.createSymbolicLink(atPath: vault + "/Linked", withDestinationPath: fx.path + "/outside")
try! fm.createSymbolicLink(atPath: vault + "/alias.md", withDestinationPath: "Notes/Ideas.md")
let idx2 = LinkIndex.build(root: vault)
check("wikilinks: a link out of the root is not indexed, a linked folder is not followed, a link inside is",
      idx2.resolve("secret", from: nil) == nil && idx2.resolve("Linked/secret", from: nil) == nil && idx2.resolve("alias", from: nil) == vault + "/alias.md")
check("wikilinks: parts and targets", LinkIndex.parse("Note#Head|Alias") == ("Note", "Head", "Alias") && LinkIndex.parse("a\\|b") == ("a", "", "b")
      && LinkIndex.links(in: "[[A]] ![[b.png|30]] [[A|again]] [[#Local]] [[x\n]] [[C#h]]").map { "\($0.embed ? "!" : "")\($0.target)" } == ["A", "!b.png", "C"])
let lp = idx2.payload(text: "[[Ideas]] ![[diagram.png]] ![[Projects/Plan]] [[nowhere]]", current: vault + "/Daily/2026-09-25.md")
check("wikilinks: the render payload resolves links, gives images their file URL, embeds a note's text one level deep",
      (lp.links["Ideas"] as? [String: Any])?["path"] as? String == vault + "/Notes/Ideas.md" && lp.links["nowhere"] == nil
      && ((lp.links["diagram.png"] as? [String: Any])?["src"] as? String)?.hasPrefix("spacebar://file" + vault + "/Attachments/diagram.png?v=") == true
      && ((lp.embeds["Projects/Plan"] as? [String: Any])?["text"] as? String)?.hasPrefix("# Plan") == true
      && lp.paths == [vault + "/Notes/Ideas.md", vault + "/Attachments/diagram.png", vault + "/Projects/Plan.md"])
let many = (0..<30).map { "![[n\($0)]]" }.joined(separator: " ")
for i in 0..<30 { put("Vault/n\(i).md", String(repeating: "word ", count: 20_000)) }
let lp2 = LinkIndex.build(root: vault).payload(text: many, current: nil)
check("wikilinks: embeds are capped in number and size", lp2.embeds.count <= LinkIndex.maxEmbeds
      && lp2.embeds.values.allSatisfy { (($0 as? [String: Any])?["text"] as? String)?.utf8.count ?? 0 <= LinkIndex.maxEmbedBytes })
check("vault root: a note in a vault's subfolder is rooted at the vault; outside a vault there is none",
      FolderRules.vaultRoot(containing: vault + "/Daily") == vault && FolderRules.vaultRoot(containing: vault) == vault
      && FolderRules.vaultRoot(containing: fx.path + "/outside") == nil)
check("vault root: never /tmp or /var, however they are spelled", FolderRules.vaultRoot(containing: "/tmp/x") == nil
      && FolderRules.vaultRoot(containing: "/var/x") == nil && FolderRules.vaultRoot(containing: "/private/tmp/x") == nil)
let downloaded = vault + "/Daily/2026-09-20.md"
check("quarantine: a downloaded note is recognised (and so keeps its own folder as its root)", !FolderRules.isQuarantined(downloaded)
      && setxattr(downloaded, "com.apple.quarantine", "0081;00000000;Safari;", 21, 0, 0) == 0 && FolderRules.isQuarantined(downloaded))

// Folders of one kind: images, PDFs, a code repository, nothing at all
for i in 0..<4 { put("images/p\(i).png", "png", age: Double(i * 10)) }
for i in 0..<3 { put("pdfs/d\(i).pdf", "%PDF", age: Double(i * 10)) }
put("repo/.git/HEAD", "ref\n"); put("repo/src/main.swift", "print(1)\n"); put("repo/package.json", "{}"); put("repo/node_modules/x/README.md", "# dep\n")
put("repo/docs/guide.md", "# Guide\n")
mkdir("empty")
let imgs = FolderScan.scan(fx.path + "/images"), pdfs = FolderScan.scan(fx.path + "/pdfs"), repo = FolderScan.scan(fx.path + "/repo"),
    empty = FolderScan.scan(fx.path + "/empty")
check("overview: a folder of images has no Markdown to open: counts and recent files, newest first",
      FolderRules.declineReason(fx.path + "/images") == nil && imgs.bestMarkdown == nil && imgs.counts == ["image": 4]
      && imgs.recent.map(\.rel) == ["p0.png", "p1.png", "p2.png", "p3.png"])
check("overview: a folder of PDFs", pdfs.bestMarkdown == nil && pdfs.counts == ["pdf": 3] && (pdfs.payload(reason: "open")["view"] as? String) == "overview")
check("finder: a repository without a README opens its docs, never a dependency's README, and is labelled",
      repo.bestMarkdown?.rel == "docs/guide.md" && !repo.files.contains { $0.rel.contains("node_modules") } && repo.hasGit
      && repo.payload(reason: "open")["label"] as? String == "Git repository")
check("overview: an empty folder is previewed, with nothing in it", FolderRules.declineReason(fx.path + "/empty") == nil && empty.files.isEmpty
      && empty.folders == 0 && (empty.payload(reason: "open")["total"] as? Int) == 0)
let op = imgs.payload(reason: "open"), recent = op["recent"] as? [[String: Any]] ?? []
check("overview: payload names only files inside the root", op["path"] as? String == fx.path + "/images"
      && recent.count == 4 && recent.allSatisfy { ($0["path"] as? String)?.hasPrefix(fx.path + "/images/") == true })

// A huge folder: the listing and the scan stay bounded
let huge = fx.appendingPathComponent("huge")
mkdir("huge")
for i in 0..<12_000 { fm.createFile(atPath: huge.appendingPathComponent(String(format: "f%05d.txt", i)).path, contents: nil) }
var t1 = Date()
let hl = FolderListing.list(huge.path, sort: "name", readmeFirst: true, pinned: huge.path + "/f11999.txt")
let listMs = Int(Date().timeIntervalSince(t1) * 1000)
t1 = Date()
let hs = FolderScan.scan(huge.path)
let scanMs = Int(Date().timeIntervalSince(t1) * 1000)
t1 = Date()
let hi = LinkIndex.build(root: huge.path, maxEntries: 5_000)
let indexMs = Int(Date().timeIntervalSince(t1) * 1000)
check("huge folder: 12,000 files list 500 plus the pinned file, the rest counted (\(listMs) ms)",
      hl.entries.count == FolderListing.cap + 1 && hl.more == 12_000 - hl.entries.count && hl.entries.last?.name == "f11999.txt" && listMs < 1500)
check("huge folder: the scan stops at its entry cap or time budget (\(scanMs) ms, \(hs.scanned) entries)",
      !hs.complete && hs.scanned <= FolderScan.maxEntries && scanMs < 1000)
check("huge folder: the index stops at its cap (\(indexMs) ms)", !hi.complete && hi.count <= 5_000 && indexMs < 1500)

// Declines: packages, app bundles, volumes and system folders; everything else is previewed
mkdir("Tool.app/Contents"); mkdir("Doc.rtfd"); mkdir("Proj.xcodeproj"); mkdir("plain.folder.name")
check("declines: an app bundle and packages", FolderRules.declineReason(fx.path + "/Tool.app") != nil
      && FolderRules.declineReason(fx.path + "/Doc.rtfd") != nil && FolderRules.declineReason(fx.path + "/Proj.xcodeproj") != nil)
check("declines: the volume root and system folders", ["/", "/System", "/Library", "/usr", "/usr/bin", "/System/Library", "/private/var", "/Volumes",
      "/Applications", FolderRules.home + "/Library"].allSatisfy { FolderRules.declineReason($0) != nil })
check("declines: not an ordinary folder, a dotted name, the home folder or a folder in /tmp's subtree",
      FolderRules.declineReason(fx.path + "/plain.folder.name") == nil && FolderRules.declineReason(fx.path) == nil
      && FolderRules.declineReason(FolderRules.home) == nil && FolderRules.declineReason(FolderRules.home + "/Library/NoSuchFolder") != nil)
try! fm.removeItem(at: fx)

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

// Version 2: folder previews on by default, and on once for files written before it.
let migDir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-migrate-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: migDir, withIntermediateDirectories: true)
let migFile = migDir.appendingPathComponent("settings.json")
check("defaults: folder previews on, version 2", Settings().folderMode && Settings().version == 2)
try! Data(#"{"version": 1, "folderMode": false, "theme": "nord"}"#.utf8).write(to: migFile)
check("a version-1 file reads as folder previews on", SettingsFile.load(at: migFile).folderMode)
SettingsFile.migrate(at: migFile)
let migrated = (try! JSONSerialization.jsonObject(with: Data(contentsOf: migFile))) as! [String: Any]
check("migrate turns folder previews on once and writes version 2, keeping other keys",
      migrated["folderMode"] as? Bool == true && (migrated["version"] as? NSNumber)?.intValue == 2 && migrated["theme"] as? String == "nord")
_ = SettingsFile.update(["folderMode": false], at: migFile)
SettingsFile.migrate(at: migFile)
check("turned off after the migration stays off", SettingsFile.load(at: migFile).folderMode == false)
try! Data(#"{"folderMode": false}"#.utf8).write(to: migFile)
_ = SettingsFile.update(["folderMode": false], at: migFile)
check("an unversioned file's off in the same write is kept", SettingsFile.load(at: migFile).folderMode == false)
try? FileManager.default.removeItem(at: migDir)
SettingsFile.migrate(at: migFile)
check("migrate creates nothing when there is no file", !FileManager.default.fileExists(atPath: migFile.path))

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") settings checks")
exit(failures == 0 ? 0 : 1)
