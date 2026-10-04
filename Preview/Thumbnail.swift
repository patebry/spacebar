import AppKit
import ImageIO
import QuickLookThumbnailing
import UniformTypeIdentifiers

/// Apple's own thumbnail of a file, as Finder draws it large (a Keynote slide, an app's icon, a document's first page), for the
/// info card of a file the panel does not otherwise show.
enum Thumbnail {
    static let maxBytes = 2 << 20
    static let points: CGFloat = 512

    /// A PNG data: URL of `url`'s thumbnail at 512 points, 2x (1x when that is over 2 MB), or nil: no thumbnail, or none within
    /// `timeout`. `icon`: the file's icon will do (an app has no other picture); else a generic document icon is no thumbnail.
    /// Blocks; call it off the main thread.
    static func dataURL(_ url: URL, icon: Bool = false, timeout: TimeInterval = 3) -> String? {
        let deadline = DispatchTime.now() + timeout
        for scale in [2, 1] as [CGFloat] {
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: points, height: points), scale: scale, representationTypes: icon ? .all : .thumbnail)
            let done = DispatchSemaphore(value: 0)
            var image: CGImage?
            QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
                image = rep?.cgImage
                done.signal()
            }
            guard done.wait(timeout: deadline) == .success else {
                QLThumbnailGenerator.shared.cancel(req)
                return nil
            }
            guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return nil }
            let s = "data:image/png;base64," + png.base64EncodedString()
            if s.utf8.count <= maxBytes { return s }
        }
        return nil
    }
}

/// The folder grid's thumbnails, served to the page by SchemeHandler's `thumb` host. Each is made off the main thread when the
/// page asks (it asks only for the tiles in view), a few at a time (`defaultConcurrency`), oldest request first; a request the
/// page drops before its turn is never made. Images are decoded by ImageIO in this process under the image view's bounds
/// (ImagePane), from a descriptor whose real path is checked to be inside the root; video and SVG go to QuickLookThumbnailing,
/// whose generators run in Quick Look's daemons. A file iCloud has evicted gets none (making one would download it). The
/// result is a small JPEG (PNG when it has transparency), encoded in memory and kept in a capped cache emptied under memory
/// pressure: nothing is written to disk.
final class ThumbnailPipeline {
    struct Thumb { let data: Data; let mime: String }
    /// `stamp` is the file's version as its listing saw it (size and modification time), so a changed file is made again;
    /// `root` is the resolved folder the file must still be inside when it is read.
    struct Key: Hashable { let path: String; let root: String; let stamp: String; let px: Int }
    typealias Maker = (_ key: Key, _ cancelled: @escaping () -> Bool) -> Thumb?
    struct Stats: Equatable { var made = 0, failed = 0, hits = 0, dropped = 0, abandoned = 0, evicted = 0 }

    /// The sizes, in pixels on the longest side, a thumbnail is made at: a request is rounded up to one of them.
    static let sizes = [128, 256, 384, 512]
    static let jpegQuality = 0.8
    static let qlTimeout: TimeInterval = 5

    static let shared = ThumbnailPipeline()

    let maxConcurrent: Int
    let maxCacheBytes: Int
    let maxCacheCount: Int
    private let make: Maker
    private let work = DispatchQueue(label: "md.spacebar.thumbs", qos: .userInitiated, attributes: .concurrent)

    // Main thread only, from here to `stats`.
    private final class Job {
        let key: Key
        var waiters: [Int: (Thumb?) -> Void] = [:]
        let flag = Flag()
        init(key: Key) { self.key = key }
    }
    private var cache: [Key: (thumb: Thumb, used: Int)] = [:]
    private var cacheBytes = 0
    private var clock = 0
    private var jobs: [Key: Job] = [:]
    private var queue: [Job] = []
    private var head = 0
    private var running = 0
    private var tickets = 0
    private var ticketKey: [Int: Key] = [:]
    private(set) var stats = Stats()
    private(set) var peakRunning = 0
    private var pressure: DispatchSourceMemoryPressure?

    /// A first row of five or six tiles made in one round, leaving the machine a couple of cores.
    static let defaultConcurrency = min(6, max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    init(maxConcurrent: Int = defaultConcurrency, maxCacheBytes: Int = 48 << 20, maxCacheCount: Int = 4000, make: @escaping Maker = ThumbnailPipeline.makeThumb) {
        self.maxConcurrent = maxConcurrent
        self.maxCacheBytes = maxCacheBytes
        self.maxCacheCount = maxCacheCount
        self.make = make
        let src = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        src.setEventHandler { [weak self] in self?.purge() }
        src.resume()
        pressure = src
    }

    deinit { pressure?.cancel() }

    static func size(for requested: Int) -> Int { sizes.first { $0 >= requested } ?? sizes.last! }

    var cachedCount: Int { cache.count }
    var cachedBytes: Int { cacheBytes }
    var pending: Int { queue.count - head }

    /// The thumbnail of `path`, inside the resolved folder `root`, at about `px` pixels: `done` runs on the main thread, at once
    /// from the cache or once it is made (nil when there is none). Returns a ticket for `cancel`, or nil when `done` has run.
    @discardableResult
    func request(path: String, root: String, stamp: String, px: Int, done: @escaping (Thumb?) -> Void) -> Int? {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Key(path: path, root: root, stamp: stamp, px: Self.size(for: px))
        if let hit = cache[key] {
            clock += 1
            cache[key]?.used = clock
            stats.hits += 1
            done(hit.thumb)
            return nil
        }
        tickets += 1
        let t = tickets
        ticketKey[t] = key
        if let job = jobs[key] {
            job.waiters[t] = done
        } else {
            let job = Job(key: key)
            job.waiters[t] = done
            jobs[key] = job
            queue.append(job)
            pump()
        }
        return t
    }

    /// Ticket `t` is no longer wanted (its tile scrolled away): a job no one waits for is dropped before it starts, and one
    /// already running is told to stop (a Quick Look request is cancelled; an ImageIO decode finishes and is cached).
    func cancel(_ t: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let key = ticketKey.removeValue(forKey: t), let job = jobs[key] else { return }
        job.waiters[t] = nil
        guard job.waiters.isEmpty else { return }
        jobs[key] = nil
        job.flag.set()
    }

    private func pump() {
        while running < maxConcurrent, head < queue.count {
            let job = queue[head]
            head += 1
            if head > 256, head * 2 > queue.count { queue.removeFirst(head); head = 0 }
            if job.flag.isSet { stats.dropped += 1; continue }
            // Made meanwhile by a job that was cancelled while it ran (an ImageIO decode finishes and is kept).
            if let hit = cache[job.key] {
                stats.hits += 1
                if jobs[job.key] === job { jobs[job.key] = nil }
                deliver(job, hit.thumb)
                continue
            }
            running += 1
            peakRunning = max(peakRunning, running)
            let make = self.make, key = job.key, flag = job.flag
            work.async { [weak self] in
                let thumb = flag.isSet ? nil : make(key, { flag.isSet })
                DispatchQueue.main.async { self?.finished(job, thumb) }
            }
        }
    }

    private func finished(_ job: Job, _ thumb: Thumb?) {
        running -= 1
        if let thumb {
            stats.made += 1
            store(job.key, thumb)
        } else if job.flag.isSet {
            stats.abandoned += 1
        } else {
            stats.failed += 1
        }
        if jobs[job.key] === job { jobs[job.key] = nil }
        deliver(job, thumb)
        pump()
    }

    private func deliver(_ job: Job, _ thumb: Thumb?) {
        let waiters = job.waiters.sorted { $0.key < $1.key }
        job.waiters = [:]
        for (t, done) in waiters {
            ticketKey[t] = nil
            done(thumb)
        }
    }

    private func store(_ key: Key, _ thumb: Thumb) {
        guard thumb.data.count <= maxCacheBytes / 8 else { return }
        clock += 1
        if let old = cache[key] { cacheBytes -= old.thumb.data.count }
        cache[key] = (thumb, clock)
        cacheBytes += thumb.data.count
        guard cacheBytes > maxCacheBytes || cache.count > maxCacheCount else { return }
        // Down to three quarters of each cap, least recently used first, so a long scroll does not evict on every thumbnail.
        for (k, v) in cache.sorted(by: { $0.value.used < $1.value.used }) {
            if cacheBytes <= maxCacheBytes * 3 / 4 && cache.count <= maxCacheCount * 3 / 4 { break }
            cache[k] = nil
            cacheBytes -= v.thumb.data.count
            stats.evicted += 1
        }
    }

    func purge() {
        cache = [:]
        cacheBytes = 0
    }

    /// A thumbnail of the key's file at most `px` pixels on its longest side, or nil. Blocks: call it off the main thread.
    static func makeThumb(_ key: Key, cancelled: @escaping () -> Bool) -> Thumb? {
        let ext = (key.path as NSString).pathExtension.lowercased()
        guard !FileTypes.isDataless(key.path) else { return nil }
        let image: CGImage?
        if FileTypes.imageExtensions.contains(ext), ext != "svg" {
            image = read(key.path, inside: key.root).flatMap { imageIO($0, px: key.px) }
        } else {
            // Quick Look opens the file itself: it gets the path resolved and checked now.
            guard let real = FolderListing.realPath(key.path), real.hasPrefix(key.root == "/" ? "/" : key.root + "/") else { return nil }
            image = quickLook(URL(fileURLWithPath: real), px: key.px, cancelled: cancelled)
        }
        guard let image, !cancelled() else { return nil }
        return encode(image)
    }

    /// The bytes of the regular file at `path` when the file actually opened is inside `root` (its real path, read from the
    /// open descriptor, so a link swapped in after the listing's check leads nowhere) and within the image size limit.
    static func read(_ path: String, inside root: String) -> Data? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        var st = stat()
        guard fcntl(fd, F_GETPATH, &buf) != -1, String(cString: buf).hasPrefix(root == "/" ? "/" : root + "/"),
              fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int64(st.st_size) <= FileTypes.maxImageBytes else { return nil }
        return try? h.read(upToCount: Int(FileTypes.maxImageBytes))
    }

    /// ImageIO's thumbnail of an image's bytes, EXIF orientation applied. As in the image view, an image declaring more than
    /// ImagePane.maxArea pixels is not decoded.
    static func imageIO(_ data: Data, px: Int) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(src) > 0 else { return nil }
        let index = ImagePane.primaryIndex(src)
        guard let size = ImagePane.orientedSize(src, index), size.width >= 1, size.height >= 1,
              Int(size.width) * Int(size.height) <= ImagePane.maxArea else { return nil }
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                                     kCGImageSourceThumbnailMaxPixelSize: min(px, Int(max(size.width, size.height))),
                                     kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateThumbnailAtIndex(src, index, opts as CFDictionary)
    }

    /// Quick Look's thumbnail (a video's frame, an SVG), made in its daemons; nil when there is none within `qlTimeout`, or the
    /// request is cancelled meanwhile.
    static func quickLook(_ url: URL, px: Int, cancelled: @escaping () -> Bool) -> CGImage? {
        let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: px, height: px), scale: 1, representationTypes: .thumbnail)
        let done = DispatchSemaphore(value: 0)
        let box = ImageBox()
        QLThumbnailGenerator.shared.generateBestRepresentation(for: req) { rep, _ in
            box.image = rep?.cgImage
            done.signal()
        }
        let deadline = Date().addingTimeInterval(qlTimeout)
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            if cancelled() || Date() > deadline {
                QLThumbnailGenerator.shared.cancel(req)
                return nil
            }
        }
        return box.image
    }

    /// JPEG, or PNG for an image with transparency, encoded in memory.
    static func encode(_ image: CGImage) -> Thumb? {
        let png = [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, (png ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, png ? nil : [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return Thumb(data: out as Data, mime: png ? "image/png" : "image/jpeg")
    }

    private final class ImageBox: @unchecked Sendable { var image: CGImage? }

    /// A cancellation flag the worker threads read.
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
    }
}
