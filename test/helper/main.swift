// Checks the Space helper's routing (Helper/Decision.swift): Decision.space over the contexts the spike recorded live in
// Finder and other apps (contexts.json, from spike_contexts.py), and over made-up ones; then KeyRoute with the panel closed,
// open, and open while another process (the writer's key panel) has the keyboard. Build and run with test/helper/run.sh.
// Opens no window and posts no event.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " " + detail())")
    if !ok { failures += 1 }
}
func describe(_ d: SpaceDecision) -> String { if case .show = d { return "show" }; if case .pass(let r) = d { return "pass:" + r }; return "?" }

// MARK: recorded contexts

struct Recorded: Decodable {
    let label: String, id: Int, front: String, target: String, role: String?, subrole: String?, ql: Bool, errs: [String], latencyMs: Double
    let selection: [String], expect: String
}
let recorded = try! JSONDecoder().decode([Recorded].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
for r in recorded {
    let c = SpaceContext(frontIsFinder: r.front == "finder", role: r.role, subrole: r.subrole, quickLookOpen: r.ql, selection: r.selection,
                         axErrors: r.errs, elapsedMs: r.latencyMs)
    let d = Decision.space(c)
    check("recorded \(r.label) (space \(r.id)): \(r.expect)", describe(d) == r.expect, describe(d))
    if case .show(let p) = d { check("recorded \(r.label) (space \(r.id)): shows the whole selection", p == r.selection) }
    var k = KeyRoute()
    let routed = k.route(KeyEvent(code: KeyCode.space, targetPid: r.target == "finder" ? 583 : 1526), panel: PanelContext(open: false, finderPid: 583, viewerPid: 900))
    check("recorded \(r.label) (space \(r.id)): its target pid \(r.target == "finder" ? "asks for" : "skips") the AX read", routed == (r.target == "finder" ? .space : .pass))
}
let labels = Set(recorded.map { $0.label.hasPrefix("other app") ? "other app" : $0.label })
check("recorded: every context the spike covered", labels.isSuperset(of: ["list", "icon", "column", "gallery", "desktop", "rename", "search", "qlopen", "other app"]),
      labels.sorted().joined(separator: ","))
check("recorded: every recorded decision was within the budget", recorded.allSatisfy { $0.latencyMs <= Decision.budgetMs })

// MARK: made-up contexts

let sel = ["/Users/u/a.md", "/Users/u/b.csv"]
func space(_ c: SpaceContext) -> String { describe(Decision.space(c)) }
check("Finder, a selection: show", Decision.space(SpaceContext(frontIsFinder: true, role: "AXOutline", selection: sel)) == .show(sel))
check("not Finder: pass", space(SpaceContext(frontIsFinder: false, role: "AXOutline", selection: sel)) == "pass:not-finder")
for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] {
    check("focus in \(role): pass", space(SpaceContext(frontIsFinder: true, role: role, selection: sel)) == "pass:text-focus")
}
check("a search field by subrole: pass", space(SpaceContext(frontIsFinder: true, role: "AXTextField", subrole: "AXSearchField", selection: sel)) == "pass:text-focus")
check("Apple's Quick Look open: pass", space(SpaceContext(frontIsFinder: true, role: "AXWebArea", quickLookOpen: true, selection: sel)) == "pass:ql-open")
check("nothing selected: pass", space(SpaceContext(frontIsFinder: true, role: "AXOutline")) == "pass:no-selection")
check("any AX error: pass", space(SpaceContext(frontIsFinder: true, role: "AXOutline", selection: sel, axErrors: ["AXFocusedUIElement:-25204"])) == "pass:ax-error")
check("an AX error beats a selection read", space(SpaceContext(frontIsFinder: true, selection: sel, axErrors: ["AXSelectedRows:-25212"])) == "pass:ax-error")
check("over the 60 ms budget: pass", space(SpaceContext(frontIsFinder: true, role: "AXOutline", selection: sel, elapsedMs: 60.5)) == "pass:budget")
check("at the budget: show", space(SpaceContext(frontIsFinder: true, role: "AXOutline", selection: sel, elapsedMs: 60)) == "show")
check("a name without its folder is not shown", space(SpaceContext(frontIsFinder: true, role: "AXList", selection: ["name:a.md"])) == "pass:no-selection")
check("only absolute paths are shown", Decision.space(SpaceContext(frontIsFinder: true, role: "AXList", selection: ["name:x", "/a"])) == .show(["/a"]))
check("the AX timeout is 50 ms", Decision.axTimeout == 0.05)

// MARK: KeyRoute

let finder: Int32 = 583, viewer: Int32 = 900, writer: Int32 = 901
let closed = PanelContext(open: false, finderPid: finder, viewerPid: viewer)
let open = PanelContext(open: true, finderPid: finder, viewerPid: viewer)
func key(_ code: Int64, _ chars: String = "", down: Bool = true, rep: Bool = false, mods: HelperMods = [], tagged: Bool = false, to pid: Int32 = finder) -> KeyEvent {
    KeyEvent(code: code, chars: chars, down: down, isRepeat: rep, mods: mods, tagged: tagged, targetPid: pid)
}
func routeOnce(_ e: KeyEvent, _ p: PanelContext) -> Route { var r = KeyRoute(); return r.route(e, panel: p) }

// Closed.
check("closed: a plain Space asks for the AX read", routeOnce(key(KeyCode.space), closed) == .space)
check("closed: a repeated Space passes", routeOnce(key(KeyCode.space, rep: true), closed) == .pass)
for (m, n) in [(HelperMods.command, "⌘"), (.shift, "⇧"), (.option, "⌥"), (.control, "⌃")] {
    check("closed: \(n)Space passes", routeOnce(key(KeyCode.space, mods: m), closed) == .pass)
}
check("closed: the helper's own re-posted Space passes", routeOnce(key(KeyCode.space, tagged: true), closed) == .pass)
check("closed: Esc, arrows and Return pass", [KeyCode.escape, KeyCode.down, KeyCode.up, KeyCode.returnKey].allSatisfy { routeOnce(key($0), closed) == .pass })
check("closed: a key-up nobody took passes", routeOnce(key(KeyCode.space, down: false), closed) == .pass)
check("closed: Space to another process (a launcher's panel over Finder) passes", routeOnce(key(KeyCode.space, to: 1526), closed) == .pass)
check("closed: Space with no target pid passes", routeOnce(key(KeyCode.space, to: 0), PanelContext(open: false, finderPid: 0, viewerPid: 0)) == .pass)

// A Space that opened the panel: its repeats and its key-up never reach Finder.
var r = KeyRoute()
check("show: Space asks", r.route(key(KeyCode.space), panel: closed) == .space)
r.hold(KeyCode.space)
check("show: the held Space's repeats are swallowed while the show is on its way", r.route(key(KeyCode.space, rep: true), panel: open) == .swallow)
check("show: its key-up is swallowed", r.route(key(KeyCode.space, down: false), panel: open) == .swallow)
check("show: the next key-up passes", r.route(key(KeyCode.space, down: false), panel: open) == .pass)

// Open, keys to Finder or the viewer.
for (code, n) in [(KeyCode.space, "Space"), (KeyCode.escape, "Esc")] {
    for pid in [finder, viewer] {
        var k = KeyRoute()
        check("open: \(n) to \(pid == finder ? "Finder" : "the viewer") closes in one press", k.route(key(code, to: pid), panel: open) == .close)
        check("open: \(n)'s repeat is swallowed", k.route(key(code, rep: true, to: pid), panel: PanelContext(open: false, finderPid: finder, viewerPid: viewer)) == .swallow)
        check("open: \(n)'s key-up is swallowed", k.route(key(code, down: false, to: pid), panel: closed) == .swallow)
    }
}
check("open: ⌘W closes", routeOnce(key(13, "w", mods: .command), open) == .close)
check("open: ⌘. closes", routeOnce(key(47, ".", mods: .command), open) == .close)
check("open: ⌘W by character, on a layout where W is elsewhere", routeOnce(key(6, "w", mods: .command), open) == .close)
check("open: ⌘Z (W's key on AZERTY) passes", routeOnce(key(13, "z", mods: .command), open) == .pass)
check("open: ⌥Space passes", routeOnce(key(KeyCode.space, mods: .option), open) == .pass)
check("open: ⇧Esc passes", routeOnce(key(KeyCode.escape, mods: .shift), open) == .pass)
let routed: [(Int64, String)] = [(KeyCode.up, "up"), (KeyCode.down, "down"), (KeyCode.left, "left"), (KeyCode.right, "right"), (KeyCode.home, "home"),
                                 (KeyCode.end, "end"), (KeyCode.pageUp, "pageup"), (KeyCode.pageDown, "pagedown"), (KeyCode.returnKey, "return"), (KeyCode.enter, "return")]
for (code, name) in routed {
    var k = KeyRoute()
    check("open: \(name) is routed", k.route(key(code), panel: open) == .forward(name))
    check("open: \(name) repeats are routed", k.route(key(code, rep: true), panel: open) == .forward(name))
    check("open: \(name)'s key-up is swallowed", k.route(key(code, down: false), panel: open) == .swallow)
    check("open: \(name) to the viewer is routed", routeOnce(key(code, to: viewer), open) == .forward(name))
}
check("open: every routed name is one the viewer accepts", Set(routed.map(\.1)).isSubset(of: HelperKeys.list))
let commands: [(KeyEvent, String)] = [(key(31, "o", mods: .command), "open"), (key(3, "f", mods: .command), "find"),
                                      (key(24, "=", mods: .command), "zoomIn"), (key(24, "+", mods: [.command, .shift]), "zoomIn"),
                                      (key(KeyCode.keypadPlus, "+", mods: .command), "zoomIn"), (key(27, "-", mods: .command), "zoomOut"),
                                      (key(29, "0", mods: .command), "zoomReset"), (key(KeyCode.keypad0, "0", mods: .command), "zoomReset")]
for (e, name) in commands { check("open: \(e.mods.contains(.shift) ? "⌘⇧" : "⌘")\(e.chars) is \(name)", routeOnce(e, open) == .forward(name)) }
check("open: every command is one the viewer accepts", Set(commands.map(\.1)) == HelperKeys.commands)
check("open: ⌘C passes (copy in Finder)", routeOnce(key(8, "c", mods: .command), open) == .pass)
check("open: ⌘⌥O passes", routeOnce(key(31, "o", mods: [.command, .option]), open) == .pass)
check("open: ⌘⇧O passes", routeOnce(key(31, "o", mods: [.command, .shift]), open) == .pass)
check("open: ⇧↓ passes", routeOnce(key(KeyCode.down, mods: .shift), open) == .pass)
check("open: ⌥↓ passes", routeOnce(key(KeyCode.down, mods: .option), open) == .pass)
check("open: ⌘↓ passes", routeOnce(key(KeyCode.down, mods: .command), open) == .pass)
check("open: a letter passes", routeOnce(key(0, "a"), open) == .pass)
check("open: Tab passes", routeOnce(key(48), open) == .pass)
check("open: the helper's own event passes", routeOnce(key(KeyCode.space, tagged: true), open) == .pass)

// Open, but another process has the keyboard: the writer's key panel during a filter or an edit.
for (code, n) in [(KeyCode.space, "Space"), (KeyCode.escape, "Esc"), (KeyCode.down, "↓"), (KeyCode.returnKey, "Return")] {
    check("open, writer has the keys: \(n) passes", routeOnce(key(code, to: writer), open) == .pass)
}
check("open, writer has the keys: ⌘W passes", routeOnce(key(13, "w", mods: .command, to: writer), open) == .pass)
check("open, no viewer pid: a target of 0 is not the viewer", routeOnce(key(KeyCode.down, to: 0), PanelContext(open: true, finderPid: finder, viewerPid: 0)) == .pass)

// Finder's focus in a text field while the panel is open: a rename or the search field keeps its keys.
let typing = PanelContext(open: true, finderPid: finder, viewerPid: viewer, textFocus: true)
for (code, n) in [(KeyCode.space, "Space"), (KeyCode.escape, "Esc"), (KeyCode.down, "↓"), (KeyCode.returnKey, "Return")] {
    check("open, Finder text field focused: \(n) passes", routeOnce(key(code), typing) == .pass)
}
check("open, Finder text field focused: keys to the viewer are still routed", routeOnce(key(KeyCode.down, to: viewer), typing) == .forward("down"))

// sidebarKeys off: the arrows move Finder's selection, and the helper follows it.
let noSidebar = PanelContext(open: true, finderPid: finder, viewerPid: viewer, sidebarKeys: false)
for code in [KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right] {
    var k = KeyRoute()
    check("sidebarKeys off: arrow \(code) passes", k.route(key(code), panel: noSidebar) == .pass)
    check("sidebarKeys off: its repeat passes", k.route(key(code, rep: true), panel: noSidebar) == .pass)
    check("sidebarKeys off: its key-up passes", k.route(key(code, down: false), panel: noSidebar) == .pass)
}
check("sidebarKeys off: Home is still routed", routeOnce(key(KeyCode.home), noSidebar) == .forward("home"))
check("sidebarKeys off: Space still closes", routeOnce(key(KeyCode.space), noSidebar) == .close)

// A key held from before the panel opened is not taken half-way.
var h = KeyRoute()
check("held: an arrow pressed while closed passes", h.route(key(KeyCode.down), panel: closed) == .pass)
check("held: its repeat once the panel is open is routed", h.route(key(KeyCode.down, rep: true), panel: open) == .forward("down"))
check("held: its key-up is swallowed", h.route(key(KeyCode.down, down: false), panel: open) == .swallow)
var g = KeyRoute()
_ = g.route(key(KeyCode.down), panel: open)
check("held: a routed arrow's repeat after the panel closed is swallowed", g.route(key(KeyCode.down, rep: true), panel: closed) == .swallow)
var m = KeyRoute()
_ = m.route(key(KeyCode.escape), panel: open)
check("held: a fresh press after a missed key-up is routed, not swallowed", m.route(key(KeyCode.escape), panel: closed) == .pass)
var n = KeyRoute()
_ = n.route(key(KeyCode.down), panel: open)
n.release()
check("held: release forgets held keys (the tap was off)", n.held.isEmpty && n.route(key(KeyCode.down, down: false), panel: closed) == .pass)
check("held: nothing stays held after the key-ups", { var k = KeyRoute(); _ = k.route(key(KeyCode.escape), panel: open); _ = k.route(key(KeyCode.escape, down: false), panel: closed); return k.held.isEmpty }())

print(failures == 0 ? "\nall helper checks passed (\(recorded.count) recorded contexts)" : "\n\(failures) helper checks failed")
exit(failures == 0 ? 0 : 1)
