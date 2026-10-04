import AppKit
import WebKit

/// NSApplication.sendEvent drops pinch and smart-zoom events while the app is not active, key window or not; scrolls and clicks
/// still get through. The Space viewer is never active (Finder stays frontmost), so without this nothing in its panel could be
/// pinched. The event goes to its window directly, which hands it to the view under the pointer as it would in an active app.
enum GestureRouter {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.magnify, .smartMagnify]) { e in
            guard !NSApp.isActive, let w = e.window else { return e }
            w.sendEvent(e)
            return nil
        }
    }
}

/// While an edit holds the keyboard the preview's window is not key, and WKWebView takes the first click into a non-key
/// window only as window activation. Every click here edits, selects or follows a link, so it must land on the first try.
/// A two-finger double tap (smart zoom) goes to the page's image viewer; WebKit does nothing with it unless the whole page
/// can be magnified.
final class PreviewWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The press the pointer is in (its latest event, and where it began): a file drag starts from it, and only while the button
    /// is still down.
    private var press: NSEvent?
    private var pressedAt: NSPoint?
    private var dragging = false

    override func mouseDown(with e: NSEvent) { press = e; pressedAt = e.locationInWindow; super.mouseDown(with: e) }
    override func mouseDragged(with e: NSEvent) { press = e; super.mouseDragged(with: e) }
    override func mouseUp(with e: NSEvent) { press = nil; pressedAt = nil; super.mouseUp(with: e) }

    /// Why a file drag cannot start now, or nil: the page asks once the pointer has moved on a row with the button held, and
    /// only a press the user is still making in this view starts one.
    func fileDragRefusal() -> String? {
        guard !dragging else { return "a drag is under way" }
        guard let e = press, e.window === window, window != nil else { return "no press in this view" }
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return "the button is up" }
        guard ProcessInfo.processInfo.systemUptime - e.timestamp < 5 else { return "the press is stale" }
        return nil
    }

    /// Drags `file` out as a file URL, as a Finder drag does, from the press under way: a copy only, since a preview must never
    /// move a file (Finder moves on a plain drop within a volume). WebKit never sees that press end, so it is given a mouse-up
    /// where it began once the drag is over.
    @discardableResult
    func beginFileDrag(_ file: URL, source: NSDraggingSource) -> String? {
        if let why = fileDragRefusal() { return why }
        guard let e = press else { return "no press in this view" }
        let item = NSDraggingItem(pasteboardWriter: file as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: file.path)
        let p = convert(e.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 16, y: p.y - 16, width: 32, height: 32), contents: icon)
        dragging = true
        let session = beginDraggingSession(with: [item], event: e, source: source)
        session.animatesToStartingPositionsOnCancelOrFail = true
        return nil
    }

    /// The drag ended: WebKit is handed the mouse-up it never got, where the press began, so it stops tracking the press.
    func fileDragEnded() {
        dragging = false
        guard let e = press, let w = window else { return }
        let at = pressedAt ?? e.locationInWindow
        press = nil
        pressedAt = nil
        if let up = NSEvent.mouseEvent(with: .leftMouseUp, location: at, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: w.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0) {
            super.mouseUp(with: up)
        }
    }

    override func smartMagnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let z = max(pageZoom * magnification, 0.01)
        let y = isFlipped ? p.y : bounds.height - p.y
        evaluateJavaScript("window.sb && sb.smartZoom && sb.smartZoom({x: \(Double(p.x / z)), y: \(Double(y / z))})")
    }
}
