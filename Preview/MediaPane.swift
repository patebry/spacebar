import AppKit
import AVFoundation
import AVKit
import WebKit

/// A video or audio file on screen, played by AVKit: an AVPlayerView laid over the part of the panel the page reserves for it,
/// like PDFPane. A file opens paused on its first frame and never plays by itself. The player pauses and lets the file go when
/// another file is shown, the pane closes or the preview disappears, so nothing is heard once Quick Look closes.
///
/// An audio file shows its embedded artwork above the controls, else its Finder icon, on the page's backdrop colour, which also
/// covers AVKit's own audio placeholder. A change on disk reloads the file at the time it was at, playing again only if it was.
final class MediaPane: NSObject {
    let view: AVPlayerView
    let backdrop: NSView
    let art: NSImageView
    /// The file on screen, symlinks resolved as the sidebar lists it.
    private(set) var path: String?
    private(set) var placed = false
    private(set) var audio = false
    /// The file cannot be played (not media, or a codec AVFoundation lacks): the owner shows its info card instead.
    var onFailed: (String) -> Void = { _ in }
    /// What the file holds, for the kind line: a video's size and length, an audio file's title, artist and length.
    var onInfo: (String, String) -> Void = { _, _ in }
    private var infoTask: Task<Void, Never>?
    private var status: NSKeyValueObservation?
    private var resume: (time: CMTime, playing: Bool)?
    private var artTask: Task<Void, Never>?
    /// Where the art sits in the player: clear of the inline controls along the bottom.
    static let artInsets = NSEdgeInsets(top: 16, left: 16, bottom: 56, right: 16)
    static let maxArtBytes = 16 << 20

    override init() {
        view = AVPlayerView(frame: .zero)
        backdrop = NSView(frame: .zero)
        art = NSImageView(frame: .zero)
        super.init()
        view.controlsStyle = .inline
        // Never the Now Playing app: the keyboard's play key must not start a preview.
        view.updatesNowPlayingInfoCenter = false
        view.autoresizingMask = [.width, .height]
        view.isHidden = true
        backdrop.wantsLayer = true
        backdrop.autoresizingMask = [.width, .height]
        backdrop.isHidden = true
        art.imageScaling = .scaleProportionallyUpOrDown
        art.autoresizingMask = [.width, .height]
        backdrop.addSubview(art)
        (view.contentOverlayView ?? view).addSubview(backdrop)
    }

    /// Where a reload of the same file starts: the time it was at, unless that is at or past the new end (a shorter file starts
    /// over). Nil: from the start.
    static func resumeTime(_ t: CMTime, duration: CMTime) -> CMTime? {
        guard t.isNumeric, t.seconds > 0 else { return nil }
        if duration.isNumeric, t >= duration { return nil }
        return t
    }

    /// Shows `url` above `web`, paused on its first frame. The same file again (a change on disk) keeps its time and whether it played.
    /// The view joins the container only when the page places it: an AVPlayerView added at a zero size made the container
    /// grow to its minimum size (a video left within ~100 ms, before the page placed it, left the panel 50×43 points too big).
    func show(_ url: URL, audio: Bool, over web: NSView) {
        let old = view.player
        // A reload before the last one was ready keeps the time and state that one was waiting to restore.
        resume = url.path == path ? (resume ?? old.map { ($0.currentTime(), $0.rate != 0) }) : nil
        old?.pause()
        path = url.path
        self.audio = audio
        // A movie file can reference other files or URLs for its media (a QuickTime reference movie): none is followed.
        let asset = AVURLAsset(url: url, options: [AVURLAssetReferenceRestrictionsKey: AVAssetReferenceRestrictions.forbidAll.rawValue])
        let item = AVPlayerItem(asset: asset)
        let player = old ?? AVPlayer()
        player.actionAtItemEnd = .pause
        player.replaceCurrentItem(with: item)
        view.player = player
        view.showsFullScreenToggleButton = !audio
        status = item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
            DispatchQueue.main.async { self?.statusChanged(item) }
        }
        backdrop.isHidden = !audio
        artTask?.cancel()
        art.image = nil
        if audio { loadArt(item.asset, url) }
        loadInfo(asset, path: url.path, audio: audio)
    }

    private func loadInfo(_ asset: AVURLAsset, path: String, audio: Bool) {
        infoTask?.cancel()
        infoTask = Task { @MainActor [weak self] in
            guard let text = await Self.info(asset, audio: audio), !Task.isCancelled, let self, self.path == path else { return }
            self.onInfo(path, text)
        }
    }

    /// "1920 × 1080 · 0:06" for a video; "Title — Artist · 3:12" for audio, with whatever of those the file has.
    static func info(_ asset: AVAsset, audio: Bool) async -> String? {
        var parts: [String] = []
        if audio {
            let meta = (try? await asset.load(.commonMetadata)) ?? []
            func text(_ id: AVMetadataIdentifier) async -> String? {
                guard let item = AVMetadataItem.metadataItems(from: meta, filteredByIdentifier: id).first,
                      let s = try? await item.load(.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
                return String(s.prefix(120))
            }
            let title = await text(.commonIdentifierTitle), artist = await text(.commonIdentifierArtist)
            let named = [title, artist].compactMap { $0 }.joined(separator: " — ")
            if !named.isEmpty { parts.append(named) }
        } else if let track = try? await asset.loadTracks(withMediaType: .video).first,
                  let (size, t) = try? await track.load(.naturalSize, .preferredTransform) {
            let r = CGRect(origin: .zero, size: size).applying(t)
            if r.width >= 1, r.height >= 1 { parts.append("\(Int(abs(r.width).rounded())) × \(Int(abs(r.height).rounded()))") }
        }
        if let d = try? await asset.load(.duration), d.isNumeric, d.seconds > 0 { parts.append(duration(d.seconds)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// m:ss, or h:mm:ss from an hour.
    static func duration(_ seconds: Double) -> String {
        let t = Int(seconds.rounded()), h = t / 3600, m = t / 60 % 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func statusChanged(_ item: AVPlayerItem) {
        guard let player = view.player, player.currentItem === item, let path else { return }
        switch item.status {
        case .failed:
            // Both the initial and the change callback can read .failed by the time they run: report it once.
            guard status != nil else { return }
            status = nil
            log.error("media failed: \(String(describing: item.error), privacy: .public)")
            onFailed(path)
        case .readyToPlay:
            guard let r = resume else { return }
            resume = nil
            if let t = Self.resumeTime(r.time, duration: item.duration) { item.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero, completionHandler: nil) }
            if r.playing { player.play() }
        default: break
        }
    }

    /// The Finder icon at once, then the artwork embedded in the file when it has any.
    private func loadArt(_ asset: AVAsset, _ url: URL) {
        art.image = NSWorkspace.shared.icon(forFile: url.path)
        let path = url.path
        artTask = Task { @MainActor [weak self] in
            guard let data = await Self.artwork(asset), !Task.isCancelled, let self, self.path == path, !self.backdrop.isHidden,
                  let image = NSImage(data: data) else { return }
            self.art.image = image
        }
    }

    static func artwork(_ asset: AVAsset) async -> Data? {
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let d = try? await item.load(.dataValue), d.count <= maxArtBytes { return d }
        }
        return nil
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
            backdrop.layer?.backgroundColor = CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1)
        }
        let radius = num("radius").map { max(0, min(16, $0)) } ?? 0
        view.wantsLayer = true
        view.layer?.cornerRadius = radius * zoom
        view.layer?.masksToBounds = radius > 0
        guard let f = PDFPane.frame(css: CGRect(x: x, y: y, width: w, height: h), in: web, zoom: zoom) else { view.isHidden = true; return }
        PDFPane.attach(view, frame: f, over: web)
        view.layoutSubtreeIfNeeded()
        backdrop.frame = backdrop.superview?.bounds ?? view.bounds
        let i = Self.artInsets, host = backdrop.bounds
        art.frame = NSRect(x: i.left, y: i.bottom, width: max(0, host.width - i.left - i.right), height: max(0, host.height - i.top - i.bottom))
        placed = true
        view.isHidden = hide
    }

    func conceal() { view.isHidden = true }

    func pause() { view.player?.pause() }

    /// Stops playback, takes the view down and lets the file go.
    func close() {
        artTask?.cancel()
        infoTask?.cancel()
        status = nil
        resume = nil
        view.player?.pause()
        view.player?.replaceCurrentItem(with: nil)
        view.player = nil
        art.image = nil
        view.removeFromSuperview()
        view.isHidden = true
        path = nil
        placed = false
    }
}
