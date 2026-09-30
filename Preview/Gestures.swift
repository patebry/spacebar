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

    override func smartMagnify(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let z = max(pageZoom * magnification, 0.01)
        let y = isFlipped ? p.y : bounds.height - p.y
        evaluateJavaScript("window.sb && sb.smartZoom && sb.smartZoom({x: \(Double(p.x / z)), y: \(Double(y / z))})")
    }
}
