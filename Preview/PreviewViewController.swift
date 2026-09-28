import Cocoa
import QuickLookUI

/// The Quick Look extension's entry point: Quick Look's calls, mapped onto PreviewController.
@objc(PreviewViewController)
final class PreviewViewController: PreviewController, QLPreviewingController {
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        onReady = handler
        onDecline = { why in handler(CocoaError(.fileReadUnsupportedScheme, userInfo: [NSLocalizedDescriptionKey: why])) }
        _ = url.startAccessingSecurityScopedResource()
        start(url: url, reason: "prepare")
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        disableHostDoubleClick()
        hostWillAppear()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        disableHostDoubleClick()
        hostAppeared()
        #if PROBE
        Probe.windowAttached(view)
        #endif
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        hostDisappearing()
    }

    override func pageRendered() { disableHostDoubleClick() }

    /// Esc or Space in a list session gave the keys back to Quick Look, which closes on the next press.
    override func listSessionEnded(reason: String) {
        if reason == "escape" { status("Press Space again to close") }
    }

    #if PROBE
    override func makeRoot(frame: NSRect) -> NSView {
        let root = Probe.makeRoot(frame: frame)
        Probe.install()
        return root
    }

    override var prewarmsWriter: Bool { !Probe.has("noprewarm") }
    #endif

    /// Quick Look's service view controller hangs a two-click NSClickGestureRecognizer on an ancestor of this view. On a
    /// double-click it asks the host to open the file in its default app, and while it waits to see whether a click becomes a
    /// double-click it withholds the primary mouse events, so every click reached the web view one double-click interval late.
    /// Clicks in this preview mean edit, select or follow a link, so the recognizer is switched off.
    private func disableHostDoubleClick() {
        #if PROBE
        if Probe.has("nofix") { return }
        #endif
        var v: NSView? = view
        while let cur = v {
            for g in cur.gestureRecognizers {
                guard let click = g as? NSClickGestureRecognizer, click.numberOfClicksRequired >= 2, click.isEnabled else { continue }
                click.isEnabled = false
                log.info("disabled host double-click recognizer on \(NSStringFromClass(type(of: cur)), privacy: .public) (delayed primary clicks: \(click.delaysPrimaryMouseButtonEvents))")
            }
            v = cur.superview
        }
    }
}
