import AppKit
import WebKit

/// An RTF or RTFD document, drawn by AppKit: a read-only NSTextView laid over the part of the web view the page reserves for it
/// (`.pdf-area`), placed by the same `pdfRect` messages as a PDF. The document never becomes HTML: AppKit's RTF reader builds
/// the attributed string (no web content, no script, no remote load), and an RTFD's pictures come from inside its package.
/// In a dark theme the text view maps the document's colours for a dark background, as TextEdit does.
final class RichTextPane: NSObject, NSTextViewDelegate, NativeDocument {
    let view: NSScrollView
    let textView: NSTextView
    private(set) var path: String?
    /// Whether the page has placed the view yet; it stays hidden until then, so it never shows at a stale position.
    private(set) var placed = false
    /// A link in the document. NSTextView's own open does nothing inside the sandbox, so the owner routes it.
    var onLink: (URL) -> Void = { _ in }
    static let inset = NSSize(width: 36, height: 28)
    /// The longest line, in points: on a wide panel the text is centred at this width, as the page's documents are.
    static let measure: CGFloat = 720
    private var matches: [NSRange] = []

    override init() {
        view = NSScrollView(frame: .zero)
        textView = NSTextView(frame: .zero)
        super.init()
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = false
        view.autohidesScrollers = true
        view.borderType = .noBorder
        view.drawsBackground = true
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.importsGraphics = false
        textView.allowsImageEditing = false
        textView.usesFindBar = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.displaysLinkToolTips = true
        textView.usesAdaptiveColorMappingForDarkAppearance = true
        // The scroll view draws the theme's background: the text view's own would be mapped for dark like the text is.
        textView.drawsBackground = false
        textView.textContainerInset = Self.inset
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.delegate = self
        view.documentView = textView
        view.allowsMagnification = true
        view.minMagnification = 0.5
        view.maxMagnification = 3
    }

    func find(_ query: String) -> Int {
        findClear()
        guard !query.isEmpty else { return 0 }
        let text = textView.string as NSString
        var at = 0
        while matches.count < maxMatches {
            let r = text.range(of: query, options: [.caseInsensitive], range: NSRange(location: at, length: text.length - at))
            guard r.location != NSNotFound, r.length > 0 else { break }
            matches.append(r)
            at = r.location + r.length
        }
        for r in matches { textView.layoutManager?.addTemporaryAttribute(.backgroundColor, value: NSColor.findHighlightColor.withAlphaComponent(0.45), forCharacterRange: r) }
        if !matches.isEmpty { findGo(0) }
        return matches.count
    }

    func findGo(_ i: Int) {
        guard matches.indices.contains(i) else { return }
        textView.setSelectedRange(matches[i])
        textView.scrollRangeToVisible(matches[i])
        textView.showFindIndicator(for: matches[i])
    }

    func findClear() {
        let all = NSRange(location: 0, length: (textView.string as NSString).length)
        textView.layoutManager?.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)
        matches = []
    }

    var selectedText: String? {
        let r = textView.selectedRange()
        guard r.length > 0, NSMaxRange(r) <= (textView.string as NSString).length else { return nil }
        return (textView.string as NSString).substring(with: r)
    }

    func zoom(_ key: String) {
        let m = key == "zoomIn" ? view.magnification * 1.1 : key == "zoomOut" ? view.magnification / 1.1 : 1
        view.magnification = min(max(m, view.minMagnification), view.maxMagnification)
        layout()
    }

    func scrollKey(_ key: String) -> Bool {
        switch key {
        case "pageup", "pagedown": scrollPage(view, down: key == "pagedown")
        case "home": textView.scrollToBeginningOfDocument(nil)
        case "end": textView.scrollToEndOfDocument(nil)
        default: return false
        }
        return true
    }

    enum LoadError: Error, Equatable { case unreadable, tooLarge }

    /// The whole of an RTFD package, pictures included, may be no larger than this.
    static let maxPackageBytes: Int64 = 256 << 20

    /// Reads `url` as RTF (an .rtf file) or RTFD (a package, or a flattened .rtfd file), downloading it from iCloud first.
    /// Only the RTF reader runs: a file that is really HTML or anything else is refused, never parsed as a web page.
    static func open(_ url: URL) -> Result<NSAttributedString, LoadError> {
        FileTypes.materializing {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return .failure(.unreadable) }
            if isDir.boolValue {
                guard url.pathExtension.lowercased() == "rtfd" else { return .failure(.unreadable) }
                guard packageBytes(url) <= maxPackageBytes else { return .failure(.tooLarge) }
                // Symbolic links in the package stay links: FileWrapper does not follow them.
                guard let w = try? FileWrapper(url: url, options: .immediate), w.isDirectory,
                      let s = NSAttributedString(rtfdFileWrapper: w, documentAttributes: nil) else { return .failure(.unreadable) }
                return .success(s)
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return .failure(.unreadable) }
            guard Int64(data.count) <= FolderListing.maxDocumentBytes else { return .failure(.tooLarge) }
            let s = url.pathExtension.lowercased() == "rtfd" ? NSAttributedString(rtfd: data, documentAttributes: nil)
                : data.starts(with: Array("{\\rtf".utf8)) ? NSAttributedString(rtf: data, documentAttributes: nil) : nil
            return s.map { .success($0) } ?? .failure(.unreadable)
        }
    }

    /// The bytes of the regular files in a package, not following links; stops counting once past the limit.
    static func packageBytes(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: []) else { return .max }
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
            total += Int64(v.fileSize ?? 0)
            if total > maxPackageBytes { break }
        }
        return total
    }

    /// Shows `text` for the file at `path`. The same file again (a change on disk) keeps the place on screen.
    func show(_ text: NSAttributedString, path: String) {
        let same = path == self.path
        let y = view.contentView.bounds.origin.y
        if !same { view.magnification = 1 }
        matches = []
        self.path = path
        textView.textStorage?.setAttributedString(text)
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        if placed { layout() }
        view.contentView.scroll(to: NSPoint(x: 0, y: same ? y : 0))
        view.reflectScrolledClipView(view.contentView)
    }

    private func layout() {
        // The clip view's width in the document's own points, which magnification changes.
        let width = view.contentView.bounds.width
        textView.textContainerInset = NSSize(width: max(Self.inset.width, ((width - Self.measure) / 2).rounded(.down)), height: Self.inset.height)
        textView.frame.size.width = width
        if let c = textView.textContainer { textView.layoutManager?.ensureLayout(for: c) }
        textView.sizeToFit()
    }

    /// A `pdfRect` message from the page: {path, x, y, w, h, hide, bg: [r, g, b], dark, radius}, for the file on screen only; `hide`
    /// with no rect means the page no longer shows it.
    func place(message b: [String: Any], in web: NSView) {
        func num(_ k: String) -> CGFloat? {
            guard let n = b[k] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
            return CGFloat(n.doubleValue)
        }
        let hide = (b["hide"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
        guard let p = b["path"] as? String, p == path else { return }
        guard let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h") else { return hide ? conceal() : () }
        let zoom = (web as? WKWebView).map { $0.pageZoom * $0.magnification } ?? 1
        if let bg = b["bg"] as? [NSNumber], bg.count == 3 {
            let c = bg.map { CGFloat(max(0, min(255, $0.doubleValue))) / 255 }
            style(background: NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1), dark: b["dark"] as? Bool == true)
        }
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius * zoom
        view.layer?.masksToBounds = radius > 0
        guard let f = PDFPane.frame(css: CGRect(x: x, y: y, width: w, height: h), in: web, zoom: zoom) else { view.isHidden = true; return }
        let resized = view.frame.size != f.size
        PDFPane.attach(view, frame: f, over: web)
        if resized || !placed { layout() }
        placed = true
        view.isHidden = hide
    }

    /// The page theme's background behind the text, and the appearance the text's colours are mapped for.
    func style(background: NSColor, dark: Bool) {
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.backgroundColor = background
    }

    func conceal() { view.isHidden = true }

    /// Takes the view down and lets the document go.
    func close() {
        matches = []
        view.magnification = 1
        textView.textStorage?.setAttributedString(NSAttributedString())
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        if let url = link as? URL ?? (link as? String).flatMap({ URL(string: $0) }) { onLink(url) }
        return true
    }

    /// An attachment (an RTFD's picture or file) is never opened from here.
    func textView(_ view: NSTextView, doubleClickedOn cell: NSTextAttachmentCellProtocol, in cellFrame: NSRect, at charIndex: Int) {}
}
