import AppKit
import SwiftUI

/// The settings window: one page at a fixed width, with a height that follows it (Advanced opening and closing, a notice
/// appearing) up to what the screen allows; past that the page scrolls.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let host: NSHostingController<AnyView>
    private var pageObserver: NSObjectProtocol?

    init(store: SettingsStore, system: SystemStatus) {
        self.store = store
        host = NSHostingController(rootView: AnyView(SettingsPane().environmentObject(store).environmentObject(system)))
        // No sizing options: with .preferredContentSize the hosting view takes the page's whole height, so the window outgrows
        // the screen and the page never scrolls. The height comes from the page's scroll view instead (pageHeight).
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "spacebar Settings"
        super.init(window: window)
        window.delegate = self
        host.view.layoutSubtreeIfNeeded()
        if let page = Self.scrollView(in: host.view)?.documentView {
            page.postsFrameChangedNotifications = true
            pageObserver = NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: page, queue: .main) { [weak self] _ in
                // Posted inside SwiftUI's layout pass; an animated resize there would block it, once per frame change.
                DispatchQueue.main.async { self?.fitWindow(animated: self?.window?.isVisible == true) }
            }
        }
        fitWindow(animated: false)
        window.center()
        window.setFrameAutosaveName("Settings")
        // A saved frame can be taller than the page or the screen allows.
        fitWindow(animated: false)
    }

    deinit { pageObserver.map(NotificationCenter.default.removeObserver) }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first
    }

    /// The page's full height: the Form's scroll view holds all of it.
    private var pageHeight: CGFloat? {
        guard let height = Self.scrollView(in: host.view)?.documentView?.frame.height, height > 0 else { return nil }
        return height
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ tab: SettingsTab) {
        store.revealAdvanced(tab.opensAdvanced)
    }

    /// Resizes the window to the page's natural height, keeping its top edge where it is unless that puts the bottom off screen.
    func fitWindow(animated: Bool) {
        guard let window else { return }
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame
        let screen = visible?.height ?? 800
        let natural = pageHeight ?? 600
        let height = min(max(natural, 200), screen - 140, 900)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: paneWidth, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible {
            if frame.maxY > visible.maxY { frame.origin.y = visible.maxY - frame.height }
            if frame.minY < visible.minY { frame.origin.y = min(visible.minY, visible.maxY - frame.height) }
        }
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated)
    }
}
