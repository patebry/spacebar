import Cocoa
import ApplicationServices

let finderID = "com.apple.finder"

func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(since t0: UInt64) -> Double { Double(nowNs() &- t0) / 1_000_000 }

/// The AX errors of one read, so the caller can fail open. noValue and attributeUnsupported are answers, not errors.
final class AXTrace {
    var errors: [String] = []
    let started = nowNs()
    let deadline: UInt64
    init(budgetMs: Double = Decision.budgetMs) { deadline = started + UInt64(budgetMs * 1_000_000) }
    var expired: Bool { nowNs() > deadline }
    var elapsedMs: Double { ms(since: started) }

    func attr(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        if expired { return nil }
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(el, name as CFString, &v)
        switch e {
        case .success: return v
        case .noValue, .attributeUnsupported: return nil
        default:
            let s = "\(name):\(e.rawValue)"
            if !errors.contains(s) { errors.append(s) }
            return nil
        }
    }

    func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = attr(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }
    func elements(_ el: AXUIElement, _ name: String) -> [AXUIElement]? {
        guard let v = attr(el, name), let arr = v as? [AnyObject] else { return nil }
        return arr.compactMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
    }
    func string(_ el: AXUIElement, _ name: String) -> String? { attr(el, name) as? String }
    func url(_ el: AXUIElement, _ name: String) -> URL? {
        guard let v = attr(el, name) else { return nil }
        if let u = v as? URL { return u }
        if let s = v as? String { return URL(string: s) }
        return nil
    }
    func role(_ el: AXUIElement) -> String? { string(el, kAXRoleAttribute) }
    func subrole(_ el: AXUIElement) -> String? { string(el, kAXSubroleAttribute) }
}

enum FinderAX {
    /// Everything `Decision.space` needs, read within the budget. Stops at the first thing that already decides.
    static func spaceContext(finderPid: pid_t) -> SpaceContext {
        let trace = AXTrace()
        let app = AXUIElementCreateApplication(finderPid)
        var c = SpaceContext(frontIsFinder: true)
        let focused = trace.element(app, kAXFocusedUIElementAttribute)
        if let f = focused { c.role = trace.role(f); c.subrole = trace.subrole(f) }
        let finish = { () -> SpaceContext in c.axErrors = trace.errors; c.elapsedMs = trace.elapsedMs; return c }
        if Decision.space(finish()) != .pass("no-selection") { return finish() }
        c.quickLookOpen = quickLookOpen(finderPid: finderPid, app: app, trace: trace)
        if c.quickLookOpen { return finish() }
        c.selection = selection(app: app, focused: focused, trace: trace)
        return finish()
    }

    /// Finder's selection when it comes back over a hidden panel, within the same budget as a Space.
    static func resumeRead(finderPid: pid_t) -> Decision.ResumeRead {
        let trace = AXTrace()
        let app = AXUIElementCreateApplication(finderPid)
        var r = Decision.ResumeRead()
        let focused = trace.element(app, kAXFocusedUIElementAttribute)
        if let f = focused {
            r.desktop = trace.element(f, kAXWindowAttribute) == nil
            r.selection = selection(app: app, focused: f, trace: trace)
        }
        r.axErrors = trace.errors
        r.elapsedMs = trace.elapsedMs
        return r
    }

    /// Finder's selection through AX only: from the focused element up to 4 ancestors (then its children) for AXSelectedRows or
    /// AXSelectedChildren, each item resolved to a path through AXURL, or AXFilename in its window's folder.
    static func selection(app: AXUIElement, focused: AXUIElement?, trace: AXTrace) -> [String] {
        guard let f = focused ?? trace.element(app, kAXFocusedUIElementAttribute) else { return [] }
        var candidates: [AXUIElement] = []
        var el: AXUIElement? = f
        var depth = 0
        while let e = el, depth < 5 {
            candidates.append(e)
            el = trace.element(e, kAXParentAttribute)
            depth += 1
        }
        candidates += (trace.elements(f, kAXChildrenAttribute) ?? []).prefix(8)
        for e in candidates {
            if trace.expired { break }
            for attr in [kAXSelectedRowsAttribute, kAXSelectedChildrenAttribute] as [String] {
                guard let items = trace.elements(e, attr), !items.isEmpty else { continue }
                var dir: String??
                return items.prefix(200).compactMap { itemPath($0, trace: trace, dir: &dir) }
            }
        }
        return []
    }

    private static func itemPath(_ item: AXUIElement, trace: AXTrace, dir: inout String??) -> String? {
        var queue: [(AXUIElement, Int)] = [(item, 0)]
        var visited = 0
        while !queue.isEmpty, visited < 25, !trace.expired {
            let (e, d) = queue.removeFirst()
            visited += 1
            // The Desktop gives file reference URLs (file:///.file/id=…), whose path names no file.
            if let u = trace.url(e, kAXURLAttribute), u.isFileURL, let p = (u as NSURL).filePathURL?.path { return p }
            if let name = trace.string(e, kAXFilenameAttribute), !name.isEmpty {
                if dir == nil { dir = .some(windowDirectory(item, trace: trace)) }
                guard let d = dir!, !d.isEmpty else { return nil }
                return (d as NSString).appendingPathComponent(name)
            }
            if d < 3 { queue += (trace.elements(e, kAXChildrenAttribute) ?? []).prefix(8).map { ($0, d + 1) } }
        }
        return nil
    }

    /// The folder of the window holding `item`, or ~/Desktop for an item on the Desktop, whose "window" is a scroll area.
    private static func windowDirectory(_ item: AXUIElement, trace: AXTrace) -> String? {
        if let w = trace.element(item, kAXWindowAttribute), trace.role(w) == kAXWindowRole {
            if let doc = trace.string(w, kAXDocumentAttribute), let u = URL(string: doc), u.isFileURL { return u.path }
            return nil
        }
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return (home as NSString).appendingPathComponent("Desktop")
    }

    /// Whether Apple's Quick Look panel is open for Finder: a floating window in Finder's AX tree, or an on-screen window of
    /// Finder above the normal layer, or one of a Quick Look process.
    static func quickLookOpen(finderPid: pid_t, app: AXUIElement? = nil, trace: AXTrace = AXTrace(budgetMs: 100)) -> Bool {
        let app = app ?? AXUIElementCreateApplication(finderPid)
        for w in (trace.elements(app, kAXWindowsAttribute) ?? []).prefix(20) {
            if let sr = trace.subrole(w), ["AXFloatingWindow", "AXSystemFloatingWindow", "AXQuickLookWindow"].contains(sr) { return true }
        }
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in info {
            let owner = w[kCGWindowOwnerName as String] as? String ?? ""
            let layer = w[kCGWindowLayer as String] as? Int ?? 0
            let pid = w[kCGWindowOwnerPID as String] as? pid_t ?? 0
            let alpha = w[kCGWindowAlpha as String] as? Double ?? 1
            let b = w[kCGWindowBounds as String] as? [String: Double] ?? [:]
            if alpha <= 0 || (b["Width"] ?? 0) < 80 || (b["Height"] ?? 0) < 80 { continue }
            if owner.contains("QuickLook") && layer >= 0 && layer < 1000 { return true }
            if pid == finderPid && layer > 0 && layer < 1000 { return true }
        }
        return false
    }
}
