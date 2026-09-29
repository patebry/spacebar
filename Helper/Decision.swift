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
    static let home: Int64 = 115, end: Int64 = 119, pageUp: Int64 = 116, pageDown: Int64 = 121
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

    /// How long a panel hidden by another app coming forward waits for Finder to come back.
    static let suspendLimit: TimeInterval = 10 * 60

    /// An app came forward. Another app hides an open panel, as it hides Apple's Quick Look, and closes a show still on its way;
    /// Finder brings a hidden panel back within `suspendLimit`. The panel brought back is a show like any other: pending, it
    /// holds the closing and list keys as a Space's show does, and keeps them only once `panelOpened` accepts it.
    static func activated(isFinder: Bool, open: Bool, pending: Bool, suspendedFor age: TimeInterval?) -> ActivationAction {
        if !isFinder { return pending ? .close : open ? .suspend : .none }
        guard let age, !open, !pending else { return .none }
        return age < suspendLimit ? .restore : .forget
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

enum ActivationAction: Equatable { case none, close, suspend, restore, forget }

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
        if Self.closes(e) { held.insert(e.code); return .close }
        if let name = Self.forwarded(e, sidebarKeys: panel.sidebarKeys) { held.insert(e.code); return .forward(name) }
        return .pass
    }

    /// Space, Esc, ⌘W and ⌘. close the panel in one press.
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
            case KeyCode.home: return "home"
            case KeyCode.end: return "end"
            case KeyCode.pageUp: return "pageup"
            case KeyCode.pageDown: return "pagedown"
            case KeyCode.returnKey, KeyCode.enter: return "return"
            default: return nil
            }
        }
        // ⌘+ is ⌘⇧= on most layouts.
        guard e.mods.contains(.command), e.mods.isSubset(of: [.command, .shift]) else { return nil }
        if e.code == KeyCode.keypadPlus || e.chars == "=" || e.chars == "+" { return "zoomIn" }
        if e.code == KeyCode.keypadMinus || e.chars == "-" { return e.mods == .command ? "zoomOut" : nil }
        guard e.mods == .command else { return nil }
        if e.code == KeyCode.keypad0 || e.chars == "0" { return "zoomReset" }
        if e.chars == "o" { return "open" }
        if e.chars == "f" { return "find" }
        return nil
    }
}
