import AppKit
import PDFKit
import WebKit

/// The PDF on screen, drawn by PDFKit: a PDFView laid over the part of the web view the page reserves for it (`.pdf-area`),
/// so the sidebar, breadcrumb and toolbar stay web content and WebKit's PDF plugin, with its unlabelled HUD, never loads. The
/// page reports that area in CSS pixels whenever it moves (`place`); between reports the view keeps its margins to the
/// container's edges, which is what the page's layout does while the panel is resized.
final class PDFPane: NSObject, PDFViewDelegate {
    enum LoadError: Error, Equatable { case unreadable, locked }

    let view: PDFView
    /// The file on screen, symlinks resolved as the sidebar lists it.
    private(set) var path: String?
    /// Whether the page has placed the view yet; it stays hidden until then, so it never shows at a stale position.
    private(set) var placed = false
    /// A link in the PDF. PDFView's own NSWorkspace open does nothing inside the sandbox, so the owner routes it.
    var onLink: (URL) -> Void = { _ in }

    override init() {
        view = PDFView(frame: .zero)
        super.init()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical
        view.displaysPageBreaks = true
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        view.delegate = self
    }

    /// Opens `url` for display. PDFKit runs no script in a PDF; a document it cannot parse, or one behind a password, is refused.
    static func open(_ url: URL) -> Result<PDFDocument, LoadError> {
        guard let doc = PDFDocument(url: url), doc.pageCount > 0 || doc.isLocked else { return .failure(.unreadable) }
        return doc.isLocked ? .failure(.locked) : .success(doc)
    }

    /// Shows `doc` above `web`, in `web`'s superview. The same file again (a change on disk) keeps the page that was on screen.
    func show(_ doc: PDFDocument, path: String, over web: NSView) {
        guard let container = web.superview else { return }
        if view.superview !== container {
            view.removeFromSuperview()
            container.addSubview(view, positioned: .above, relativeTo: web)
        }
        let keep = path == self.path ? view.currentPage.flatMap { view.document?.index(for: $0) } : nil
        self.path = path
        view.document = doc
        if let keep, keep < doc.pageCount, let page = doc.page(at: keep) { view.go(to: page) }
    }

    /// The view's frame in `web`'s superview for a rect in CSS pixels of the web view's viewport, clipped to the web view.
    static func frame(css r: CGRect, in web: NSView, zoom: CGFloat) -> NSRect? {
        guard [r.minX, r.minY, r.width, r.height, zoom].allSatisfy({ $0.isFinite }), zoom > 0, r.width > 0, r.height > 0,
              let container = web.superview else { return nil }
        let w = r.width * zoom, h = r.height * zoom
        let local = NSRect(x: r.minX * zoom, y: web.isFlipped ? r.minY * zoom : web.bounds.height - r.minY * zoom - h, width: w, height: h)
        let clipped = local.intersection(web.bounds)
        guard !clipped.isEmpty else { return nil }
        return web.convert(clipped, to: container)
    }

    /// Puts the view where the page reserved space. `hidden`: the page has something above that space for now.
    func place(css r: CGRect, in web: NSView, hidden: Bool) {
        guard path != nil else { return }
        let zoom = (web as? WKWebView).map { $0.pageZoom * $0.magnification } ?? 1
        guard let f = Self.frame(css: r, in: web, zoom: zoom) else { view.isHidden = true; return }
        view.frame = f
        placed = true
        view.isHidden = hidden
    }

    /// A `pdfRect` message from the page: {path, x, y, w, h, hide, bg: [r, g, b], dark, radius}. Only for the file on screen; a message
    /// with `hide` and no rect means no PDF is on the page any more.
    func place(message b: [String: Any], in web: NSView) {
        func num(_ k: String) -> CGFloat? {
            guard let n = b[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return CGFloat(n.doubleValue)
        }
        let hide = (b["hide"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        guard let p = b["path"] as? String, p == path else { return }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return hide ? conceal() : () }
        if let bg = b["bg"] as? [NSNumber], bg.count == 3 {
            let c = bg.map { CGFloat(max(0, min(255, $0.doubleValue))) / 255 }
            style(background: NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1), dark: b["dark"] as? Bool == true)
        }
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius * ((web as? WKWebView).map { $0.pageZoom * $0.magnification } ?? 1)
        view.layer?.masksToBounds = radius > 0
        place(css: CGRect(x: x, y: y, width: w, height: h), in: web, hidden: hide)
    }

    /// Hides the view without dropping the document (the page's popover, or a transition between two views).
    func conceal() { view.isHidden = true }

    /// The page theme's backdrop around the pages, and the matching appearance for the scrollers.
    func style(background: NSColor, dark: Bool) {
        view.backgroundColor = background
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    }

    /// Takes the view down and lets the document go, which closes the file.
    func close() {
        view.document = nil
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }

    func pdfViewWillClick(onLink sender: PDFView, with url: URL) { onLink(url) }

    /// Why a link in a PDF is not followed, or nil: web links only, and only what the link policy allows.
    static func linkRefusal(_ url: URL) -> String? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return "scheme \(url.scheme ?? "none")" }
        return LinkPolicy.refusal(url)
    }
    /// A link to another PDF file: not followed.
    func pdfViewOpenPDF(_ sender: PDFView, forRemoteGoToAction action: PDFActionRemoteGoTo) {}
}
