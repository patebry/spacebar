import CoreGraphics
import Foundation
import ImageIO

// The welcome sheet's "Try it" folder, made under a scratch home (never the real one): every sample file, valid JSON, a PNG and
// a one-page PDF drawn on the spot, nothing overwritten.
var failed = 0
func check(_ name: String, _ ok: Bool) {
    print("\(ok ? "PASS" : "FAIL") \(name)")
    if !ok { failed += 1 }
}

let fm = FileManager.default
let realHome = FileManager.default.homeDirectoryForCurrentUser
check("the sample folder is spacebar Sample Folder in the home folder, outside Documents and Desktop",
      SampleFolder.url() == realHome.appendingPathComponent("spacebar Sample Folder", isDirectory: true))
let home = SettingsFile.supportDir.deletingLastPathComponent().appendingPathComponent("home", isDirectory: true)
let dir = SampleFolder.url(home: home)
check("the folder follows the home it is given", dir.deletingLastPathComponent().standardizedFileURL.path == home.standardizedFileURL.path)
guard case .success(let made) = SampleFolder.create(in: dir) else { check("created", false); exit(1) }
let names = SampleFolder.names
check("created with every sample file", made == dir && names.allSatisfy { fm.fileExists(atPath: dir.appendingPathComponent($0).path) })
check("mixed kinds: Markdown, CSV, JSON, a notebook, code, text, an SVG, a PNG and a PDF",
      Set(names.map { ($0 as NSString).pathExtension }) == ["md", "csv", "json", "ipynb", "py", "txt", "svg", "png", "pdf"])
let png = dir.appendingPathComponent("keyboard.png")
let image = CGImageSourceCreateWithURL(png as CFURL, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) }
check("keyboard.png is a PNG that decodes", CGImageSourceCreateWithURL(png as CFURL, nil).flatMap(CGImageSourceGetType) as String? == "public.png"
      && image.map { $0.width == 1280 && $0.height == 720 } == true)
let pdf = CGPDFDocument(dir.appendingPathComponent("guide.pdf") as CFURL)
check("guide.pdf is a one-page PDF", pdf?.numberOfPages == 1)
let tour = String(data: fm.contents(atPath: dir.appendingPathComponent("README.md").path) ?? Data(), encoding: .utf8) ?? ""
check("the tour names the image and the PDF, and how editing works",
      tour.contains("`keyboard.png`") && tour.contains("`guide.pdf`") && tour.contains("Esc") && tour.contains("⌘Z"))
for n in names where n.hasSuffix(".json") || n.hasSuffix(".ipynb") {
    let data = fm.contents(atPath: dir.appendingPathComponent(n).path) ?? Data()
    check("\(n) is valid JSON", (try? JSONSerialization.jsonObject(with: data)) != nil)
}
let readme = dir.appendingPathComponent("README.md")
try! Data("# mine\n".utf8).write(to: readme)
try! fm.removeItem(at: dir.appendingPathComponent("data.csv"))
guard case .success = SampleFolder.create(in: dir) else { check("made again", false); exit(1) }
check("made again: an edited file is kept, a deleted one comes back",
      String(data: fm.contents(atPath: readme.path)!, encoding: .utf8) == "# mine\n" && fm.fileExists(atPath: dir.appendingPathComponent("data.csv").path))
let blocked = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sb-welcome-\(getpid())")
try! Data("a file, not a folder".utf8).write(to: blocked)
if case .failure = SampleFolder.create(in: blocked) { check("a path it cannot use is an error, not a crash", true) } else { check("a path it cannot use is an error, not a crash", false) }
try? fm.removeItem(at: blocked)
check("welcomeShown starts off", !SettingsFile.load().welcomeShown)
_ = SettingsFile.update(["welcomeShown": true])
check("welcomeShown is saved", SettingsFile.load().welcomeShown)
var fresh = Settings(), upgraded = Settings(), offered = Settings()
upgraded.welcomeShown = true
offered.welcomeShown = true; offered.helperOffered = true
check("a first launch sees the introduction, then the helper's offer", fresh.welcomeSteps(helperAvailable: true, openerAvailable: false) == [.intro, .helper])
check("an upgrade that dismissed the introduction sees only the offer", upgraded.welcomeSteps(helperAvailable: true, openerAvailable: false) == [.helper])
check("once offered, nothing", offered.welcomeSteps(helperAvailable: true, openerAvailable: false).isEmpty)
check("a copy without a usable helper never offers it", fresh.welcomeSteps(helperAvailable: false, openerAvailable: false) == [.intro] && upgraded.welcomeSteps(helperAvailable: false, openerAvailable: false).isEmpty)
check("a copy that can be the default app offers it last, once", fresh.welcomeSteps(helperAvailable: true, openerAvailable: true) == [.intro, .helper, .opener]
      && offered.welcomeSteps(helperAvailable: false, openerAvailable: true) == [.opener])
_ = SettingsFile.update(["helperOffered": true])
check("helperOffered is saved", SettingsFile.load().helperOffered && SettingsFile.load().welcomeSteps(helperAvailable: true, openerAvailable: false).isEmpty)
_ = SettingsFile.update(["spaceHelper": true, "theme": "nord"])
guard case .success(let reset) = SettingsFile.update(Settings.resetPatch()) else { check("Reset to Defaults writes", false); exit(1) }
check("Reset to Defaults does not bring the welcome sheet or the helper's offer back", reset.welcomeSteps(helperAvailable: true, openerAvailable: false).isEmpty)
check("Reset to Defaults leaves Use spacebar for every file on", reset.spaceHelper && reset.theme == "apple")
_ = SettingsFile.update(["helperOffered": false])
guard case .success(let resetBeforeOffer) = SettingsFile.update(Settings.resetPatch()) else { check("Reset to Defaults writes", false); exit(1) }
check("a reset before the offer was answered still offers the helper once", resetBeforeOffer.welcomeSteps(helperAvailable: true, openerAvailable: false) == [.helper])
let welcomeSource = (try? String(contentsOfFile: "App/Welcome.swift", encoding: .utf8)) ?? ""
check("the welcome sheet names Settings, not a tab it no longer has",
      welcomeSource.contains("in Settings.") && !["Settings, General", "Settings, Advanced", "Settings, Sidebar"].contains { welcomeSource.contains($0) })
check("the welcome sheet says Not Now, offers Try Again itself, and links to how the helper works",
      welcomeSource.contains("Button(\"Not Now\")") && welcomeSource.contains("Button(\"Try Again\")") && !welcomeSource.contains("Try again in Settings")
        && welcomeSource.contains("HelperCopy.securityURL") && welcomeSource.contains("two places"))
print(failed == 0 ? "\nall welcome checks" : "\n\(failed) welcome checks failed")
exit(failed == 0 ? 0 : 1)
