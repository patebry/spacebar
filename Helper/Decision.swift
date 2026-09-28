import Foundation

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
}

struct PanelContext: Equatable {
    /// The panel is open, or a show is on its way to the viewer.
    var open: Bool
    var finderPid: Int32
    var viewerPid: Int32
    var sidebarKeys = true
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

    mutating func route(_ e: KeyEvent, panel: PanelContext) -> Route {
        if e.tagged { return .pass }
        if !e.down { return held.remove(e.code) != nil ? .swallow : .pass }
        let mine = panel.open && (e.targetPid == panel.finderPid || (panel.viewerPid > 0 && e.targetPid == panel.viewerPid))
        if held.contains(e.code) {
            if mine, e.isRepeat, let name = Self.forwarded(e, sidebarKeys: panel.sidebarKeys), HelperKeys.list.contains(name) { return .forward(name) }
            return .swallow
        }
        guard panel.open else { return Decision.wantsSpace(e) ? .space : .pass }
        guard mine else { return .pass }
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
