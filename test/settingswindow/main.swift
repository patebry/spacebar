import AppKit

// The settings window, built and never shown: with Advanced open the page is taller than the window allows, so the window
// stops at its cap, stays on screen, and the page scrolls; closing Advanced shrinks the window back to the page.
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print((ok ? "PASS " : "FAIL ") + name + (ok ? "" : " " + detail()))
    if !ok { failures += 1 }
}
func spin() { for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) } }
func scrollView(in view: NSView) -> NSScrollView? { (view as? NSScrollView) ?? view.subviews.lazy.compactMap(scrollView).first }

func run() {
    _ = NSApplication.shared
    let store = SettingsStore()
    store.advancedExpanded = false
    let controller = SettingsWindowController(store: store, system: SystemStatus())
    let window = controller.window!
    spin()
    guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { print("SKIP no screen"); return }
    let cap = min(visible.height - 140, 900)
    let closed = window.contentLayoutRect.height

    store.advancedExpanded = true
    spin()
    let open = window.contentLayoutRect.height
    let scroll = scrollView(in: window.contentView!)
    let page = scroll?.documentView?.frame.height ?? 0
    let clip = scroll?.contentView.bounds.height ?? 0
    check("Advanced open: the page is taller than the window", page > open, "page \(page), window \(open)")
    check("Advanced open: the window stops at its cap", open <= cap + 0.5, "window \(open), cap \(cap)")
    check("Advanced open: the page scrolls", page > clip + 1 && clip > 0, "page \(page), visible \(clip)")
    check("Advanced open: the window is on screen", visible.contains(window.frame.insetBy(dx: 0.5, dy: 0.5)), "\(window.frame) in \(visible)")

    window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.maxY + 400))
    controller.fitWindow(animated: false)
    check("a window high on the screen keeps its title bar on it", window.frame.maxY <= visible.maxY + 0.5, "\(window.frame) in \(visible)")
    window.setFrameTopLeftPoint(NSPoint(x: visible.minX + 40, y: visible.minY + 300))
    controller.fitWindow(animated: false)
    check("a window low on the screen moves up rather than run off the bottom", window.frame.minY >= visible.minY - 0.5, "\(window.frame) in \(visible)")

    store.advancedExpanded = false
    spin()
    if closed < cap - 0.5 {
        check("Advanced closed: the window shrinks back", window.contentLayoutRect.height < open, "closed \(window.contentLayoutRect.height), open \(open)")
    }
    check("Advanced closed: the same height as before it opened", abs(window.contentLayoutRect.height - closed) < 1, "now \(window.contentLayoutRect.height), before \(closed)")
}

run()
print(failures == 0 ? "settings window ok" : "settings window: \(failures) failed")
exit(failures == 0 ? 0 : 1)
