import Foundation
import CoreGraphics

/// One key event as the tap saw it, reduced to what routing needs.
struct KeyEvent: Equatable {
    var code: Int64
    /// The character the key types without modifiers, in the current layout (so ⌘W is W on AZERTY too).
    var chars: String = ""
    var down = true
    var isRepeat = false
    var mods: HelperMods = []
    /// Posted by the helper itself (`Decision.repostTag` in eventSourceUserData).
    var tagged = false
    var targetPid: Int32 = 0
}

enum KeyCode {
    static let space: Int64 = 49, escape: Int64 = 53, returnKey: Int64 = 36, enter: Int64 = 76
    static let left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126
    static let home: Int64 = 115, end: Int64 = 119, pageUp: Int64 = 116, pageDown: Int64 = 121, delete: Int64 = 51
    static let keypadPlus: Int64 = 69, keypadMinus: Int64 = 78, keypad0: Int64 = 82
}

/// What the AX reads found when Space was pressed with the panel closed.
struct SpaceContext: Equatable {
    var frontIsFinder: Bool
    var role: String? = nil
    var subrole: String? = nil
    var quickLookOpen = false
    var selection: [String] = []
    var axErrors: [String] = []
    var elapsedMs: Double = 0
}

enum SpaceDecision: Equatable {
    case show([String])
    case pass(String)
}

enum Decision {
    /// Marks events the helper posts (a Space handed back to Finder), so its own tap lets them through.
    static let repostTag: Int64 = 0x5350_4832
    /// The AX reads for one Space; past it the key goes to Finder.
    static let budgetMs = 60.0
    static let axTimeout: Float = 0.05
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]

    /// Whether Space with the panel closed is worth reading Finder for: a plain first press.
    static func wantsSpace(_ e: KeyEvent) -> Bool {
        e.down && e.code == KeyCode.space && e.mods.isEmpty && !e.isRepeat && !e.tagged
    }

    static func space(_ c: SpaceContext) -> SpaceDecision {
        guard c.frontIsFinder else { return .pass("not-finder") }
        guard c.axErrors.isEmpty else { return .pass("ax-error") }
        guard c.elapsedMs <= budgetMs else { return .pass("budget") }
        if let r = c.role, textRoles.contains(r) { return .pass("text-focus") }
        if c.subrole == "AXSearchField" { return .pass("text-focus") }
        if c.quickLookOpen { return .pass("ql-open") }
        // A name AX gave without its folder is not a path; nothing is guessed.
        let paths = c.selection.filter { $0.hasPrefix("/") }
        return paths.isEmpty ? .pass("no-selection") : .show(paths)
    }

    /// A Space older than this is not handed back to Finder: Apple's panel opening then would surprise more than nothing.
    static let staleSpace: TimeInterval = 1

    /// What a failed show leaves behind. A Space goes back to Finder while it is fresh, and the viewer, which may still answer
    /// late, must not open over Apple's panel. A follow of Finder's selection that failed leaves the panel as it is.
    static func failed(space: Bool, age: TimeInterval) -> FailAction {
        guard space else { return .leave }
        return age < staleSpace ? .closeAndRepost : .close
    }

    /// The viewer's word that its panel opened for `requestID`: only a pending show may take Finder's keys, and only with its
    /// window really up. The window server may not have the first frame yet, so it gets one retry.
    static func panelOpened(pendingID: Int?, requestID: Int, onScreen: Bool, retried: Bool) -> PanelGate {
        guard let p = pendingID, p == requestID else { return .notPending }
        if onScreen { return .accept }
        return retried ? .fail : .retry
    }

    /// The viewer closed its panel while showing `requestID`: the show it was answering is over.
    static func closeEndsPending(pendingID: Int?, requestID: Int) -> Bool {
        requestID > 0 && pendingID == requestID
    }

    /// Whether the viewer's window is worth taking Finder's keys for: the viewer's, on screen, visible, big enough to read and
    /// on a display.
    static func panelVisible(_ w: WindowInfo, viewerPid: Int32, displays: [CGRect]) -> Bool {
        viewerPid > 0 && w.owner == viewerPid && w.onScreen && w.alpha > 0 && w.bounds.width >= 200 && w.bounds.height >= 150
            && displays.contains { $0.intersects(w.bounds) }
    }

    /// How long a panel hidden by another app coming forward waits for Finder to come back. Long enough to answer a message or
    /// copy a value and come back; past it the panel is a leftover the user no longer expects.
    static let suspendLimit: TimeInterval = 2 * 60

    /// What Finder's selection was read to be when Finder came back while a panel was hidden.
    struct ResumeRead: Equatable {
        var selection: [String] = []
        /// Finder's focus is in no window: the Desktop.
        var desktop = false
        /// A mouse button went down just before Finder came forward.
        var clicked = false
        var axErrors: [String] = []
        var elapsedMs: Double = 0
    }

    static func tapAction(exists: Bool, trusted: Bool) -> TapAction {
        exists ? (trusted ? .none : .remove) : (trusted ? .create : .none)
    }

    /// A tap macOS disabled (a timeout, or user input such as Accessibility being turned off) is enabled again only while
    /// Accessibility is still granted; otherwise the watch removes it.
    static func reenablesTap(trusted: Bool) -> Bool { trusted }

    /// An app came forward. Another app hides an open panel, as it hides Apple's Quick Look, and closes a show still on its way.
    /// Finder coming back within `suspendLimit` has its selection read (`resumes`) before anything comes back.
    static func activated(isFinder: Bool, open: Bool, pending: Bool, suspendedFor age: TimeInterval?) -> ActivationAction {
        if !isFinder { return pending ? .close : open ? .suspend : .none }
        guard let age, !open, !pending else { return .none }
        return age < suspendLimit ? .check : .forget
    }

    /// Finder is back and its selection read: the hidden panel comes back only for the selection it was showing. Any other
    /// selection, none, a click on the Desktop, or a read with an AX error or past the budget drops it as a close does, so
    /// nothing stale comes back later and the next Space shows what is selected then. The panel brought back is a show like
    /// any other: pending, it holds the closing and list keys as a Space's show does, and keeps them only once `panelOpened`
    /// accepts it.
    static func resumes(_ r: ResumeRead, shown: [String], suspendedFor age: TimeInterval) -> ActivationAction {
        guard age < suspendLimit, r.axErrors.isEmpty, r.elapsedMs <= budgetMs, !(r.desktop && r.clicked) else { return .forget }
        let selected = Set(r.selection.filter { $0.hasPrefix("/") })
        return !selected.isEmpty && selected == Set(shown) ? .restore : .forget
    }

    /// Whether Finder's focus is a text field. Any AX error, or a budget spent before the role was read, counts as one.
    static func textFocus(_ r: FocusRead) -> Bool {
        if r.errors { return true }
        guard r.found else { return r.expired }
        if r.role == nil, r.expired { return true }
        return textRoles.contains(r.role ?? "") || r.subrole == "AXSearchField"
    }
}

enum FailAction: Equatable { case leave, close, closeAndRepost }

/// `check`: Finder is back within the limit and its selection decides (`Decision.resumes`).
enum ActivationAction: Equatable { case none, close, suspend, check, restore, forget }

/// What the watch does with the event tap: made once Accessibility is granted, torn down once it is revoked.
enum TapAction: Equatable { case none, create, remove }


enum PanelGate: Equatable { case accept, notPending, retry, fail }

struct WindowInfo: Equatable {
    var owner: Int32
    var onScreen: Bool
    var alpha: Double
    var bounds: CGRect
}

/// One read of Finder's focused element within the AX budget.
struct FocusRead: Equatable {
    var found: Bool
    var role: String? = nil
    var subrole: String? = nil
    var errors = false
    var expired = false
}

struct PanelContext: Equatable {
    /// The panel is open, or a show is on its way to the viewer.
    var open: Bool
    var finderPid: Int32
    var viewerPid: Int32
    var sidebarKeys = true
    /// Finder's focus is in a text field (a rename, the search field): its keys are the user's typing.
    var textFocus = false
    /// The viewer's writer panel holds the keyboard for an edit, the filter or the find field (`TextSession`).
    var textSession = false
    /// One of the page's popovers is open (`popover` from the viewer): Esc closes it instead of the panel.
    var popover = false
}

/// The viewer's word that its writer's key panel holds the keyboard. Only the panel it is open for, or on its way, can have one,
/// and every end of that panel ends it. The window server annotates keys with the frontmost app's pid, Finder's, not the pid of
/// the non-activating panel that receives them, so without this the helper would take the typing's Space, Esc and arrows.
struct TextSession {
    private(set) var active = false

    /// Returns whether the helper now holds what the viewer said.
    mutating func set(_ on: Bool, panelOpen: Bool) -> Bool {
        active = on && panelOpen
        return active == on
    }

    mutating func clear() { active = false }
}

enum Route: Equatable {
    case pass
    /// The rest of a key already taken: its repeats and its key-up.
    case swallow
    /// Panel closed and a plain Space: read Finder and ask `Decision.space`.
    case space
    case close
    case forward(String)
}

/// Routes each key while the helper's tap is on. Holds the keys it took, so their repeats and key-ups never reach Finder alone.
struct KeyRoute {
    private(set) var held: Set<Int64> = []

    mutating func hold(_ code: Int64) { held.insert(code) }

    /// Forgets every held key: after the tap was off, their key-ups may never come.
    mutating func release() { held.removeAll() }

    mutating func route(_ e: KeyEvent, panel: PanelContext) -> Route {
        if e.tagged { return .pass }
        if !e.down { return held.remove(e.code) != nil ? .swallow : .pass }
        // Every key is the typing's, Esc too: the session ends itself, and the next Esc or Space closes.
        if panel.open, panel.textSession { held.remove(e.code); return .pass }
        let mine = panel.open && (e.targetPid == panel.finderPid || (panel.viewerPid > 0 && e.targetPid == panel.viewerPid))
        // A fresh press of a held key means its key-up was missed: route it as new.
        if held.contains(e.code), !e.isRepeat { held.remove(e.code) }
        if held.contains(e.code) {
            if mine, e.isRepeat, let name = Self.forwarded(e, sidebarKeys: panel.sidebarKeys), HelperKeys.list.contains(name) { return .forward(name) }
            return .swallow
        }
        // Only a Space on its way to Finder: a non-activating panel of another app (a launcher, a password manager) can have
        // the keys while Finder stays frontmost.
        guard panel.open else { return Decision.wantsSpace(e) && e.targetPid == panel.finderPid && e.targetPid > 0 ? .space : .pass }
        guard mine, !(panel.textFocus && e.targetPid == panel.finderPid) else { return .pass }
        if Self.closes(e) {
            held.insert(e.code)
            return panel.popover && e.code == KeyCode.escape ? .forward(HelperKeys.escape) : .close
        }
        if let name = Self.forwarded(e, sidebarKeys: panel.sidebarKeys) { held.insert(e.code); return .forward(name) }
        return .pass
    }

    /// Space, Esc, ⌘W and ⌘. close the panel in one press; Esc closes a popover of the page first, while one is open.
    static func closes(_ e: KeyEvent) -> Bool {
        if e.mods.isEmpty { return (e.code == KeyCode.space && !e.isRepeat) || e.code == KeyCode.escape }
        return e.mods == .command && !e.isRepeat && (e.chars == "w" || e.chars == ".")
    }

    static func forwarded(_ e: KeyEvent, sidebarKeys: Bool) -> String? {
        if e.mods.isEmpty {
            switch e.code {
            case KeyCode.up: return sidebarKeys ? "up" : nil
            case KeyCode.down: return sidebarKeys ? "down" : nil
            case KeyCode.left: return sidebarKeys ? "left" : nil
            case KeyCode.right: return sidebarKeys ? "right" : nil
            case KeyCode.delete: return sidebarKeys ? "back" : nil
            case KeyCode.home: return "home"
            case KeyCode.end: return "end"
            case KeyCode.pageUp: return "pageup"
            case KeyCode.pageDown: return "pagedown"
            case KeyCode.returnKey, KeyCode.enter: return "return"
            default: return nil
            }
        }
        if e.mods == [.command, .option] { return e.chars == "f" ? "filter" : nil }
        // ⌘+ is ⌘⇧= on most layouts.
        guard e.mods.contains(.command), e.mods.isSubset(of: [.command, .shift]) else { return nil }
        if e.code == KeyCode.keypadPlus || e.chars == "=" || e.chars == "+" { return "zoomIn" }
        if e.code == KeyCode.keypadMinus || e.chars == "-" { return e.mods == .command ? "zoomOut" : nil }
        guard e.mods == .command else { return nil }
        if e.code == KeyCode.keypad0 || e.chars == "0" { return "zoomReset" }
        if e.chars == "o" { return "open" }
        if e.chars == "f" { return "find" }
        if e.chars == "c" { return "copy" }
        return nil
    }
}

/// A trackpad event of the zooming kinds as the tap saw it. Type 29 is the window server's gesture event, `subtype` its HID
/// kind (8 a pinch, 22 a two-finger double tap); 30 and 32 are a pinch and a smart zoom already typed as such.
struct GestureEvent: Equatable {
    var type: Int64
    var subtype: Int64 = 0
    /// CGGesturePhase: 1 began, 2 changed, 4 ended, 8 cancelled, 128 may begin; 0 for an event without phases.
    var phase: Int64 = 0
    /// The window under the pointer as the window server annotated it; 0 when it did not.
    var windowUnder: Int = 0
    /// Global, from the top left of the main display.
    var location: CGPoint = .zero
    /// Seconds since startup.
    var time: Double = 0
}

enum GestureAction: Equatable {
    case pass
    /// Sent to the viewer and kept from Finder.
    case forward
    /// Kept from Finder and not sent: the pinch or smart zoom already sent, arriving again as the other event type.
    case swallow
}

/// Takes the pinches and smart zooms made over the open panel, which the window server would otherwise hand to Finder, the
/// active app. A pinch is decided where it begins and keeps that answer to its end, so neither app sees half of one, and only
/// the event type it began as is sent on. Every other gesture (scrolls, swipes, Mission Control) and every zoom elsewhere is
/// Finder's or the system's.
struct GestureRoute {
    /// The pinch under way: the event type it began as, and whether it is the panel's.
    private(set) var pinch: (stream: Int64, taking: Bool)?
    private var lastSmart: (type: Int64, time: Double)?
    /// A smart zoom of the other type this close to one already taken is the same tap.
    static let smartTwin = 0.05

    /// The gesture tap runs only while the panel is open or a pinch it took is under way; the rest of the time no gesture
    /// event waits on the helper.
    static func tapOn(open: Bool, pinching: Bool) -> Bool { open || pinching }

    /// Type 30 is also the window server's Dock control event, which carries the system's swipes (Spaces, Mission Control,
    /// Launchpad, App Exposé) as subtype 23; only one marked as a zoom is a pinch.
    static func zooms(_ g: GestureEvent) -> Bool {
        g.type == 32 || ((g.type == 29 || g.type == 30) && g.subtype == 8) || (g.type == 29 && g.subtype == 22)
    }

    static func smart(_ g: GestureEvent) -> Bool { g.type == 32 || (g.type == 29 && g.subtype == 22) }

    /// Placed by the panel's last known bounds, the window server having named no window under the pointer.
    static func byBounds(_ g: GestureEvent) -> Bool { g.windowUnder == 0 }

    /// Over the panel by the window server's word, or by its last known bounds when the event carries no window.
    static func overPanel(_ g: GestureEvent, panelWindow: Int, bounds: CGRect) -> Bool {
        guard panelWindow > 0 else { return false }
        return g.windowUnder > 0 ? g.windowUnder == panelWindow : bounds.contains(g.location)
    }

    mutating func route(_ g: GestureEvent, open: Bool, panelWindow: Int, bounds: CGRect) -> GestureAction {
        guard Self.zooms(g) else { return .pass }
        let here = open && Self.overPanel(g, panelWindow: panelWindow, bounds: bounds)
        if Self.smart(g) {
            if let s = lastSmart, s.type != g.type, abs(g.time - s.time) < Self.smartTwin {
                lastSmart = nil
                return here ? .swallow : .pass
            }
            lastSmart = here ? (g.type, g.time) : nil
            return here ? .forward : .pass
        }
        if let p = pinch, p.stream != g.type { return open && p.taking ? .swallow : .pass }
        switch g.phase {
        case 1, 128:
            pinch = (g.type, here)
            return here ? .forward : .pass
        case 0:
            return here ? .forward : .pass
        default:
            let ends = g.phase == 4 || g.phase == 8
            defer { if ends { pinch = nil } }
            if let p = pinch { return open && p.taking ? .forward : .pass }
            // Without its beginning, a pinch is placed only by the window server's word, never by bounds that may be old.
            return here && !Self.byBounds(g) ? .forward : .pass
        }
    }

    mutating func reset() { pinch = nil; lastSmart = nil }
}
