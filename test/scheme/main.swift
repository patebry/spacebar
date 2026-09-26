// Checks SchemeHandler.resolve: the user host serves only custom.css and themes/<name>.css from the support folder, and no
// URL spelling reaches another file. Build and run with test/scheme/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let dir = SettingsFile.supportDir
let fm = FileManager.default
_ = SettingsFile.ensure()
try! Data(":root{}".utf8).write(to: dir.appendingPathComponent("custom.css"))
try! Data(":root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("dark.css"))
try! Data("secret".utf8).write(to: dir.appendingPathComponent("secret.css"))
try! fm.createSymbolicLink(atPath: SettingsFile.themesDir.appendingPathComponent("link.css").path, withDestinationPath: "/etc/hosts")
try! fm.createDirectory(at: SettingsFile.themesDir.appendingPathComponent("dir.css"), withIntermediateDirectories: true)
try! Data(repeating: 0x20, count: SchemeHandler.maxUserCSSBytes + 1).write(to: SettingsFile.themesDir.appendingPathComponent("huge.css"))

let h = SchemeHandler(webRoot: URL(fileURLWithPath: CommandLine.arguments[1]))
func r(_ s: String) -> String? { URL(string: s).flatMap { h.resolve($0) }?.path }

try! Data(":root{}".utf8).write(to: SettingsFile.themesDir.appendingPathComponent("My Theme.css"))
var spaced = Settings(); spaced.userTheme = "My Theme.css"
let spacedURL = PageSettings.payload(spaced, supportDir: dir)["userThemeURL"] as? String ?? ""
check("theme with a space: payload URL is encoded and resolves", spacedURL.contains("My%20Theme.css") && r(spacedURL) != nil)
check("encoded separator inside a name refused", r("spacebar://user/themes/a%2Fdark.css") == nil && r("spacebar://user/themes/%2E%2E%2Fcustom.css") == nil)
check("custom.css served", r("spacebar://user/custom.css") == dir.appendingPathComponent("custom.css").path)
check("theme served", r("spacebar://user/themes/dark.css") == SettingsFile.themesDir.appendingPathComponent("dark.css").path)
check("theme with version query served", r("spacebar://user/themes/dark.css?v=123") != nil)
for bad in ["spacebar://user/settings.json", "spacebar://user/secret.css", "spacebar://user/../settings.json", "spacebar://user/themes/../settings.json",
            "spacebar://user/themes/..%2Fsettings.json", "spacebar://user/themes/%2E%2E/custom.css", "spacebar://user/themes/..%2F..%2F..%2Fetc%2Fhosts",
            "spacebar://user//custom.css", "spacebar://user/./custom.css", "spacebar://user/themes/sub/dark.css", "spacebar://user/themes/",
            "spacebar://user/themes/.hidden.css", "spacebar://user/themes/dark.css%00.png", "spacebar://user/custom.css/",
            "spacebar://user/themes/dir.css", "spacebar://user/themes/huge.css", "spacebar://user/themes/missing.css",
            "spacebar://user/%63ustom.css", "spacebar://USER/custom.css", "spacebar://bundle/../../settings.json", "spacebar://bundle/%2E%2E/Info.plist"] {
    check("refused \(bad)", r(bad) == nil)
}
check("symlinked theme refused", r("spacebar://user/themes/link.css") == nil)
check("bundle file served", r("spacebar://bundle/index.html") != nil)
check("file host: images only", r("spacebar://file/etc/hosts") == nil && r("spacebar://file/tmp/x.png") != nil)
let noFile = SchemeHandler(webRoot: URL(fileURLWithPath: CommandLine.arguments[1]), fileHost: false)
check("file host off for the app preview", URL(string: "spacebar://file/tmp/x.png").flatMap { noFile.resolve($0) } == nil)

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") scheme checks")
exit(failures == 0 ? 0 : 1)
