import AppKit
import ObjectiveC

/// Keeps a harness's windows where it parked them, far off every display. AppKit's `constrainFrameRect(_:to:)` pulls a titled
/// window back onto a screen (a panel parked at -20000,-20000 lands at the bottom left of the main display), so it is replaced
/// by the identity for every window in the process. A titled window is also moved on screen when it is made, whatever its
/// content rect, so it must be given its parked frame before it is ordered in. Ordering in a window that overlaps a screen
/// aborts the run before the window server sees it, and a watchdog checks each visible window on every move and resize and on
/// a short timer: a harness must never show a window to the user.
/// Call `OffScreen.install()` right after `NSApplication.shared`, before any window exists.
enum OffScreen {
    private static var installed = false

    static func install() {
        guard !installed else { return }
        installed = true
        let sel = #selector(NSWindow.constrainFrameRect(_:to:))
        let identity: @convention(block) (AnyObject, NSRect, NSScreen?) -> NSRect = { _, rect, _ in rect }
        let imp = imp_implementationWithBlock(identity)
        let types = method_getTypeEncoding(class_getInstanceMethod(NSWindow.self, sel)!)
        // NSPanel and any subclass that overrides the method get the identity too.
        for cls in [NSWindow.self, NSPanel.self] { class_replaceMethod(cls, sel, imp, types) }

        // Every way into the window list, checked before the window server sees the window.
        let orderSel = #selector(NSWindow.order(_:relativeTo:))
        let orderMethod = class_getInstanceMethod(NSWindow.self, orderSel)!
        typealias Order = @convention(c) (NSWindow, Selector, Int, Int) -> Void
        let order = unsafeBitCast(method_getImplementation(orderMethod), to: Order.self)
        let ordered: @convention(block) (NSWindow, Int, Int) -> Void = { w, place, other in
            if place != NSWindow.OrderingMode.out.rawValue { refuse(w) }
            order(w, orderSel, place, other)
        }
        method_setImplementation(orderMethod, imp_implementationWithBlock(ordered))
        let regardlessSel = #selector(NSWindow.orderFrontRegardless)
        let regardlessMethod = class_getInstanceMethod(NSWindow.self, regardlessSel)!
        typealias Plain = @convention(c) (NSWindow, Selector) -> Void
        let regardless = unsafeBitCast(method_getImplementation(regardlessMethod), to: Plain.self)
        let front: @convention(block) (NSWindow) -> Void = { w in refuse(w); regardless(w, regardlessSel) }
        method_setImplementation(regardlessMethod, imp_implementationWithBlock(front))
        typealias Sender = @convention(c) (NSWindow, Selector, AnyObject?) -> Void
        for sel in [#selector(NSWindow.orderFront(_:)), #selector(NSWindow.makeKeyAndOrderFront(_:)), #selector(NSWindow.orderBack(_:))] {
            let m = class_getInstanceMethod(NSWindow.self, sel)!
            let original = unsafeBitCast(method_getImplementation(m), to: Sender.self)
            let checked: @convention(block) (NSWindow, AnyObject?) -> Void = { w, sender in refuse(w); original(w, sel, sender) }
            method_setImplementation(m, imp_implementationWithBlock(checked))
        }

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in check() }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in check() }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Gives every window and screen `scale` as its backing scale, whatever the displays are, so a 2x Mac can check what a 1x
    /// display (a GitHub runner's) does: AppKit aligns scroll positions to backing pixels. Call it before any window exists.
    static func backingScale(_ scale: CGFloat) {
        let fixed: @convention(block) (AnyObject) -> CGFloat = { _ in scale }
        for (cls, sel) in [(NSWindow.self as AnyClass, #selector(getter: NSWindow.backingScaleFactor)),
                           (NSScreen.self as AnyClass, #selector(getter: NSScreen.backingScaleFactor))] {
            method_setImplementation(class_getInstanceMethod(cls, sel)!, imp_implementationWithBlock(fixed))
        }
    }

    /// A web view in a window off every screen counts as occluded, and WebKit then stops requestAnimationFrame (the page's
    /// "rendered" message, a PDF's placement, mermaid): it is told to draw as a visible one would (WKWebView SPI, harness only).
    static func keepDrawing(_ web: NSView) {
        let sel = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard web.responds(to: sel) else { return print("SKIP OFFSCREEN: this WebKit cannot be told to draw while occluded") }
        typealias SetBool = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(web.method(for: sel), to: SetBool.self)(web, sel, false)
    }

    /// Aborts if any visible window of this process overlaps a screen.
    static func check() {
        for w in NSApp.windows where w.isVisible { refuse(w) }
    }

    /// Aborts if `w` overlaps a screen.
    private static func refuse(_ w: NSWindow) {
        let f = w.frame
        guard let s = NSScreen.screens.first(where: { $0.frame.intersects(f) }) else { return }
        for other in NSApp.windows { other.alphaValue = 0; other.orderOut(nil) }
        print("FAIL OFFSCREEN: a \(type(of: w)) at \(f) would be on the display at \(s.frame); run aborted")
        fflush(stdout)
        exit(70)
    }
}
