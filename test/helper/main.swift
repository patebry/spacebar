// Checks the Space helper's routing (Helper/Decision.swift): Decision.space over the contexts the spike recorded live in
// Finder and other apps (contexts.json, from spike_contexts.py), and over made-up ones; then KeyRoute with the viewer's
// windows closed and open, and the names KeyRoute gives the keys typed in them. Build and run with test/helper/run.sh.
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
check("closed: Space to the viewer passes", routeOnce(key(KeyCode.space, to: viewer), closed) == .pass)
check("closed: Space with no target pid passes", routeOnce(key(KeyCode.space, to: 0), PanelContext(open: false, finderPid: 0, viewerPid: 0)) == .pass)
check("closed: ⌘C and ⌘F pass (Finder's copy and search)", routeOnce(key(8, "c", mods: .command), closed) == .pass && routeOnce(key(3, "f", mods: .command), closed) == .pass)

// A Space that opened a window: its repeats and its key-up never reach Finder.
var r = KeyRoute()
check("show: Space asks", r.route(key(KeyCode.space), panel: closed) == .space)
r.hold(KeyCode.space)
check("show: the held Space's repeats are swallowed while the show is on its way", r.route(key(KeyCode.space, rep: true), panel: open) == .swallow)
check("show: its key-up is swallowed", r.route(key(KeyCode.space, down: false), panel: open) == .swallow)
check("show: the next key-up passes", r.route(key(KeyCode.space, down: false), panel: open) == .pass)

// A window open. The viewer's windows are ordinary windows: only a plain Space on its way to Finder is the helper's; every
// other key is Finder's (its arrows move the selection the newest window follows), or the window's it was typed into.
check("open: a plain Space to Finder asks for the AX read", routeOnce(key(KeyCode.space), open) == .space)
check("open: a repeated Space passes", routeOnce(key(KeyCode.space, rep: true), open) == .pass)
check("open: ⌥Space passes", routeOnce(key(KeyCode.space, mods: .option), open) == .pass)
check("open: the helper's own event passes", routeOnce(key(KeyCode.space, tagged: true), open) == .pass)
let plain: [(Int64, String)] = [(KeyCode.escape, "Esc"), (KeyCode.up, "↑"), (KeyCode.down, "↓"), (KeyCode.left, "←"), (KeyCode.right, "→"),
                                (KeyCode.home, "Home"), (KeyCode.end, "End"), (KeyCode.pageUp, "Page Up"), (KeyCode.pageDown, "Page Down"),
                                (KeyCode.returnKey, "Return"), (KeyCode.enter, "keypad Enter"), (KeyCode.delete, "Delete"), (0, "a letter"), (48, "Tab")]
for (code, n) in plain {
    var k = KeyRoute()
    check("open: \(n) to Finder passes, and nothing is held", k.route(key(code), panel: open) == .pass && k.held.isEmpty
          && k.route(key(code, rep: true), panel: open) == .pass && k.route(key(code, down: false), panel: open) == .pass)
}
let shortcuts = [key(13, "w", mods: .command), key(47, ".", mods: .command), key(31, "o", mods: .command), key(3, "f", mods: .command),
                 key(3, "f", mods: [.command, .option]), key(8, "c", mods: .command), key(24, "=", mods: .command),
                 key(24, "+", mods: [.command, .shift]), key(27, "-", mods: .command), key(29, "0", mods: .command)]
check("open: ⌘W ⌘. ⌘O ⌘F ⌥⌘F ⌘C ⌘= ⌘⇧+ ⌘- ⌘0 to Finder pass", shortcuts.allSatisfy { routeOnce($0, open) == .pass })
check("open: ⇧Esc and ⇧↓ pass", routeOnce(key(KeyCode.escape, mods: .shift), open) == .pass && routeOnce(key(KeyCode.down, mods: .shift), open) == .pass)

// A key to the viewer's pid: the window it was typed into has it, Space too.
for (code, n) in [(KeyCode.space, "Space")] + plain {
    check("open, a key to the viewer: \(n) passes", routeOnce(key(code, to: viewer), open) == .pass)
}
check("open, a key to the viewer: the shortcuts pass", shortcuts.allSatisfy { var e = $0; e.targetPid = viewer; return routeOnce(e, open) == .pass })

// Open, but a key annotated with another process's pid.
for (code, n) in [(KeyCode.space, "Space"), (KeyCode.escape, "Esc"), (KeyCode.down, "↓"), (KeyCode.returnKey, "Return")] {
    check("open, a key to another pid: \(n) passes", routeOnce(key(code, to: writer), open) == .pass)
}
check("open, a key to another pid: ⌘W passes", routeOnce(key(13, "w", mods: .command, to: writer), open) == .pass)
check("open, no viewer pid: Space to a target of 0 passes", routeOnce(key(KeyCode.space, to: 0), PanelContext(open: true, finderPid: finder, viewerPid: 0)) == .pass)

// A text session in the viewer no longer decides anything: its window has its keys.
let editing = PanelContext(open: true, finderPid: finder, viewerPid: viewer, textSession: true)
for (code, n) in [(KeyCode.space, "Space")] + plain {
    check("text session, a key to the viewer: \(n) passes", routeOnce(key(code, to: viewer), editing) == .pass)
}
check("text session: Esc, ↓ and ⌘W to Finder pass", routeOnce(key(KeyCode.escape), editing) == .pass && routeOnce(key(KeyCode.down), editing) == .pass
      && routeOnce(key(13, "w", mods: .command), editing) == .pass)
do {
    var t = TextSession()
    check("text session: starts off", !t.active)
    check("text session: taken while the panel is open", t.set(true, panelOpen: true) && t.active)
    check("text session: ended by the viewer", t.set(false, panelOpen: true) && !t.active)
    check("text session: refused with no panel open or on its way", !t.set(true, panelOpen: false) && !t.active)
    _ = t.set(true, panelOpen: true)
    t.clear()
    check("text session: cleared when the panel closes (or the viewer goes, or it suspends)", !t.active)
}
check("text session: only the viewer may claim one", Link.permits(.viewer, .textSession) && !Link.permits(.app, .textSession))
check("popover: Esc to Finder passes", routeOnce(key(KeyCode.escape), PanelContext(open: true, finderPid: finder, viewerPid: viewer, popover: true)) == .pass)
check("popover: the viewer accepts the name", HelperKeys.all.contains(HelperKeys.escape) && !HelperKeys.list.contains(HelperKeys.escape))
check("popover: only the viewer may say one is open", Link.permits(.viewer, .popover) && !Link.permits(.app, .popover))

// A whole edit in the viewer's window as the tap sees it: Space opens it, then every key of the typing, down, repeat and up,
// is the window's, Esc included; Space to Finder afterwards asks again.
do {
    var r = KeyRoute()
    var log: [String] = []
    func press(_ name: String, _ e: KeyEvent, repeats: Int = 0) -> Route {
        let down = r.route(e, panel: open)
        var reps: [Route] = []
        for _ in 0..<repeats { var x = e; x.isRepeat = true; reps.append(r.route(x, panel: open)) }
        var up = e; up.down = false
        let u = r.route(up, panel: open)
        if down != .pass || reps.contains(where: { $0 != .pass }) || u != .pass { log.append("\(name): \(down) \(reps) up \(u)") }
        return down
    }
    func v(_ code: Int64, _ chars: String = "", mods: HelperMods = []) -> KeyEvent { key(code, chars, mods: mods, to: viewer) }
    check("edit: Space with nothing open asks for the AX read", r.route(key(KeyCode.space), panel: closed) == .space)
    r.hold(KeyCode.space)
    check("edit: its key-up is swallowed while the show is on its way", r.route(key(KeyCode.space, down: false), panel: open) == .swallow)
    let typing: [(String, KeyEvent, Int)] = [
        ("H", v(4, mods: .shift), 0), ("i", v(34), 0), ("Space", v(KeyCode.space), 0), ("Return", v(KeyCode.returnKey), 0),
        ("Return held down", v(KeyCode.returnKey), 3), ("Shift-Return", v(KeyCode.returnKey, mods: .shift), 0), ("keypad Enter", v(KeyCode.enter), 0),
        ("Tab", v(48), 0), ("←", v(KeyCode.left), 0), ("→", v(KeyCode.right), 0), ("↑", v(KeyCode.up), 0), ("↓ held", v(KeyCode.down), 2),
        ("⌥←", v(KeyCode.left, mods: .option), 0), ("⌘←", v(KeyCode.left, mods: .command), 0), ("Home", v(KeyCode.home), 0), ("End", v(KeyCode.end), 0),
        ("Page Down", v(KeyCode.pageDown), 0), ("⌘A", v(0, "a", mods: .command), 0), ("⌘C", v(8, "c", mods: .command), 0),
        ("⌘V", v(9, "v", mods: .command), 0), ("⌘Z", v(6, "z", mods: .command), 0), ("⌥⌫", v(51, mods: .option), 0), ("Delete", v(117), 0),
        ("⌘F", v(3, "f", mods: .command), 0), ("⌘W", v(13, "w", mods: .command), 0), ("⌘=", v(24, "=", mods: .command), 0), ("Space held", v(KeyCode.space), 2),
    ]
    for (name, e, n) in typing { _ = press(name, e, repeats: n) }
    check("edit: every key of the typing passes, down, repeat and up", log.isEmpty, log.joined(separator: "; "))
    check("edit: Esc is the window's", press("Esc", v(KeyCode.escape)) == .pass && r.held.isEmpty)
    check("edit: afterwards Space to Finder asks again", r.route(key(KeyCode.space), panel: open) == .space)
}

// Finder's focus in a text field while a window is open: a rename or the search field keeps its keys, Space too.
let typing = PanelContext(open: true, finderPid: finder, viewerPid: viewer, textFocus: true)
for (code, n) in [(KeyCode.space, "Space"), (KeyCode.escape, "Esc"), (KeyCode.down, "↓"), (KeyCode.returnKey, "Return")] {
    check("open, Finder text field focused: \(n) passes", routeOnce(key(code), typing) == .pass)
}
check("open, Finder text field focused: ⌘C, ⌘F and ⌥⌘F stay the field's", [key(8, "c", mods: .command), key(3, "f", mods: .command),
      key(3, "f", mods: [.command, .option])].allSatisfy { routeOnce($0, typing) == .pass })
check("closed, a stale text-focus flag: Space still asks (Decision.space reads the focus)",
      routeOnce(key(KeyCode.space), PanelContext(open: false, finderPid: finder, viewerPid: viewer, textFocus: true)) == .space)

// A held Space is not taken half-way, and a missed key-up does not trap the next press.
var g = KeyRoute()
g.hold(KeyCode.space)
check("held: a held Space's repeat after the window closed is swallowed", g.route(key(KeyCode.space, rep: true), panel: closed) == .swallow)
var m = KeyRoute()
m.hold(KeyCode.space)
check("held: a fresh press after a missed key-up asks again, not swallowed", m.route(key(KeyCode.space), panel: closed) == .space && m.held.isEmpty)
var n = KeyRoute()
n.hold(KeyCode.space)
n.release()
check("held: release forgets held keys (the tap was off)", n.held.isEmpty && n.route(key(KeyCode.space, down: false), panel: closed) == .pass)
check("held: nothing stays held after the key-up", { var k = KeyRoute(); k.hold(KeyCode.space); _ = k.route(key(KeyCode.space, down: false), panel: closed); return k.held.isEmpty }())

// The names the viewer gives keys typed in its window (KeyRoute.forwarded), and the keys that close it (KeyRoute.closes).
let routed: [(Int64, String)] = [(KeyCode.up, "up"), (KeyCode.down, "down"), (KeyCode.left, "left"), (KeyCode.right, "right"), (KeyCode.home, "home"),
                                 (KeyCode.end, "end"), (KeyCode.pageUp, "pageup"), (KeyCode.pageDown, "pagedown"), (KeyCode.returnKey, "return"), (KeyCode.enter, "return"),
                                 (KeyCode.delete, "back")]
func named(_ e: KeyEvent, sidebar: Bool = true) -> String? { KeyRoute.forwarded(e, sidebarKeys: sidebar) }
for (code, name) in routed { check("forwarded: \(name) is named", named(key(code)) == name) }
check("forwarded: every list name is one the viewer accepts", Set(routed.map(\.1)).isSubset(of: HelperKeys.list))
let commands: [(KeyEvent, String)] = [(key(31, "o", mods: .command), "open"), (key(3, "f", mods: .command), "find"),
                                      (key(3, "f", mods: [.command, .option]), "filter"), (key(8, "c", mods: .command), "copy"),
                                      (key(24, "=", mods: .command), "zoomIn"), (key(24, "+", mods: [.command, .shift]), "zoomIn"),
                                      (key(KeyCode.keypadPlus, "+", mods: .command), "zoomIn"), (key(27, "-", mods: .command), "zoomOut"),
                                      (key(29, "0", mods: .command), "zoomReset"), (key(KeyCode.keypad0, "0", mods: .command), "zoomReset")]
for (e, name) in commands { check("forwarded: \(e.mods.contains(.shift) ? "⌘⇧" : "⌘")\(e.chars) is \(name)", named(e) == name) }
check("forwarded: every command is one the viewer accepts", Set(commands.map(\.1)) == HelperKeys.commands)
check("forwarded: ⌘⇧C, ⌘⌥C and ⌃⌘C are nothing", [HelperMods([.command, .shift]), [.command, .option], [.command, .control]].allSatisfy { named(key(8, "c", mods: $0)) == nil })
check("forwarded: ⌘⇧F and ⌃⌥⌘F are nothing", named(key(3, "f", mods: [.command, .shift])) == nil && named(key(3, "f", mods: [.command, .option, .control])) == nil)
check("forwarded: ⌘⌥O and ⌘⇧O are nothing", named(key(31, "o", mods: [.command, .option])) == nil && named(key(31, "o", mods: [.command, .shift])) == nil)
check("forwarded: ⇧↓, ⌥↓ and ⌘↓ are nothing", [HelperMods.shift, .option, .command].allSatisfy { named(key(KeyCode.down, mods: $0)) == nil })
check("forwarded: a letter, Tab and Space are nothing", named(key(0, "a")) == nil && named(key(48)) == nil && named(key(KeyCode.space)) == nil)
check("forwarded: sidebarKeys off, the arrows and Delete are nothing, Home still is",
      [KeyCode.up, KeyCode.down, KeyCode.left, KeyCode.right, KeyCode.delete].allSatisfy { named(key($0), sidebar: false) == nil }
      && named(key(KeyCode.home), sidebar: false) == "home")
check("closes: Space, Esc, ⌘W and ⌘.", [key(KeyCode.space), key(KeyCode.escape), key(13, "w", mods: .command), key(47, ".", mods: .command)].allSatisfy(KeyRoute.closes))
check("closes: ⌘W by character, on a layout where W is elsewhere", KeyRoute.closes(key(6, "w", mods: .command)))
check("closes: not ⌘Z (W's key on AZERTY), ⌥Space, ⇧Esc, a repeated Space or ⌘W",
      ![key(13, "z", mods: .command), key(KeyCode.space, mods: .option), key(KeyCode.escape, mods: .shift), key(KeyCode.space, rep: true),
        key(13, "w", rep: true, mods: .command)].contains(where: KeyRoute.closes))

// MARK: panel gate, failed shows, focus reads

check("gate: the pending show with its window up is accepted", Decision.panelOpened(pendingID: 4, requestID: 4, onScreen: true, retried: false) == .accept)
check("gate: a show not pending is ignored", Decision.panelOpened(pendingID: 5, requestID: 4, onScreen: true, retried: false) == .notPending)
check("gate: nothing pending is ignored", Decision.panelOpened(pendingID: nil, requestID: 4, onScreen: true, retried: false) == .notPending)
check("gate: a window not up yet gets one retry", Decision.panelOpened(pendingID: 4, requestID: 4, onScreen: false, retried: false) == .retry)
check("gate: a window still not up after the retry fails the show", Decision.panelOpened(pendingID: 4, requestID: 4, onScreen: false, retried: true) == .fail)
check("gate: the retry accepts a window up by then", Decision.panelOpened(pendingID: 4, requestID: 4, onScreen: true, retried: true) == .accept)
check("close: the viewer closing the pending show ends it", Decision.closeEndsPending(pendingID: 4, requestID: 4))
check("close: another request's close leaves it", !Decision.closeEndsPending(pendingID: 4, requestID: 3))
check("close: a close with no request (0) leaves it", !Decision.closeEndsPending(pendingID: 0, requestID: 0) && !Decision.closeEndsPending(pendingID: nil, requestID: 0))

check("failed: a fresh Space closes the viewer and goes back to Finder", Decision.failed(space: true, age: 0.2) == .closeAndRepost)
check("failed: a Space just under 1 s is still fresh", Decision.failed(space: true, age: 0.99) == .closeAndRepost)
check("failed: a Space 1 s old is stale: closed, not handed back", Decision.failed(space: true, age: 1) == .close)
check("failed: a stale Space after the 5 s timeout is not handed back", Decision.failed(space: true, age: 5.2) == .close)
check("failed: a follow of Finder's selection leaves the panel", Decision.failed(space: false, age: 0.1) == .leave && Decision.failed(space: false, age: 9) == .leave)

let screenA = CGRect(x: 0, y: 0, width: 1512, height: 982), screenB = CGRect(x: 1512, y: -200, width: 2560, height: 1440)
let win = WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: 300, y: 200, width: 900, height: 640))
func visible(_ w: WindowInfo, _ displays: [CGRect] = [screenA, screenB], pid: Int32 = viewer) -> Bool { Decision.panelVisible(w, viewerPid: pid, displays: displays) }
check("window: the viewer's, on screen, on a display", visible(win))
check("window: another process's is not", !visible(WindowInfo(owner: 1526, onScreen: true, alpha: 1, bounds: win.bounds)))
check("window: no viewer pid, nothing is", !visible(WindowInfo(owner: 0, onScreen: true, alpha: 1, bounds: win.bounds), pid: 0))
check("window: off screen is not", !visible(WindowInfo(owner: viewer, onScreen: false, alpha: 1, bounds: win.bounds)))
check("window: transparent is not", !visible(WindowInfo(owner: viewer, onScreen: true, alpha: 0, bounds: win.bounds)))
check("window: 199 wide is too small", !visible(WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: 10, y: 10, width: 199, height: 600))))
check("window: 149 high is too small", !visible(WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: 10, y: 10, width: 600, height: 149))))
check("window: exactly 200×150 is enough", visible(WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: 10, y: 10, width: 200, height: 150))))
check("window: parked off every display is not", !visible(WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: -5000, y: -5000, width: 900, height: 640))))
check("window: on the second display is", visible(WindowInfo(owner: viewer, onScreen: true, alpha: 1, bounds: CGRect(x: 2000, y: -100, width: 900, height: 640))))
check("window: no displays known, none is", !visible(win, []))

check("focus: an outline is not a text field", !Decision.textFocus(FocusRead(found: true, role: "AXOutline")))
for role in ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"] { check("focus: \(role) is", Decision.textFocus(FocusRead(found: true, role: role))) }
check("focus: a search field by subrole is", Decision.textFocus(FocusRead(found: true, role: "AXTextField", subrole: "AXSearchField")))
check("focus: nothing focused, read in time, is not", !Decision.textFocus(FocusRead(found: false)))
check("focus: any AX error counts as a text field", Decision.textFocus(FocusRead(found: false, errors: true)) && Decision.textFocus(FocusRead(found: true, role: "AXOutline", errors: true)))
check("focus: the budget spent before the element was read counts", Decision.textFocus(FocusRead(found: false, expired: true)))
check("focus: the budget spent before the role was read counts", Decision.textFocus(FocusRead(found: true, expired: true)))
check("focus: a role read before the budget ran out still answers", !Decision.textFocus(FocusRead(found: true, role: "AXOutline", expired: true)))

// MARK: another app in front, and Finder back

check("activation: another app leaves an open window as it is", Decision.activated(isFinder: false, open: true, pending: false, suspendedFor: nil) == .none
      && Decision.activated(isFinder: false, open: true, pending: false, suspendedFor: 3) == .none)
check("activation: another app closes a show still on its way", Decision.activated(isFinder: false, open: false, pending: true, suspendedFor: nil) == .close
      && Decision.activated(isFinder: false, open: true, pending: true, suspendedFor: nil) == .close)
check("activation: another app with nothing open does nothing", Decision.activated(isFinder: false, open: false, pending: false, suspendedFor: 3) == .none
      && Decision.activated(isFinder: false, open: false, pending: false, suspendedFor: nil) == .none)
check("activation: Finder back within the limit reads its selection", Decision.activated(isFinder: true, open: false, pending: false, suspendedFor: 3) == .check
      && Decision.activated(isFinder: true, open: false, pending: false, suspendedFor: Decision.suspendLimit - 1) == .check)
check("activation: a hidden panel waits minutes, not ten", Decision.suspendLimit >= 60 && Decision.suspendLimit <= 180)
check("activation: Finder back after the limit forgets it", Decision.activated(isFinder: true, open: false, pending: false, suspendedFor: Decision.suspendLimit) == .forget)
check("activation: Finder with nothing hidden, or a panel open or on its way, does nothing",
      Decision.activated(isFinder: true, open: false, pending: false, suspendedFor: nil) == .none
      && Decision.activated(isFinder: true, open: true, pending: false, suspendedFor: 3) == .none
      && Decision.activated(isFinder: true, open: false, pending: true, suspendedFor: 3) == .none)

// MARK: Finder back: its selection decides

let shownA = ["/Users/u/Desktop/a.pdf"], shownAB = ["/Users/u/Documents/a.md", "/Users/u/Documents/b.md"]
func resume(_ sel: [String], desktop: Bool = false, clicked: Bool = false, errs: [String] = [], ms: Double = 8, age: TimeInterval = 5,
            shown: [String] = shownA) -> ActivationAction {
    Decision.resumes(Decision.ResumeRead(selection: sel, desktop: desktop, clicked: clicked, axErrors: errs, elapsedMs: ms), shown: shown, suspendedFor: age)
}
check("resume: the same selection brings the panel back", resume(shownA) == .restore)
check("resume: the same files in another order bring it back", resume(shownAB.reversed(), shown: shownAB) == .restore)
check("resume: the same Desktop file brought back by ⌘Tab", resume(shownA, desktop: true) == .restore)
check("resume: a different selection (\"Show in Finder\" from another app) drops it", resume(["/Users/u/Downloads/new.png"]) == .forget)
check("resume: a selection that grew or shrank drops it", resume(shownAB, shown: [shownAB[0]]) == .forget && resume([shownAB[0]], shown: shownAB) == .forget)
check("resume: nothing selected (a click on an empty area) drops it", resume([]) == .forget)
check("resume: a click on the Desktop never brings it back, even on the file it showed", resume(shownA, desktop: true, clicked: true) == .forget
      && resume([], desktop: true, clicked: true) == .forget && resume(["/Users/u/Desktop/folder"], desktop: true, clicked: true) == .forget)
check("resume: a click in a Finder window on the file it showed brings it back", resume(shownA, clicked: true) == .restore)
check("resume: a name without its folder is no match", resume(["a.pdf"], shown: ["a.pdf"]) == .forget)
check("resume: any AX error drops it", resume(shownA, errs: ["AXSelectedRows:-25204"]) == .forget)
check("resume: a read past the 60 ms budget drops it", resume(shownA, ms: Decision.budgetMs + 0.5) == .forget)
check("resume: past the limit drops it, even on the same selection", resume(shownA, age: Decision.suspendLimit) == .forget
      && resume(shownA, age: Decision.suspendLimit - 1) == .restore)
check("resume: nothing shown matches nothing", resume([], shown: []) == .forget && resume(shownA, shown: []) == .forget)
do {
    // Dropped for another selection, the next Space shows that selection, never the file that was hidden.
    let next = ["/Users/u/Downloads/new.png"]
    var r = KeyRoute()
    let closedAfter = PanelContext(open: false, finderPid: finder, viewerPid: viewer)
    check("resume: after a mismatch the panel is closed and Space asks Finder again",
          resume(next) == .forget && r.route(key(KeyCode.space), panel: closedAfter) == .space)
    check("resume: after a mismatch Space shows the new selection",
          Decision.space(SpaceContext(frontIsFinder: true, role: "AXOutline", selection: next)) == .show(next))
}

// MARK: what the settings window says

let up = HelperStatus(pid: 1, version: "0.3", enabled: true, trusted: true, tap: true, viewer: true, binary: "1-2.3")
var untrusted = up; untrusted.trusted = false; untrusted.tap = false
var noTap = up; noTap.tap = false
check("state: the setting off is Off, whatever else", HelperState.of(enabled: false, agent: .requiresApproval, helper: up, secureInput: true) == .off)
check("state: blocked in Login Items", HelperState.of(enabled: true, agent: .requiresApproval, helper: nil, secureInput: false) == .needsLoginItems)
check("state: not registered is not running", HelperState.of(enabled: true, agent: .notRegistered, helper: nil, secureInput: false) == .notRunning
      && HelperState.of(enabled: true, agent: .notFound, helper: nil, secureInput: false) == .notRunning)
check("state: registered, not answering yet, is starting", HelperState.of(enabled: true, agent: .enabled, helper: nil, secureInput: false) == .starting)
check("state: waiting for Accessibility", HelperState.of(enabled: true, agent: .enabled, helper: untrusted, secureInput: true) == .needsAccessibility)
check("state: trusted, tap not up yet, is starting", HelperState.of(enabled: true, agent: .enabled, helper: noTap, secureInput: false) == .starting)
check("state: secure input on", HelperState.of(enabled: true, agent: .enabled, helper: up, secureInput: true) == .secureInput)
check("state: on", HelperState.of(enabled: true, agent: .enabled, helper: up, secureInput: false) == .on)

check("launch: the setting on and the agent not registered (a reinstall that kept settings) registers it",
      HelperState.registersAtLaunch(enabled: true, agent: .notRegistered))
check("launch: never with the setting off, nor for an agent waiting in Login Items or already registered",
      !HelperState.registersAtLaunch(enabled: false, agent: .notRegistered) && !HelperState.registersAtLaunch(enabled: true, agent: .requiresApproval)
      && !HelperState.registersAtLaunch(enabled: true, agent: .enabled))
check("reregister: on, registered, three silent polls", HelperState.shouldReregister(enabled: true, agent: .enabled, answering: false, misses: 3))
check("reregister: not before three polls", !HelperState.shouldReregister(enabled: true, agent: .enabled, answering: false, misses: 2))
check("reregister: never while it answers", !HelperState.shouldReregister(enabled: true, agent: .enabled, answering: true, misses: 9))
check("reregister: never with the setting off", !HelperState.shouldReregister(enabled: false, agent: .enabled, answering: false, misses: 9))
check("reregister: never while Login Items blocks it or it is not registered (the toggle's job)",
      [HelperState.Agent.requiresApproval, .notRegistered, .notFound].allSatisfy { !HelperState.shouldReregister(enabled: true, agent: $0, answering: false, misses: 9) })

check("requirement: pins the injection entitlements out", HelperSigning.requirement(identifiers: ["a"], leaf: "AB").hasSuffix(
    #" and !entitlement["com.apple.security.cs.allow-dyld-environment-variables"] exists and !entitlement["com.apple.security.cs.disable-library-validation"] exists"#))

check("tap: made once Accessibility is granted", Decision.tapAction(exists: false, trusted: true) == .create)
check("tap: none while Accessibility is not granted", Decision.tapAction(exists: false, trusted: false) == .none)
check("tap: kept while granted", Decision.tapAction(exists: true, trusted: true) == .none)
check("tap: removed once Accessibility is revoked", Decision.tapAction(exists: true, trusted: false) == .remove)
check("tap: a disabled tap is enabled again only while Accessibility is granted",
      Decision.reenablesTap(trusted: true) && !Decision.reenablesTap(trusted: false))

// MARK: Gestures

let panelWin = 4242, panelRect = CGRect(x: 100, y: 100, width: 800, height: 600), outside = CGPoint(x: 5, y: 5)
func zoom(_ phase: Int64, under: Int = panelWin, at p: CGPoint = CGPoint(x: 300, y: 300), type: Int64 = 29, subtype: Int64 = 8, time: Double = 0) -> GestureEvent {
    GestureEvent(type: type, subtype: subtype, phase: phase, windowUnder: under, location: p, time: time)
}
extension GestureRoute {
    mutating func go(_ g: GestureEvent, open: Bool = true, window: Int = panelWin, bounds: CGRect = panelRect) -> GestureAction {
        route(g, open: open, panelWindow: window, bounds: bounds)
    }
}
func once(_ g: GestureEvent, open: Bool = true, window: Int = panelWin, bounds: CGRect = panelRect) -> GestureAction {
    var r = GestureRoute(); return r.go(g, open: open, window: window, bounds: bounds)
}
check("gesture tap: on while the panel is open", GestureRoute.tapOn(open: true, pinching: false))
check("gesture tap: on to the end of a pinch it took", GestureRoute.tapOn(open: false, pinching: true))
check("gesture tap: off with the panel closed and no pinch", !GestureRoute.tapOn(open: false, pinching: false))
do {
    var r = GestureRoute()
    _ = r.go(zoom(1))
    check("gesture tap: a pinch begun over the panel keeps it on", GestureRoute.tapOn(open: false, pinching: r.pinch != nil))
    r.reset()
    check("gesture tap: a close (reset) turns it off", !GestureRoute.tapOn(open: false, pinching: r.pinch != nil))
    _ = r.go(zoom(1)); _ = r.go(zoom(4))
    check("gesture tap: off once the pinch ends with the panel closed", !GestureRoute.tapOn(open: false, pinching: r.pinch != nil))
}
check("gesture: a pinch over the open panel is sent", once(zoom(1)) == .forward)
check("gesture: a smart zoom (subtype 22) over the panel is sent", once(zoom(0, subtype: 22)) == .forward)
check("gesture: magnify (30) and smart magnify (32) events over the panel are sent", once(zoom(1, type: 30)) == .forward && once(zoom(0, type: 32)) == .forward)
check("gesture: a pinch with the panel closed passes", once(zoom(1), open: false) == .pass)
check("gesture: a pinch over another window passes", once(zoom(1, under: 77)) == .pass)
check("gesture: no panel window known: passes", once(zoom(1), window: 0) == .pass)
check("gesture: no window under the pointer, inside the panel's bounds, at its beginning: sent", once(zoom(1, under: 0)) == .forward)
check("gesture: no window under the pointer, outside the panel's bounds: passes", once(zoom(1, under: 0, at: outside)) == .pass)
check("gesture: no window and no bounds known: passes", once(zoom(1, under: 0), bounds: .null) == .pass)
check("gesture: a change without its beginning, placed only by bounds: passes", once(zoom(2, under: 0)) == .pass)
check("gesture: an end without its beginning, placed only by bounds: passes", once(zoom(4, under: 0)) == .pass)
check("gesture: a change without its beginning, over the panel by the window server's word: sent", once(zoom(2)) == .forward)
check("gesture: an event without phases, inside the bounds: sent", once(zoom(0, under: 0, type: 30)) == .forward)
for (sub, n) in [(Int64(6), "scroll"), (5, "rotate"), (16, "swipe"), (0, "unknown")] {
    check("gesture: a \(n) gesture (subtype \(sub)) over the panel passes", once(zoom(2, subtype: sub)) == .pass)
}
for (sub, n) in [(Int64(23), "Dock swipe (Spaces, Mission Control, Launchpad)"), (0, "unmarked")] {
    check("gesture: a \(n) control event (type 30, subtype \(sub)) over the panel passes",
          [1, 2, 4, 0].allSatisfy { once(zoom($0, type: 30, subtype: sub)) == .pass })
}
do {
    var r = GestureRoute()
    _ = r.go(zoom(1))
    check("a Dock swipe during a pinch taken by the panel passes", r.go(zoom(2, type: 30, subtype: 23)) == .pass && r.pinch != nil)
}
for t in [Int64(22), 31, 18, 19, 20] { check("gesture: event type \(t) over the panel passes", once(zoom(2, type: t)) == .pass) }
do {
    var r = GestureRoute()
    check("pinch begun over the panel: sent", r.go(zoom(1)) == .forward)
    check("pinch begun over the panel: its changes are sent when the pointer drifts off", r.go(zoom(2, under: 77, at: outside)) == .forward)
    check("pinch begun over the panel: its end is sent off the panel too", r.go(zoom(4, under: 77, at: outside)) == .forward)
    check("pinch ended: the next change elsewhere is decided afresh", r.go(zoom(2, under: 77, at: outside)) == .pass && r.pinch == nil)
    check("pinch begun elsewhere: passes", r.go(zoom(1, under: 77)) == .pass)
    check("pinch begun elsewhere: its changes pass over the panel", r.go(zoom(2)) == .pass)
    check("pinch begun elsewhere: its cancel passes over the panel", r.go(zoom(8)) == .pass && r.pinch == nil)
    check("may-begin over the panel: sent, and holds", r.go(zoom(128)) == .forward && r.pinch?.taking == true)
    check("pinch over the panel, panel closed mid-way: the rest passes", r.go(zoom(2), open: false) == .pass)
    r.reset()
    check("reset: nothing held", r.pinch == nil)
    check("pinch begun by bounds: held to its end though later events carry no window", r.go(zoom(1, under: 0)) == .forward
          && r.go(zoom(2, under: 0, at: outside)) == .forward && r.go(zoom(4, under: 0, at: outside)) == .forward)
}
do {
    var r = GestureRoute()
    check("one pinch as two streams: the gesture stream that began it is sent", r.go(zoom(1)) == .forward)
    check("one pinch as two streams: the magnify stream's beginning is swallowed", r.go(zoom(1, type: 30)) == .swallow)
    check("one pinch as two streams: its changes are swallowed, the gesture's sent", r.go(zoom(2, type: 30)) == .swallow && r.go(zoom(2)) == .forward)
    check("one pinch as two streams: the other stream's end leaves the pinch held", r.go(zoom(4, type: 30)) == .swallow && r.pinch != nil)
    check("one pinch as two streams: the first stream's end ends it", r.go(zoom(4)) == .forward && r.pinch == nil)
    _ = r.go(zoom(1, under: 77))
    check("a pinch elsewhere as two streams: both pass", r.go(zoom(2, type: 30)) == .pass && r.go(zoom(2, under: 77)) == .pass)
    r.reset()
    check("smart zoom as two events: the first is sent", r.go(zoom(0, subtype: 22, time: 10)) == .forward)
    check("smart zoom as two events: the other type within 50 ms is swallowed", r.go(zoom(0, type: 32, time: 10.02)) == .swallow)
    check("smart zoom: the next tap is sent", r.go(zoom(0, type: 32, time: 10.5)) == .forward)
    check("smart zoom: two of the same type are two taps", r.go(zoom(0, type: 32, time: 10.51)) == .forward)
    check("smart zoom elsewhere: passes, and its twin too", r.go(zoom(0, under: 77, subtype: 22, time: 20)) == .pass && r.go(zoom(0, under: 77, type: 32, time: 20.01)) == .pass)
}
check("gesture: placed by bounds only when the event names no window", GestureRoute.byBounds(zoom(1, under: 0)) && !GestureRoute.byBounds(zoom(1)))
check("link: only the viewer may report the panel's frame", Link.permits(.viewer, .panelMoved) && !Link.permits(.app, .panelMoved))

do {
    let f = NSTemporaryDirectory() + "helper-stamp-\(getpid())"
    FileManager.default.createFile(atPath: f, contents: Data("a".utf8))
    let before = HelperBinary.stamp(f)
    try? FileManager.default.removeItem(atPath: f)
    FileManager.default.createFile(atPath: f + ".new", contents: Data("a".utf8))
    try? FileManager.default.moveItem(atPath: f + ".new", toPath: f)
    let after = HelperBinary.stamp(f)
    try? FileManager.default.removeItem(atPath: f)
    check("binary stamp: a file replaced in place (a new install) stamps differently; a missing one is empty",
          !before.isEmpty && !after.isEmpty && before != after && HelperBinary.stamp(f).isEmpty)
}

print(failures == 0 ? "\nall helper checks passed (\(recorded.count) recorded contexts)" : "\n\(failures) helper checks failed")
exit(failures == 0 ? 0 : 1)
