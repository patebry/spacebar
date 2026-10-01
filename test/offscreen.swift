import AppKit
import ObjectiveC

/// Keeps a harness's windows where it parked them, far off every display. AppKit's `constrainFrameRect(_:to:)` pulls a titled
/// window back onto a screen (a panel parked at -20000,-20000 lands at the bottom left of the main display), so it is replaced
/// by the identity for every window in the process. A watchdog then checks each visible window, on every move and resize and
/// on a short timer, and aborts the run the moment one overlaps a real screen: a harness must never show a window to the user.
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

        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didChangeOcclusionStateNotification,
                     NSWindow.didChangeScreenNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) { _ in check() }
        }
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in check() }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// Aborts if any visible window of this process overlaps a screen.
    static func check() {
        for w in NSApp.windows where w.isVisible {
            let f = w.frame
            guard let s = NSScreen.screens.first(where: { $0.frame.intersects(f) }) else { continue }
            for other in NSApp.windows { other.alphaValue = 0; other.orderOut(nil) }
            print("FAIL OFFSCREEN: a \(type(of: w)) reached the screen at \(f) (display \(s.frame)); run aborted")
            fflush(stdout)
            exit(70)
        }
    }
}
