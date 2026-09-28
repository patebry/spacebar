import AppKit
import Quartz
import WebKit

/// A file spacebar has no view of its own for, but Apple's Quick Look previews (Office, iWork, fonts, 3D): a QLPreviewView laid
/// over the part of the panel the page reserves for it, like PDFPane. Only for the exact types in `FileTypes.appleQuickLookTypes`:
/// QLPreviewView hands a file to whichever extension Quick Look would pick, so a type spacebar claims would start a nested
/// spacebar inside the pane.
///
/// Apple's generators run in Quick Look's own daemons, which the sandbox reaches only through the mach-lookup exception in
/// build.sh. Without it, or for a file the generator cannot read, the view shows a generic icon: the owner then shows the info
/// card instead (`onFailed`).
final class QLFallbackPane: NSObject {
    let view: QLPreviewView
    /// The file on screen, symlinks resolved as the sidebar lists it.
    private(set) var path: String?
    private(set) var placed = false
    /// The file shows only Quick Look's generic icon: the owner shows its info card instead.
    var onFailed: (String) -> Void = { _ in }
    private var failureCheck: DispatchWorkItem?
    /// The view classes the failure check reads; a test stands in a timeline of trees.
    var inspect: (NSView) -> [String] = QLFallbackPane.classNames
    /// When the view is first looked at after it is placed (Apple's generators answered within 0.3 s in the spike), how often
    /// again while Quick Look is still loading (a damaged 2 MB document reached the generic icon only after 2.2 s), and when it
    /// stops looking.
    static let failureDelay: TimeInterval = 1.5
    static let failurePoll: TimeInterval = 0.5
    static let failureGiveUp: TimeInterval = 20

    /// What a QLPreviewView's subtree shows.
    enum Shown: Equatable { case preview, genericIcon, loading }

    init?(frame: NSRect = .zero) {
        guard let v = QLPreviewView(frame: frame, style: .normal) else { return nil }
        view = v
        super.init()
        // Closed by `close`, not by the window: Quick Look reuses the extension's window across previews.
        view.shouldCloseWithWindow = false
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
    }

    /// Shows `url`. The same file again (a change on disk) is read again in place. The view joins the container only when the
    /// page places it (PDFPane.attach).
    func show(_ url: URL) {
        if url.path == path, view.previewItem != nil {
            view.refreshPreviewItem()
            if placed { scheduleFailureCheck() }
            return
        }
        path = url.path
        failureCheck?.cancel()
        failureCheck = nil
        view.previewItem = url as NSURL
        if placed { scheduleFailureCheck() }
    }

    /// A `pdfRect` message from the page, as PDFPane takes it.
    func place(message b: [String: Any], in web: NSView) {
        func num(_ k: String) -> CGFloat? {
            guard let n = b[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return CGFloat(n.doubleValue)
        }
        let hide = (b["hide"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        guard let p = b["path"] as? String, p == path else { return }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return hide ? conceal() : () }
        let zoom = (web as? WKWebView).map { $0.pageZoom * $0.magnification } ?? 1
        view.appearance = NSAppearance(named: b["dark"] as? Bool == true ? .darkAqua : .aqua)
        view.wantsLayer = true
        if let bg = b["bg"] as? [NSNumber], bg.count == 3 {
            let c = bg.map { CGFloat(max(0, min(255, $0.doubleValue))) / 255 }
            view.layer?.backgroundColor = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        }
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.layer?.cornerRadius = radius * zoom
        view.layer?.masksToBounds = radius > 0
        guard let f = PDFPane.frame(css: CGRect(x: x, y: y, width: w, height: h), in: web, zoom: zoom) else { view.isHidden = true; return }
        PDFPane.attach(view, frame: f, over: web)
        if !placed {
            placed = true
            scheduleFailureCheck()
        }
        view.isHidden = hide
    }

    /// Quick Look loads a preview only once the view is in a window, so the check counts from the first place. It looks again
    /// while the view is still loading, until the preview or the generic icon shows, or it gives up.
    private func scheduleFailureCheck(after delay: TimeInterval = QLFallbackPane.failureDelay, started: Date = Date()) {
        failureCheck?.cancel()
        let checked = path
        let item = DispatchWorkItem { [weak self] in
            guard let self, let checked, self.path == checked, self.view.superview != nil else { return }
            self.failureCheck = nil
            let names = self.inspect(self.view)
            switch Self.shown(classNames: names) {
            case .preview: return
            case .loading:
                guard Date().timeIntervalSince(started) < Self.failureGiveUp else { return }
                self.scheduleFailureCheck(after: Self.failurePoll, started: started)
            case .genericIcon:
                log.error("quick look fallback showed a generic icon: \(names.joined(separator: " "), privacy: .public)")
                self.onFailed(checked)
            }
        }
        failureCheck = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// The class of every view under `root`, depth first.
    static func classNames(_ root: NSView) -> [String] {
        var out: [String] = []
        var stack = [root]
        while let v = stack.popLast(), out.count < 200 {
            out.append(NSStringFromClass(type(of: v)))
            stack.append(contentsOf: v.subviews.reversed())
        }
        return out
    }

    /// What a QLPreviewView's subtree shows. Measured on macOS 15.4: a preview is a web view (Office, iWork), a PDF view
    /// (PowerPoint), a text view, or a remote view (fonts, 3D); a denied or failed generator leaves an empty
    /// QLLayerBasedPreviewContainerView; anything else (QLLoadingView and its spinner, no container yet) is still loading.
    static func shown(classNames names: [String]) -> Shown {
        let content = ["QLWeb2View", "WKWebView", "WKFlippedView", "QLPDFContainerView", "PDFView", "QLTextView", "NSTextView", "NSRemoteView"]
        if names.contains(where: { n in content.contains { n.hasSuffix($0) } }) { return .preview }
        return names.contains("QLLayerBasedPreviewContainerView") ? .genericIcon : .loading
    }

    func conceal() { view.isHidden = true }

    /// Takes the view down and lets the file go. The pane is not used again.
    func close() {
        failureCheck?.cancel()
        failureCheck = nil
        view.close()
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }
}
