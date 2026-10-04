import AppKit
import ImageIO
import WebKit

/// An image WebKit does not decode reliably (HEIC, AVIF, TIFF, camera RAW, PSD, EXR, TGA, JPEG 2000, ICNS), decoded by ImageIO
/// and drawn in an NSImageView in a scroll view laid over the page's `.pdf-area`, like PDFPane. It behaves as the page's own
/// image viewer: fitted to the area, a double-click or a two-finger double tap toggles fitted and actual size about the point,
/// a pinch zooms about the pointer, two fingers or a drag move a zoomed image, ⌘+ ⌘− ⌘0 zoom and fit, and the zoom is reported
/// for the caption (`onZoom`). 100% is one image pixel per point, as `<img>`.
///
/// The first decode is sized for the screen; the whole image is decoded only once a zoom needs more pixels than that.
final class ImagePane: NSObject {
    enum LoadError: Error, Equatable { case unreadable }

    struct Loaded {
        let image: CGImage
        /// The image's size in pixels, EXIF orientation applied: its size at 100%.
        let size: CGSize
        /// Whether `image` has fewer pixels than `size` (a screen-sized first decode).
        let reduced: Bool
    }

    /// The longest side of the first decode, and of the whole-image decode a zoom may ask for (past it the image is upsampled).
    static let screenPixels = 2560
    static let maxPixels = 8192
    /// A file declaring more pixels than this is refused (a small, highly compressed file can declare gigapixels); the
    /// whole-image decode is held to `maxDecodeArea`.
    static let maxArea = 80_000_000
    static let maxDecodeArea = 40_000_000
    static let maxZoom: CGFloat = 8
    /// How long a double-click's or a key's zoom takes; none when the user asks for reduced motion.
    static var zoomDuration: TimeInterval = 0.18

    let view: NSScrollView
    let imageView: NSImageView
    /// The file the pane is for; `shownPath` once its image is on screen.
    private(set) var path: String?
    private var shownPath: String?
    private(set) var placed = false
    private(set) var size: CGSize = .zero
    /// Fitted to the area (the zoom follows a resize) rather than at a chosen zoom.
    private(set) var fitted = true
    private var reduced = false
    /// Bumped by every load and close: a decode that finishes after a newer one started is dropped.
    private var generation = 0
    /// The width in pixels of the decode on screen.
    private(set) var decodedWidth = 0
    private var upgrading = false
    private var lastPercent = -1
    /// Where an animated zoom is going, while it runs.
    private var goal: CGFloat?
    /// The page under the pane: a scroll over a fitted image scrolls it.
    weak var web: NSView?
    private var scrollMonitor: Any?
    /// The scroll under way, its momentum included, goes to the page: it began over the fitted image.
    private var scrollToPage = false
    /// The zoom, as a whole percentage, whenever it changes: the page shows it in the caption.
    var onZoom: (String, Int) -> Void = { _, _ in }
    /// ImageIO could not decode the file: the owner shows its info card instead.
    var onFailed: (String) -> Void = { _ in }

    override init() {
        view = ImageScrollView(frame: .zero)
        imageView = NSImageView(frame: .zero)
        super.init()
        view.contentView = CenteringClipView(frame: .zero)
        view.hasVerticalScroller = true
        view.hasHorizontalScroller = true
        view.autohidesScrollers = true
        view.borderType = .noBorder
        view.drawsBackground = true
        view.allowsMagnification = true
        view.usesPredominantAxisScrolling = false
        view.maxMagnification = Self.maxZoom
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageFrameStyle = .none
        imageView.isEditable = false
        imageView.animates = false
        view.documentView = imageView
        (view as? ImageScrollView)?.pane = self
        view.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: view.contentView)
        scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in self.map { $0.scrollWheel(e) } ?? e }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
    }

    /// Two fingers move a zoomed image and scroll the page under a fitted one; with ctrl a wheel zooms. Taken before the scroll
    /// view sees the event: a scroll view that overrides scrollWheel loses AppKit's responsive scrolling.
    private func scrollWheel(_ e: NSEvent) -> NSEvent? {
        guard path != nil, placed, !view.isHidden, let w = view.window, e.window === w else { return e }
        let over = view.bounds.contains(view.convert(e.locationInWindow, from: nil))
        if e.phase.contains(.began) || (e.phase.isEmpty && e.momentumPhase.isEmpty) { scrollToPage = over && fitted }
        if over, e.modifierFlags.contains(.control), e.momentumPhase.isEmpty {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 10
            zoom(by: exp(dy * 0.01), at: imageView.convert(e.locationInWindow, from: nil))
            return nil
        }
        guard scrollToPage, let web else { return e }
        web.scrollWheel(with: e)
        return nil
    }

    /// Where an image's bytes are: a file, or the bytes of a file inside an archive (ArchiveEntryView), already in memory.
    enum Source {
        case file(URL)
        case data(Data)

        func imageSource() -> CGImageSource? {
            let opts = [kCGImageSourceShouldCache: false] as CFDictionary
            switch self {
            case .file(let url): return CGImageSourceCreateWithURL(url as CFURL, opts)
            case .data(let d): return CGImageSourceCreateWithData(d as CFData, opts)
            }
        }
    }
    /// What the image at `sourcePath` was loaded from, for the whole-image decode a zoom asks for; any other path is a file.
    private var source: Source?
    private var sourcePath: String?

    /// The image at `url`, its primary picture (an icon file's largest), decoded off the main thread with EXIF orientation applied,
    /// its longest side at most `maxSide` pixels. Blocks: call it off the main thread.
    static func open(_ url: URL, maxSide: Int = screenPixels) -> Result<Loaded, LoadError> { open(.file(url), maxSide: maxSide) }

    static func open(_ source: Source, maxSide: Int = screenPixels) -> Result<Loaded, LoadError> {
        FileTypes.materializing {
            guard let src = source.imageSource(), CGImageSourceGetCount(src) > 0 else { return .failure(.unreadable) }
            let index = primaryIndex(src)
            guard let size = orientedSize(src, index), size.width >= 1, size.height >= 1 else { return .failure(.unreadable) }
            guard Int(size.width) * Int(size.height) <= maxArea else { return .failure(.unreadable) }
            let side = Int(max(size.width, size.height))
            let areaSide = Int(Double(side) * min(1, (Double(maxDecodeArea) / Double(size.width * size.height)).squareRoot()))
            let target = min(side, maxSide, max(areaSide, 1))
            let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                         kCGImageSourceThumbnailMaxPixelSize: target, kCGImageSourceShouldCacheImmediately: true]
            guard let image = CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary) else { return .failure(.unreadable) }
            return .success(Loaded(image: image, size: size, reduced: max(image.width, image.height) < min(side, maxPixels, areaSide)))
        }
    }

    /// The picture to show: the source's primary one, but the largest of an icon file's sizes.
    static func primaryIndex(_ src: CGImageSource) -> Int {
        let primary = CGImageSourceGetPrimaryImageIndex(src)
        let n = CGImageSourceGetCount(src)
        guard n > 1, (CGImageSourceGetType(src) as String?) == "com.apple.icns" else { return primary }
        let widths = (0..<n).map { (CGImageSourceCopyPropertiesAtIndex(src, $0, nil) as? [CFString: Any])?[kCGImagePropertyPixelWidth] as? Int ?? 0 }
        return widths.indices.max { widths[$0] < widths[$1] } ?? primary
    }

    /// Width and height in pixels as shown: EXIF orientations 5 to 8 turn the picture a quarter.
    static func orientedSize(_ src: CGImageSource, _ index: Int) -> CGSize? {
        guard let p = CGImageSourceCopyPropertiesAtIndex(src, index, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = p[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 && o <= 8 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Decodes `url` off the main thread, then shows it; the page lays out and paints meanwhile. The same file again (a change
    /// on disk) keeps the image on screen until the new one is decoded.
    func load(_ url: URL) { load(.file(url), path: url.path) }

    /// The same for an image already in memory, shown as `path` (the pane shows one image per path).
    func load(_ source: Source, path: String) {
        if path != shownPath { imageView.image = nil }
        self.path = path
        self.source = source
        sourcePath = path
        generation += 1
        lastPercent = -1
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async {
            let r = Self.open(source)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == gen, self.path == path else { return }
                switch r {
                case .success(let loaded): self.show(loaded, path: path)
                case .failure: self.onFailed(path)
                }
            }
        }
    }

    /// Width and height as shown, from the file's properties alone (nothing decoded); nil when ImageIO cannot read them.
    static func pixelSize(_ url: URL) -> CGSize? { pixelSize(.file(url)) }

    static func pixelSize(_ source: Source) -> CGSize? {
        FileTypes.materializing {
            guard let src = source.imageSource(), CGImageSourceGetCount(src) > 0 else { return nil }
            guard let s = orientedSize(src, primaryIndex(src)), Int(s.width) * Int(s.height) <= maxArea else { return nil }
            return s
        }
    }

    /// Shows `loaded`, the image at `path`. The same file again (a change on disk) keeps its zoom; another starts fitted.
    func show(_ loaded: Loaded, path: String) {
        let same = path == shownPath
        self.path = path
        shownPath = path
        size = loaded.size
        reduced = loaded.reduced
        upgrading = false
        imageView.image = NSImage(cgImage: loaded.image, size: loaded.size)
        decodedWidth = loaded.image.width
        imageView.frame = NSRect(origin: .zero, size: loaded.size)
        if !same { fitted = true; lastPercent = -1 }
        if placed { refit() }
    }

    /// What the image is scaled to when fitted: the whole of it in the area, never above its own size. The area is measured
    /// without scroll bars: a fitted image needs none, and legacy ones (a mouse, no trackpad) are shown until it is fitted.
    var fitScale: CGFloat {
        let area = NSScrollView.contentSize(forFrameSize: view.frame.size, horizontalScrollerClass: nil, verticalScrollerClass: nil,
                                            borderType: view.borderType, controlSize: .regular, scrollerStyle: view.scrollerStyle)
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return 1 }
        return min(1, area.width / size.width, area.height / size.height)
    }

    private func refit() {
        let fit = fitScale
        view.minMagnification = fit
        if fitted || view.magnification < fit { view.magnification = fit }
        report()
    }

    /// Zooms to `scale` (nil: fitted), keeping `point`, in the image view's coordinates, where it is; the middle of what is
    /// shown when nil.
    func zoom(to scale: CGFloat?, at point: NSPoint? = nil, animated: Bool = false) {
        guard path != nil else { return }
        let fit = fitScale
        let to = scale.map { min(Self.maxZoom, max(fit, $0)) } ?? fit
        let at = point ?? NSPoint(x: view.contentView.bounds.midX, y: view.contentView.bounds.midY)
        fitted = abs(to - fit) < 0.01
        let duration = animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? Self.zoomDuration : 0
        if duration > 0, abs(to - view.magnification) > 0.001 {
            goal = to
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().setMagnification(to, centeredAt: at)
            }, completionHandler: { [weak self] in
                guard let self, self.goal == to else { return }
                self.goal = nil
                self.report()
            })
        } else {
            goal = nil
            view.setMagnification(to, centeredAt: at)
        }
        report()
    }

    /// Double-click: fitted goes to actual size (twice that when actual size is about the fitted size), anything else to fitted.
    func toggle(at point: NSPoint) {
        let fit = fitScale
        zoom(to: fitted ? (fit < 0.8 ? 1 : min(Self.maxZoom, 2)) : nil, at: point, animated: true)
    }

    /// A wheel with ctrl: `factor` times the zoom, about `point`.
    func zoom(by factor: CGFloat, at point: NSPoint) {
        guard path != nil else { return }
        zoom(to: (goal ?? view.magnification) * factor, at: point)
    }

    /// One step of a pinch about `point`. It may go a little below fitted while the fingers are down, and springs back after.
    func pinch(_ delta: CGFloat, phase: NSEvent.Phase, at point: NSPoint) {
        guard path != nil else { return }
        let fit = fitScale
        if phase.contains(.ended) || phase.contains(.cancelled) {
            view.minMagnification = fit
            return zoom(to: view.magnification < fit + 0.005 ? nil : view.magnification, at: point, animated: true)
        }
        goal = nil
        view.minMagnification = fit * 0.8
        let to = min(Self.maxZoom, max(fit * 0.8, view.magnification * (1 + delta)))
        view.setMagnification(to, centeredAt: point)
        fitted = false
        if phase.isEmpty, to < fit { zoom(to: nil, at: point) }
        report()
    }

    /// ⌘+, ⌘− and ⌘0 (`key` zoomIn, zoomOut or zoomReset), about the middle of what is shown. Whether it applied.
    func key(_ key: String) -> Bool {
        guard path != nil, placed, !view.isHidden else { return false }
        let from = goal ?? view.magnification
        switch key {
        case "zoomIn": zoom(to: from * 1.25, animated: true)
        case "zoomOut": zoom(to: from / 1.25, animated: true)
        case "zoomReset": zoom(to: nil, animated: true)
        default: return false
        }
        return true
    }

    @objc private func boundsChanged() { report() }

    private func report() {
        guard let path, placed else { return }
        let percent = Int((view.magnification * 100).rounded())
        needsPixels()
        guard percent != lastPercent else { return }
        lastPercent = percent
        onZoom(path, percent)
    }

    /// Decodes the whole image once a zoom shows the first decode's pixels larger than the screen's.
    private func needsPixels() {
        guard reduced, !upgrading, let path else { return }
        let source = sourcePath == path ? self.source ?? .file(URL(fileURLWithPath: path)) : .file(URL(fileURLWithPath: path))
        let scale = view.window?.backingScaleFactor ?? 2
        guard view.magnification * scale * size.width > CGFloat(decodedWidth) * 1.05 else { return }
        upgrading = true
        let gen = generation
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let r = Self.open(source, maxSide: Self.maxPixels)
            DispatchQueue.main.async {
                guard let self, self.generation == gen, self.path == path, case .success(let full) = r, full.size == self.size else { return }
                self.reduced = false
                self.decodedWidth = full.image.width
                self.imageView.image = NSImage(cgImage: full.image, size: full.size)
            }
        }
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
        if let bg = b["bg"] as? [NSNumber], bg.count == 3 {
            let c = bg.map { CGFloat(max(0, min(255, $0.doubleValue))) / 255 }
            view.backgroundColor = NSColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        }
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius * zoom
        view.layer?.masksToBounds = radius > 0
        guard let f = PDFPane.frame(css: CGRect(x: x, y: y, width: w, height: h), in: web, zoom: zoom) else { view.isHidden = true; return }
        let resized = view.frame.size != f.size
        self.web = web
        PDFPane.attach(view, frame: f, over: web)
        if resized || !placed {
            placed = true
            view.layoutSubtreeIfNeeded()
            refit()
        }
        view.isHidden = hide
    }

    func conceal() { view.isHidden = true }

    /// Takes the view down and lets the image go.
    func close() {
        generation += 1
        (view as? ImageScrollView)?.endDrag()
        imageView.image = nil
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        source = nil
        sourcePath = nil
        shownPath = nil
        placed = false
        size = .zero
        reduced = false
        decodedWidth = 0
        upgrading = false
        fitted = true
        lastPercent = -1
        goal = nil
    }
}

/// Keeps an image smaller than the area in its middle rather than in the bottom-left corner.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var r = super.constrainBoundsRect(proposed)
        guard let doc = documentView else { return r }
        if r.width > doc.frame.width { r.origin.x = (doc.frame.width - r.width) / 2 }
        if r.height > doc.frame.height { r.origin.y = (doc.frame.height - r.height) / 2 }
        return r
    }
}

/// A double-click or a two-finger double tap toggles fitted and actual size; a drag moves a zoomed image (and is not a click).
final class ImageScrollView: NSScrollView {
    weak var pane: ImagePane?
    private var drag: (at: NSPoint, origin: NSPoint)?
    private var moved = false

    override func magnify(with e: NSEvent) {
        guard let pane, let doc = documentView else { return super.magnify(with: e) }
        pane.pinch(e.magnification, phase: e.phase, at: doc.convert(e.locationInWindow, from: nil))
    }

    override func smartMagnify(with e: NSEvent) {
        guard let pane, let doc = documentView else { return }
        pane.toggle(at: doc.convert(e.locationInWindow, from: nil))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        endDrag()
        drag = (e.locationInWindow, contentView.bounds.origin)
        moved = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag, pane?.fitted == false else { return }
        let dx = e.locationInWindow.x - d.at.x, dy = e.locationInWindow.y - d.at.y
        if !moved, hypot(dx, dy) < 4 { return }
        if !moved { moved = true; NSCursor.closedHand.push() }
        let m = magnification
        contentView.scroll(to: NSPoint(x: d.origin.x - dx / m, y: d.origin.y + (contentView.isFlipped ? dy : -dy) / m))
        reflectScrolledClipView(contentView)
    }

    override func viewWillMove(toWindow w: NSWindow?) {
        endDrag()
        super.viewWillMove(toWindow: w)
    }

    /// A pane closed mid-drag gets no mouse-up: its cursor is let go here.
    func endDrag() {
        if moved { NSCursor.pop() }
        drag = nil
        moved = false
    }

    override func mouseUp(with e: NSEvent) {
        defer { drag = nil; if moved { NSCursor.pop() }; moved = false }
        guard !moved, e.clickCount == 2, let pane, let doc = documentView else { return }
        pane.toggle(at: doc.convert(e.locationInWindow, from: nil))
    }
}
