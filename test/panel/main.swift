// Checks the Space panel's own pieces: where it opens and the per-display frames it remembers (Viewer/PanelFrame.swift), and
// what ⌘C puts on the pasteboard (Viewer/FinderCopy.swift). Build and run with test/panel/run.sh.
import Cocoa

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: Any = "") { print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " \(detail)")"); if !ok { failures += 1 } }

let vf = NSRect(x: 0, y: 25, width: 1440, height: 875)
let small = NSRect(x: 0, y: 25, width: 1024, height: 743)
let second = NSRect(x: 1440, y: 0, width: 1920, height: 1055)
let minSize = NSSize(width: 480, height: 320)
let inside = { (r: NSRect, v: NSRect) in v.contains(r) && r == r.integral }

let first = PanelFrame.placement(saved: nil, visible: vf, minSize: minSize)
check("nothing saved: about 60% of the screen, centred", first == NSRect(x: 288, y: 200, width: 864, height: 525), first)
check("nothing saved on a large screen: capped at 1200×900", PanelFrame.placement(saved: nil, visible: NSRect(x: 0, y: 0, width: 3000, height: 2000), minSize: minSize).size == NSSize(width: 1200, height: 900))

let moved = NSRect(x: 40, y: 60, width: 1100, height: 700)
check("a saved frame that fits comes back as it was", PanelFrame.placement(saved: moved, visible: vf, minSize: minSize) == moved)

let shrunk = PanelFrame.placement(saved: moved, visible: small, minSize: minSize)
check("the screen got smaller: the saved frame is shrunk into it", inside(shrunk, small) && shrunk.width == 1024 && shrunk.height == 700, shrunk)

let off = PanelFrame.placement(saved: NSRect(x: 1300, y: 800, width: 600, height: 400), visible: vf, minSize: minSize)
check("a frame hanging off the edge is moved back on, its size kept", inside(off, vf) && off.size == NSSize(width: 600, height: 400) && off.maxX == vf.maxX && off.maxY == vf.maxY, off)

let tiny = PanelFrame.placement(saved: NSRect(x: 100, y: 100, width: 50, height: 20), visible: vf, minSize: minSize)
check("a frame under the minimum size grows to it", tiny.size == minSize && inside(tiny, vf), tiny)

let away = PanelFrame.placement(saved: NSRect(x: 1600, y: 300, width: 800, height: 600), visible: second, minSize: minSize)
check("a screen not at the origin: kept on that screen", inside(away, second) && away.origin == NSPoint(x: 1600, y: 300), away)

let frac = PanelFrame.placement(saved: NSRect(x: 10.4, y: 30.7, width: 700.6, height: 500.2), visible: vf, minSize: minSize)
check("whole points", frac == frac.integral && inside(frac, vf), frac)

/// Defaults held in memory: a suite on disk would leave a plist in ~/Library/Preferences after every run.
final class MemoryDefaults: UserDefaults {
    var store: [String: Any] = [:]
    override func object(forKey k: String) -> Any? { store[k] }
    override func dictionary(forKey k: String) -> [String: Any]? { store[k] as? [String: Any] }
    override func set(_ v: Any?, forKey k: String) { store[k] = v }
}
let d = MemoryDefaults(suiteName: nil)!
check("nothing saved for a display at first", PanelFrame.load("A", from: d) == nil)
PanelFrame.save(moved, "A", to: d)
PanelFrame.save(off, "B", to: d)
check("each display keeps its own frame", PanelFrame.load("A", from: d) == moved && PanelFrame.load("B", from: d) == off)
PanelFrame.save(tiny, "A", to: d)
check("a later save replaces that display's frame only", PanelFrame.load("A", from: d) == tiny && PanelFrame.load("B", from: d) == off)
d.set(["C": "garbage", "D": "{{0, 0}, {0, 0}}"], forKey: PanelFrame.defaultsKey)
check("an unreadable or empty saved frame is ignored", PanelFrame.load("C", from: d) == nil && PanelFrame.load("D", from: d) == nil)
d.set("not a dictionary", forKey: PanelFrame.defaultsKey)
check("a wrong type under the key is ignored, and a save replaces it", PanelFrame.load("A", from: d) == nil && { PanelFrame.save(moved, "A", to: d); return PanelFrame.load("A", from: d) == moved }())

if let s = NSScreen.main {
    let k = PanelFrame.key(for: s)
    check("a display is named by its UUID, the same each time", k != nil && k == PanelFrame.key(for: s) && k.map { UUID(uuidString: $0) != nil } == true, k ?? "nil")
} else {
    print("SKIP no screen: display naming not checked")
}

let pb = NSPasteboard(name: NSPasteboard.Name("md.spacebar.test.panel.\(getpid())"))
let file = URL(fileURLWithPath: "/tmp/notes with space.md")
check("⌘C: the file and its text go on the pasteboard", FinderCopy.write(file: file, text: "# Notes\n", to: pb))
check("⌘C: one item, so a paste takes one thing", pb.pasteboardItems?.count == 1, pb.pasteboardItems?.count ?? -1)
let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
check("⌘C: Finder reads the file", urls == [file], urls ?? [])
check("⌘C: an editor reads the text, not the path", pb.string(forType: .string) == "# Notes\n", pb.string(forType: .string) ?? "nil")
check("⌘C: a URL that is not a file is refused, leaving the pasteboard alone",
      !FinderCopy.write(file: URL(string: "https://example.com/a.md")!, text: "x", to: pb) && pb.string(forType: .string) == "# Notes\n")

pb.releaseGlobally()
print(failures == 0 ? "panel: all passed" : "panel: \(failures) failed")
exit(failures == 0 ? 0 : 1)
