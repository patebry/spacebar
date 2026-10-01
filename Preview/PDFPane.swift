import AppKit
import PDFKit
import WebKit

/// A document drawn natively over the page (a PDF, an RTF document) that the panel's keys reach: find with the page's find bar,
/// ⌘+ ⌘− ⌘0, Page Up and Page Down, and ⌘C of what is selected in it.
protocol NativeDocument: AnyObject {
    var path: String? { get }
    /// Finds `query` (case-insensitive), shows the first match and calls `done` on the main thread with how many there are (at
    /// most `maxMatches`). A find started after it, or findClear, means `done` is never called.
    func find(_ query: String, done: @escaping (Int) -> Void)
    /// Shows match `i` of the last find.
    func findGo(_ i: Int)
    func findClear()
    /// The text selected in the document, if any.
    var selectedText: String? { get }
    /// zoomIn, zoomOut or zoomReset.
    func zoom(_ key: String)
    /// pageup, pagedown, home or end; whether the key moved the document.
    func scrollKey(_ key: String) -> Bool
}

let maxMatches = 10_000

/// Scrolls `sv` by most of a screen: Page Up and Page Down as in Preview.
func scrollPage(_ sv: NSScrollView, down: Bool) {
    let clip = sv.contentView, d = clip.bounds.height * 0.9
    var o = clip.bounds.origin
    o.y += down == (sv.documentView?.isFlipped ?? true) ? d : -d
    clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: o, size: clip.bounds.size)).origin)
    sv.reflectScrolledClipView(clip)
}

/// The PDF on screen, drawn by PDFKit: a PDFView laid over the part of the web view the page reserves for it (`.pdf-area`),
/// so the sidebar, breadcrumb and toolbar stay web content and WebKit's PDF plugin, with its unlabelled HUD, never loads. The
/// page reports that area in CSS pixels whenever it moves (`place`); between reports the view keeps its margins to the
/// container's edges, which is what the page's layout does while the panel is resized.
final class PDFPane: NSObject, PDFViewDelegate, PDFDocumentDelegate, NativeDocument {
    enum LoadError: Error, Equatable { case unreadable, locked }

    let view: PDFView
    /// The file on screen, symlinks resolved as the sidebar lists it.
    private(set) var path: String?
    /// Whether the page has placed the view yet; it stays hidden until then, so it never shows at a stale position.
    private(set) var placed = false
    /// The page to go to once the view has a frame: the first for a new document, the one on screen for a reload.
    private var pendingPage: Int?
    /// A link in the PDF. PDFView's own NSWorkspace open does nothing inside the sandbox, so the owner routes it.
    var onLink: (URL) -> Void = { _ in }
    /// The page on screen changed: the file, the page (from 1) and how many there are.
    var onPage: (String, Int, Int) -> Void = { _, _, _ in }
    private var matches: [PDFSelection] = []
    /// The find running in the background (PDFKit's own thread), and what to call when it ends.
    private var finding: (doc: PDFDocument, found: [PDFSelection], done: (Int) -> Void)?
    private var reported: (path: String, page: Int, pages: Int)?
    private var scrollWatch: NSObjectProtocol?

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
        NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: view, queue: .main) { [weak self] _ in self?.reportPage() }
    }

    /// The page last reported for the file on screen, from 1.
    var shownPage: Int? { reported.flatMap { $0.path == path ? $0.page : nil } }

    func reportPage() {
        // The page a third of the way down the view: PDFView's currentPage moves on only as it draws.
        let at = NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.height / 3 : view.bounds.height * 2 / 3)
        guard let p = path, let doc = view.document, let page = view.page(for: at, nearest: true) ?? view.currentPage else { return }
        let i = doc.index(for: page)
        guard i != NSNotFound, reported.map({ $0 != (p, i + 1, doc.pageCount) }) ?? true else { return }
        reported = (p, i + 1, doc.pageCount)
        onPage(p, i + 1, doc.pageCount)
    }

    /// Every scroll, however it is made: PDFView tells of a new page only as it draws.
    private func watchScrolling() {
        guard scrollWatch == nil, let clip = view.documentView?.enclosingScrollView?.contentView else { return }
        clip.postsBoundsChangedNotifications = true
        scrollWatch = NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            self?.reportPage()
        }
    }

    /// Page `n`, from 1, at its top.
    func go(toPage n: Int) {
        guard let doc = view.document, doc.pageCount > 0, let page = doc.page(at: min(max(n, 1), doc.pageCount) - 1) else { return }
        let top = page.bounds(for: view.displayBox)
        view.go(to: PDFDestination(page: page, at: NSPoint(x: top.minX, y: top.maxY)))
    }

    /// A long PDF takes seconds to search: the search runs off the main thread, so the panel never stalls on a keystroke.
    func find(_ query: String, done: @escaping (Int) -> Void) {
        findClear()
        guard !query.isEmpty, let doc = view.document else { return done(0) }
        finding = (doc, [], done)
        doc.delegate = self
        doc.beginFindString(query, withOptions: [.caseInsensitive])
    }

    func didMatchString(_ instance: PDFSelection) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.didMatchString(instance) } }
        guard var f = finding, instance.pages.first?.document === f.doc else { return }
        f.found.append(instance)
        finding = f
        if f.found.count >= maxMatches { f.doc.cancelFindString(); endFind() }
    }

    func documentDidEndDocumentFind(_ notification: Notification) {
        guard Thread.isMainThread else { return DispatchQueue.main.async { self.documentDidEndDocumentFind(notification) } }
        guard let f = finding, notification.object as? PDFDocument === f.doc else { return }
        endFind()
    }

    private func endFind() {
        guard let f = finding else { return }
        finding = nil
        guard view.document === f.doc else { return }
        matches = f.found
        for m in matches { m.color = NSColor.findHighlightColor.withAlphaComponent(0.45) }
        view.highlightedSelections = matches.isEmpty ? nil : matches
        if !matches.isEmpty { findGo(0) }
        f.done(matches.count)
    }

    func findGo(_ i: Int) {
        guard matches.indices.contains(i) else { return }
        view.setCurrentSelection(matches[i], animate: false)
        view.go(to: matches[i])
    }

    func findClear() {
        if let f = finding { finding = nil; f.doc.cancelFindString() }
        if !matches.isEmpty { view.clearSelection() }
        matches = []
        view.highlightedSelections = nil
    }

    var selectedText: String? { view.currentSelection?.string.flatMap { $0.isEmpty ? nil : $0 } }

    func zoom(_ key: String) {
        switch key {
        case "zoomIn": view.zoomIn(nil)
        case "zoomOut": view.zoomOut(nil)
        default: view.autoScales = true
        }
    }

    func scrollKey(_ key: String) -> Bool {
        switch key {
        case "pageup", "pagedown":
            guard let sv = view.documentView?.enclosingScrollView else { return false }
            scrollPage(sv, down: key == "pagedown")
        case "home": view.goToFirstPage(nil)
        case "end": view.goToLastPage(nil)
        default: return false
        }
        return true
    }

    /// Opens `url` for display. PDFKit runs no script in a PDF; a document it cannot parse, or one behind a password, is refused.
    static func open(_ url: URL) -> Result<PDFDocument, LoadError> {
        guard let doc = FileTypes.materializing({ PDFDocument(url: url) }), doc.pageCount > 0 || doc.isLocked else { return .failure(.unreadable) }
        return doc.isLocked ? .failure(.locked) : .success(doc)
    }

    /// Shows `doc` above `web`, in `web`'s superview, from the top of its first page. The same file again (a change on disk)
    /// keeps the page that was on screen. The view joins the container only when the page first places it (see attach).
    func show(_ doc: PDFDocument, path: String, over web: NSView) {
        let keep = path == self.path ? view.currentPage.flatMap { view.document?.index(for: $0) } : nil
        matches = []
        reported = nil
        if path != self.path { view.autoScales = true }
        self.path = path
        view.document = doc
        pendingPage = keep ?? 0
        // Laid out at a zero size, PDFView keeps the scroll position that size gives, the end of the document: the page is
        // chosen again once the view has its frame.
        if placed { goToPendingPage() }
    }

    private func goToPendingPage() {
        guard let i = pendingPage, let doc = view.document else { return }
        pendingPage = nil
        view.layoutDocumentView()
        guard let page = doc.page(at: min(i, max(0, doc.pageCount - 1))) else { return }
        let top = page.bounds(for: view.displayBox)
        view.go(to: PDFDestination(page: page, at: NSPoint(x: top.minX, y: top.maxY)))
        reportPage()
    }

    /// Puts a native view over `web` at `frame`, adding it to `web`'s superview only now, with its frame already set. A view
    /// added before it has one (AVPlayerView above all) can make the container grow to fit its minimum size.
    static func attach(_ v: NSView, frame f: NSRect, over web: NSView) {
        guard let container = web.superview else { return }
        if v.superview !== container {
            v.removeFromSuperview()
            v.frame = f
            container.addSubview(v, positioned: .above, relativeTo: web)
        } else {
            v.frame = f
        }
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
        let keep = placed && pendingPage == nil && view.frame.size != f.size ? anchor() : nil
        Self.attach(view, frame: f, over: web)
        placed = true
        watchScrolling()
        if let keep { restore(keep) }
        goToPendingPage()
        view.isHidden = hidden
    }

    /// The page at the top of the view and how far down it the view starts, in page points, which a new width does not change.
    /// Autoscaled to a new width, PDFView keeps its scroll offset instead, so the same place on the page moves.
    private func anchor() -> (page: Int, below: CGFloat)? {
        let top = NSPoint(x: view.bounds.midX, y: view.isFlipped ? view.bounds.minY : view.bounds.maxY)
        guard let doc = view.document, let page = view.page(for: top, nearest: true) else { return nil }
        let i = doc.index(for: page)
        guard i != NSNotFound else { return nil }
        return (i, max(0, page.bounds(for: view.displayBox).maxY - view.convert(top, to: page).y))
    }

    private func restore(_ a: (page: Int, below: CGFloat)) {
        guard let page = view.document?.page(at: a.page) else { return }
        view.layoutDocumentView()
        let b = page.bounds(for: view.displayBox)
        view.go(to: PDFDestination(page: page, at: NSPoint(x: b.minX, y: b.maxY - a.below)))
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
        matches = []
        view.highlightedSelections = nil
        view.document = nil
        pendingPage = nil
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
