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
check("panel keys are cosmetic only", Settings.panelKeys.isSubset(of: ["theme", "appearance", "fontSize", "width", "bodyFont", "lineHeight"]))

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

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") settings checks")
exit(failures == 0 ? 0 : 1)
