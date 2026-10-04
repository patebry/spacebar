import AppKit
import ImageIO
import UniformTypeIdentifiers
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func spin(until: Double = 10, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { spin(0.01) } }

_ = NSApplication.shared
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()

/// A thread-safe count of what the fake maker was asked to make, by path.
final class Made: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func add(_ p: String) { lock.lock(); paths.append(p); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

func fake(bytes: Int = 1000, delay: TimeInterval = 0, made: Made, honours: Bool = false) -> ThumbnailPipeline.Maker {
    { key, cancelled in
        made.add(key.path)
        let end = Date().addingTimeInterval(delay)
        while Date() < end {
            if honours && cancelled() { return nil }
            Thread.sleep(forTimeInterval: 0.002)
        }
        return ThumbnailPipeline.Thumb(data: Data(count: bytes), mime: "image/jpeg")
    }
}

// ---- sizes: a request is rounded up to one of a few sizes ----
check("size: rounded up to 128, 256, 384 or 512 pixels", [1, 128, 129, 300, 384, 600, 5000].map(ThumbnailPipeline.size(for:)) == [128, 128, 256, 384, 384, 512, 512])

// ---- concurrency: at most maxConcurrent at once, in the order asked ----
do {
    let made = Made()
    let p = ThumbnailPipeline(maxConcurrent: 3, make: fake(delay: 0.03, made: made))
    var done: [String] = []
    for i in 0..<20 { p.request(path: "/x/\(i)", root: "/", stamp: "1", px: 256) { if $0 != nil { done.append("/x/\(i)") } } }
    spin(until: 5) { done.count == 20 }
    check("concurrency: never more than three at once, every one made", p.peakRunning == 3 && done.count == 20 && p.stats.made == 20, "\(p.peakRunning) \(done.count)")
    check("concurrency: begun in the order asked", made.all.prefix(3).sorted() == ["/x/0", "/x/1", "/x/2"] && made.all.last == "/x/19", "\(made.all)")
}

// ---- the cache: hits, the count cap and the byte cap, least recently used first ----
do {
    let made = Made()
    let p = ThumbnailPipeline(maxConcurrent: 4, maxCacheBytes: 1 << 20, maxCacheCount: 40, make: fake(bytes: 1000, made: made))
    var got = 0
    for i in 0..<30 { p.request(path: "/c/\(i)", root: "/", stamp: "1", px: 256) { _ in got += 1 } }
    spin(until: 5) { got == 30 }
    var sync = false
    let t = p.request(path: "/c/5", root: "/", stamp: "1", px: 200) { sync = $0 != nil }
    check("cache: a thumbnail made once is served from memory, at once", t == nil && sync && p.stats.hits == 1 && made.all.count == 30)
    var again = false
    p.request(path: "/c/5", root: "/", stamp: "2", px: 256) { again = $0 != nil }
    spin(until: 5) { again }
    check("cache: a changed file (another stamp) is made again", made.all.count == 31)
    for i in 30..<100 { p.request(path: "/c/\(i)", root: "/", stamp: "1", px: 256) { _ in got += 1 } }
    spin(until: 5) { got == 100 }
    check("cache: held to its count cap", p.cachedCount <= 40 && p.stats.evicted > 0, "\(p.cachedCount)")
    var hit = false
    p.request(path: "/c/99", root: "/", stamp: "1", px: 256) { hit = $0 != nil }
    let before = made.all.count
    var old = false
    p.request(path: "/c/31", root: "/", stamp: "1", px: 256) { old = $0 != nil }
    spin(until: 5) { old }
    check("cache: the newest kept, the oldest evicted", hit && made.all.count == before + 1)

    let big = Made()
    let q = ThumbnailPipeline(maxConcurrent: 4, maxCacheBytes: 100_000, maxCacheCount: 1000, make: fake(bytes: 10_000, made: big))
    var n = 0
    for i in 0..<50 { q.request(path: "/b/\(i)", root: "/", stamp: "1", px: 256) { _ in n += 1 } }
    spin(until: 5) { n == 50 }
    check("cache: held to its byte cap", q.cachedBytes <= 100_000 && q.cachedCount <= 10, "\(q.cachedBytes) bytes, \(q.cachedCount)")
    let huge = Made()
    let r = ThumbnailPipeline(maxConcurrent: 1, maxCacheBytes: 80_000, make: fake(bytes: 20_000, made: huge))
    var h = false
    r.request(path: "/h", root: "/", stamp: "1", px: 256) { h = $0 != nil }
    spin(until: 5) { h }
    check("cache: a thumbnail over an eighth of the cap is served but not kept", h && r.cachedCount == 0)
}

// ---- cancellation: a fast scroll drops what is queued; a Quick Look request in flight stops ----
do {
    let made = Made()
    let p = ThumbnailPipeline(maxConcurrent: 4, make: fake(delay: 0.05, made: made))
    var answered: [Int] = []
    var tickets: [Int: Int] = [:]
    for i in 0..<200 { tickets[i] = p.request(path: "/s/\(i)", root: "/", stamp: "1", px: 256) { _ in answered.append(i) } }
    // The page scrolled on: all but the last screen of 10 are dropped.
    for i in 0..<190 { p.cancel(tickets[i]!) }
    spin(until: 5) { answered.count == 10 }
    spin(0.2)
    check("cancel: tiles scrolled past are never made, only those already under way", made.all.count <= 4 + 10 && p.stats.dropped >= 186,
          "made \(made.all.count), dropped \(p.stats.dropped)")
    check("cancel: a dropped load is never answered, the rest are", answered.sorted() == Array(190..<200) && p.pending == 0, "\(answered)")

    let slow = Made()
    let q = ThumbnailPipeline(maxConcurrent: 2, make: fake(delay: 2, made: slow, honours: true))
    var late = false
    let t = q.request(path: "/q", root: "/", stamp: "1", px: 256) { _ in late = true }!
    spin(until: 2) { !slow.all.isEmpty }
    let start = Date()
    q.cancel(t)
    spin(until: 3) { q.stats.abandoned == 1 }
    check("cancel: one being made stops when told (as a Quick Look request is cancelled)", q.stats.abandoned == 1 && Date().timeIntervalSince(start) < 0.5 && !late)

    let two = Made()
    let s = ThumbnailPipeline(maxConcurrent: 1, make: fake(delay: 0.05, made: two))
    var a = false, b = false
    let ta = s.request(path: "/d", root: "/", stamp: "1", px: 256) { _ in a = true }!
    s.request(path: "/d", root: "/", stamp: "1", px: 256) { b = $0 != nil }
    s.cancel(ta)
    spin(until: 3) { b }
    check("cancel: two tiles of one file share one thumbnail; dropping one keeps it for the other", b && !a && two.all.count == 1)

    // Cancelled while being made, then asked for again: the second job takes what the first finished and cached.
    let redo = Made()
    let u = ThumbnailPipeline(maxConcurrent: 1, make: fake(delay: 0.1, made: redo))
    let tr = u.request(path: "/r", root: "/", stamp: "1", px: 256) { _ in }!
    spin(until: 2) { !redo.all.isEmpty }
    u.cancel(tr)
    var re = false
    u.request(path: "/r", root: "/", stamp: "1", px: 256) { re = $0 != nil }
    spin(until: 3) { re }
    check("cancel: asked again while the dropped one finished, it is not made twice", re && redo.all.count == 1, "\(redo.all.count)")
}

// ---- making them: ImageIO for plain images, under the image view's bounds; JPEG, PNG when transparent; in memory ----
func picture(_ w: Int, _ h: Int, alpha: Bool = false) -> CGImage {
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast).rawValue)!
    ctx.setFillColor(CGColor(srgbRed: 0.9, green: 0.4, blue: 0.2, alpha: alpha ? 0.5 : 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()!
}
func write(_ name: String, _ type: UTType, _ image: CGImage, orientation: Int? = nil) -> URL {
    let url = dir.appendingPathComponent(name)
    let d = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(d, image, orientation.map { [kCGImagePropertyOrientation: $0] as CFDictionary })
    _ = CGImageDestinationFinalize(d)
    return url
}
func pixels(_ t: ThumbnailPipeline.Thumb?) -> (Int, Int)? {
    guard let t, let src = CGImageSourceCreateWithData(t.data as CFData, nil), let i = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
    return (i.width, i.height)
}
let jpeg = write("photo.jpg", .jpeg, picture(3000, 2000))
let turned = write("turned.jpg", .jpeg, picture(600, 400), orientation: 6)
let clear = write("clear.png", .png, picture(400, 300, alpha: true))
let never = { false }
let root = FolderListing.realPath(dir.path)!
func key(_ url: URL, _ px: Int, root: String = root) -> ThumbnailPipeline.Key { .init(path: url.path, root: root, stamp: "1", px: px) }
let tj = ThumbnailPipeline.makeThumb(key(jpeg, 384), cancelled: never)
check("make: a photo, as a JPEG at most 384 pixels on its longest side", tj?.mime == "image/jpeg" && pixels(tj).map { $0 == (384, 256) } == true,
      "\(String(describing: pixels(tj)))")
let tt = ThumbnailPipeline.makeThumb(key(turned, 256), cancelled: never)
check("make: turned by its EXIF orientation", pixels(tt).map { $0 == (171, 256) || $0 == (170, 256) } == true, "\(String(describing: pixels(tt)))")
let tc = ThumbnailPipeline.makeThumb(key(clear, 128), cancelled: never)
check("make: a transparent image stays transparent, as a PNG", tc?.mime == "image/png" && pixels(tc).map { $0 == (128, 96) } == true)
let small = write("small.png", .png, picture(40, 30))
check("make: never enlarged", pixels(ThumbnailPipeline.makeThumb(key(small, 512), cancelled: never)).map { $0 == (40, 30) } == true)

/// A PNG whose header declares `w`×`h` pixels and whose data is nothing: never decoded, so its size costs nothing.
func declaring(_ name: String, _ w: UInt32, _ h: UInt32) -> URL {
    var table = [UInt32](repeating: 0, count: 256)
    for n in 0..<256 { var c = UInt32(n); for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }; table[n] = c }
    func crc(_ d: [UInt8]) -> UInt32 { ~d.reduce(~UInt32(0)) { table[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8) } }
    func be(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xff), UInt8(v >> 8 & 0xff), UInt8(v & 0xff)] }
    func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] { let td = Array(type.utf8) + data; return be(UInt32(data.count)) + td + be(crc(td)) }
    let png = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] + chunk("IHDR", be(w) + be(h) + [8, 2, 0, 0, 0])
        + chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01]) + chunk("IEND", [])
    let url = dir.appendingPathComponent(name)
    try! Data(png).write(to: url)
    return url
}
check("make: an image declaring 100 megapixels is not decoded, here or by Quick Look",
      ThumbnailPipeline.makeThumb(key(declaring("bomb.png", 20_000, 5_000), 256), cancelled: never) == nil)
check("make: a file that is not an image gives none", ThumbnailPipeline.makeThumb(key(declaring("x.png", 0, 0), 256), cancelled: never) == nil)

// A file listed inside the root, then swapped for a link to an image outside it: the descriptor's real path is outside, so
// nothing is read.
let outside = dir.appendingPathComponent("outside")
let inside = dir.appendingPathComponent("inside")
try! FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
try! FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
let secret = write("outside/secret.jpg", .jpeg, picture(300, 200))
let listed = inside.appendingPathComponent("a.jpg")
try! FileManager.default.copyItem(at: secret, to: listed)
check("make: a file inside the root is made", ThumbnailPipeline.makeThumb(key(listed, 128, root: FolderListing.realPath(inside.path)!), cancelled: never) != nil)
try! FileManager.default.removeItem(at: listed)
try! FileManager.default.createSymbolicLink(at: listed, withDestinationURL: secret)
check("make: swapped for a link out of the root after the check, it is not read", ThumbnailPipeline.makeThumb(key(listed, 128, root: FolderListing.realPath(inside.path)!), cancelled: never) == nil)
let movie = inside.appendingPathComponent("clip.mov")
try! FileManager.default.createSymbolicLink(at: movie, withDestinationURL: secret)
check("make: nor handed to Quick Look", ThumbnailPipeline.makeThumb(key(movie, 128, root: FolderListing.realPath(inside.path)!), cancelled: never) == nil)
let before = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) ?? -1
_ = ThumbnailPipeline.makeThumb(key(jpeg, 256), cancelled: never)
check("make: nothing written beside the files", (try? FileManager.default.contentsOfDirectory(atPath: dir.path).count) == before)

// ---- the `thumb` host: the source decides; a dropped load is cancelled; the app's preview has none ----
final class Task: NSObject, WKURLSchemeTask {
    let request: URLRequest
    var status = 0
    var data = Data()
    var finished = false
    var error: Error?
    init(_ url: String) { request = URLRequest(url: URL(string: url)!) }
    func didReceive(_ response: URLResponse) { status = (response as? HTTPURLResponse)?.statusCode ?? -1 }
    func didReceive(_ data: Data) { self.data.append(data) }
    func didFinish() { finished = true }
    func didFailWithError(_ error: Error) { self.error = error }
}
let web = WKWebView(frame: .zero)
let handler = SchemeHandler(webRoot: dir)
var refused: [String] = []
handler.onRefused = { refused.append($0) }
let allowed = jpeg.path
var cancels = 0
var pending: [(Data?, String) -> Void] = []
handler.thumbnail = { path, px, reply in
    guard path == allowed, px == 256 else { return nil }
    pending.append(reply)
    return { cancels += 1 }
}
let enc = { (p: String) in "spacebar://thumb/" + p.addingPercentEncoding(withAllowedCharacters: .alphanumerics)! }
let ok = Task(enc(allowed) + "?s=256&n=1")
handler.webView(web, start: ok)
pending.removeFirst()(Data([1, 2, 3]), "image/jpeg")
check("host: a thumbnail the source allows is served as its image", ok.finished && ok.status == 200 && ok.data == Data([1, 2, 3]))
let badType = Task(enc(allowed) + "?s=256&n=2")
handler.webView(web, start: badType)
pending.removeFirst()(Data([1]), "text/html")
check("host: served as a JPEG or PNG only", badType.error != nil && !badType.finished)
let asks = [enc("/etc/hosts") + "?s=256", enc(allowed) + "?s=128", enc(allowed), enc(allowed) + "?s=4096", "spacebar://thumb/relative.jpg?s=256",
            "spacebar://thumb" + allowed + "?s=256"]
let tasks = asks.map(Task.init)
tasks.forEach { handler.webView(web, start: $0) }
check("host: refused when the source refuses, the size is missing or out of range, or the path is not one absolute path",
      tasks.allSatisfy { $0.error != nil && !$0.finished } && pending.isEmpty && refused.count == asks.count, "\(refused)")
let dropped = Task(enc(allowed) + "?s=256&n=3")
handler.webView(web, start: dropped)
handler.dropThumbs([dropped.request.url!.absoluteString])
check("host: a load the page drops is cancelled and failed", cancels == 1 && dropped.error != nil)
pending.removeFirst()(Data([9]), "image/jpeg")
check("host: its late answer goes nowhere", !dropped.finished && dropped.data.isEmpty)
let early = Task(enc(allowed) + "?s=256&n=4")
handler.dropThumbs([early.request.url!.absoluteString])
handler.webView(web, start: early)
check("host: one dropped before it started is refused when it starts, never made", early.error != nil && pending.isEmpty)
let stopped = Task(enc(allowed) + "?s=256&n=5")
handler.webView(web, start: stopped)
handler.webView(web, stop: stopped)
check("host: one WebKit stops is cancelled", cancels == 2)
pending.removeAll()
let app = SchemeHandler(webRoot: dir, fileHost: false)
app.thumbnail = handler.thumbnail
let none = Task(enc(allowed) + "?s=256")
app.webView(web, start: none)
check("host: the app's own preview (no file host) serves none", none.error != nil && pending.isEmpty)

print(failures == 0 ? "thumbs: all passed" : "thumbs: \(failures) failed")
exit(failures == 0 ? 0 : 1)
