import AppKit
import AVFoundation
import AVKit
import WebKit
import os

let log = Logger(subsystem: "md.spacebar.test", category: "mediapane")
var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func spin(until: Double = 10, _ done: () -> Bool) { let end = Date().addingTimeInterval(until); while !done() && Date() < end { spin(0.02) } }

/// One second of a quiet sine, 16-bit PCM.
func makeWAV(_ url: URL, seconds: Double = 2) {
    let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1)!
    let file = try! AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1,
                                                            AVLinearPCMBitDepthKey: 16])
    let n = AVAudioFrameCount(44_100 * seconds)
    let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: n)!
    buf.frameLength = n
    for i in 0..<Int(n) { buf.floatChannelData![0][i] = 0.1 * sin(Float(i) * 0.06) }
    try! file.write(from: buf)
}

/// `frames` frames of 64x64 H.264 at 10 fps, each a shade lighter than the last.
func makeVideo(_ url: URL, frames: Int) {
    let w = try! AVAssetWriter(outputURL: url, fileType: .mp4)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 64, AVVideoHeightKey: 64])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 64, kCVPixelBufferHeightKey as String: 64])
    w.add(input)
    w.startWriting()
    w.startSession(atSourceTime: .zero)
    for i in 0..<frames {
        spin(until: 5) { input.isReadyForMoreMediaData }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(20 + i * 8), CVPixelBufferGetDataSize(pb!))
        CVPixelBufferUnlockBaseAddress(pb!, [])
        adaptor.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 10))
    }
    input.markAsFinished()
    var done = false
    w.finishWriting { done = true }
    spin { done }
}

func png(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// The WAV as AAC with `art` as its embedded artwork, or nil when the export is not available here.
func makeM4A(from wav: URL, to url: URL, art: Data) -> URL? {
    guard let s = AVAssetExportSession(asset: AVURLAsset(url: wav), presetName: AVAssetExportPresetAppleM4A) else { return nil }
    let item = AVMutableMetadataItem()
    item.identifier = .commonIdentifierArtwork
    item.dataType = kCMMetadataBaseDataType_PNG as String
    item.value = art as NSData
    s.outputURL = url
    s.outputFileType = .m4a
    let title = AVMutableMetadataItem(), artist = AVMutableMetadataItem()
    title.identifier = .commonIdentifierTitle
    title.value = "Test Tone" as NSString
    artist.identifier = .commonIdentifierArtist
    artist.value = "spacebar" as NSString
    s.metadata = [item, title, artist]
    var done = false
    s.exportAsynchronously { done = true }
    spin(until: 20) { done }
    return s.status == .completed ? url : nil
}

_ = NSApplication.shared
OffScreen.install()
let dir = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
let wav = dir.appendingPathComponent("tone.wav"), mp4 = dir.appendingPathComponent("clip.mp4"), junk = dir.appendingPathComponent("junk.mp4")
makeWAV(wav)
makeVideo(mp4, frames: 20)
try! Data((0..<4096).map { _ in UInt8.random(in: 0...255) }).write(to: junk)
let artPNG = png(width: 40, height: 30)
let m4a = makeM4A(from: wav, to: dir.appendingPathComponent("tagged.m4a"), art: artPNG)

// ---- resumeTime: where a reload of the same file starts ----
let s = { (x: Double) in CMTime(seconds: x, preferredTimescale: 600) }
check("resume: the time it was at", MediaPane.resumeTime(s(1.5), duration: s(3)) == s(1.5))
check("resume: at the start, invalid or indefinite: from the start",
      MediaPane.resumeTime(.zero, duration: s(3)) == nil && MediaPane.resumeTime(.invalid, duration: s(3)) == nil
      && MediaPane.resumeTime(.indefinite, duration: s(3)) == nil && MediaPane.resumeTime(s(-1), duration: s(3)) == nil)
check("resume: at or past the end of a shorter file: from the start", MediaPane.resumeTime(s(3), duration: s(3)) == nil
      && MediaPane.resumeTime(s(5), duration: s(2)) == nil)
check("resume: a duration not known yet does not stop it", MediaPane.resumeTime(s(1), duration: .indefinite) == s(1))

// ---- info: what the kind line says of a video and an audio file ----
func info(_ url: URL, audio: Bool) -> String? {
    var out: String?, done = false
    Task { out = await MediaPane.info(AVURLAsset(url: url), audio: audio); done = true }
    spin(until: 10) { done }
    return out
}
check("info: a video's size and length", info(mp4, audio: false).map { $0.hasPrefix("64 × 64 · 0:0") } == true, info(mp4, audio: false) ?? "nil")
if let m4a {
    check("info: an audio file's title, artist and length", info(m4a, audio: true).map { $0.hasPrefix("Test Tone — spacebar · 0:0") } == true, info(m4a, audio: true) ?? "nil")
}
check("info: lengths as m:ss, and h:mm:ss from an hour", MediaPane.duration(6) == "0:06" && MediaPane.duration(125.4) == "2:05" && MediaPane.duration(3725) == "1:02:05")

// ---- the pane in a real (off-screen) window above a WKWebView, as in the extension ----
let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 1000, height: 800), styleMask: [.borderless], backing: .buffered, defer: false)
let container = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 800))
let web = WKWebView(frame: container.bounds)
web.autoresizingMask = [.width, .height]
container.addSubview(web)
window.contentView = container
window.orderBack(nil)

let pane = MediaPane()
var failed: [String] = []
pane.onFailed = { failed.append($0) }
func item() -> AVPlayerItem? { pane.view.player?.currentItem }
func ready() { spin { item()?.status == .readyToPlay || item()?.status == .failed } }
func seconds() -> Double { pane.view.player?.currentTime().seconds ?? -1 }

// A video shown and left before the page places it (a quick switch in the sidebar): the container keeps its size.
do {
    let quick = MediaPane()
    let before = (container.frame, web.frame, window.frame)
    quick.show(mp4, audio: false, over: web)
    spin(until: 0.3) { false }
    let joined = quick.view.superview != nil
    quick.close()
    spin(until: 0.2) { false }
    // The growth itself needs Quick Look's constraint-laid-out window; off screen the check is that the view never joins.
    check("a video left before it is placed never joins the container, and the container, web view and window keep their size",
          !joined && container.frame == before.0 && web.frame == before.1 && window.frame == before.2,
          "\(container.frame) \(web.frame) \(window.frame)")
}

pane.show(wav, audio: true, over: web)
check("show: not in the container until the page places it, hidden",
      pane.view.superview == nil && pane.view.isHidden && !pane.placed)
check("audio: inline controls, no full screen button, the file's icon above the controls",
      pane.view.controlsStyle == .inline && !pane.view.showsFullScreenToggleButton && pane.audio && !pane.backdrop.isHidden && pane.art.image != nil)
let msg: [String: Any] = ["path": wav.path, "x": 340, "y": 300, "w": 560, "h": 220, "hide": false, "bg": [240, 240, 242], "dark": false, "radius": 8]
pane.place(message: ["path": mp4.path, "x": 0, "y": 0, "w": 10, "h": 10], in: web)
check("place: a message for another file is ignored", pane.view.isHidden && !pane.placed)
pane.place(message: msg, in: web)
check("place: at the page's area, above the web view, corners rounded", !pane.view.isHidden && pane.placed && pane.view.frame == NSRect(x: 340, y: 280, width: 560, height: 220)
      && pane.view.superview === container && container.subviews.last === pane.view
      && pane.view.layer?.cornerRadius == 8, "\(pane.view.frame)")
let artFrame = pane.art.convert(pane.art.bounds, to: pane.view)
let backdrop = pane.backdrop.layer?.backgroundColor.flatMap { NSColor(cgColor: $0)?.usingColorSpace(.sRGB) }
check("audio: the art sits inside the player, clear of the controls along the bottom, on the page's backdrop over AVKit's placeholder",
      artFrame.minY >= MediaPane.artInsets.bottom - 1 && artFrame.maxY <= 220 && artFrame.width > 400 && artFrame.height > 100
      && pane.backdrop.convert(pane.backdrop.bounds, to: pane.view) == pane.view.bounds && backdrop.map { abs($0.redComponent * 255 - 240) < 1 } == true,
      "\(artFrame) \(pane.backdrop.frame)")
pane.place(message: msg.merging(["x": "340", "w": true]) { _, n in n }, in: web)
check("place: strings and booleans are not numbers", pane.view.frame == NSRect(x: 340, y: 280, width: 560, height: 220))
pane.place(message: ["path": wav.path, "hide": true], in: web)
check("hide alone: hidden, the file kept", pane.view.isHidden && pane.path == wav.path)
pane.place(message: msg, in: web)
ready()
spin(0.3)
check("audio: opens paused at the start, never playing by itself", item()?.status == .readyToPlay && pane.view.player?.rate == 0 && seconds() == 0,
      "status \(item()?.status.rawValue ?? -1) rate \(pane.view.player?.rate ?? -1) t \(seconds())")

// ---- video: the same pane, a new item ----
let firstPlayer = pane.view.player
pane.show(mp4, audio: false, over: web)
pane.place(message: msg.merging(["path": mp4.path, "x": 240, "y": 100, "w": 760, "h": 700, "radius": 0]) { _, n in n }, in: web)
ready()
spin(0.3)
check("video: the art goes, the full screen button comes, the pane is reused", pane.backdrop.isHidden && pane.view.showsFullScreenToggleButton
      && !pane.audio && pane.view.player === firstPlayer && pane.view.frame == NSRect(x: 240, y: 0, width: 760, height: 700))
check("video: opens paused on its first frame", item()?.status == .readyToPlay && pane.view.player?.rate == 0 && seconds() == 0
      && abs((item()?.duration.seconds ?? 0) - 2) < 0.2, "rate \(pane.view.player?.rate ?? -1) t \(seconds()) d \(item()?.duration.seconds ?? -1)")

// ---- a change on disk: the same file again keeps its time, and plays only if it was playing ----
var sought = false
pane.view.player?.seek(to: s(1.2), toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
spin { sought }
let before = item()
pane.show(mp4, audio: false, over: web)
ready()
spin { abs(seconds() - 1.2) < 0.05 }
check("reload: a new item, at the time it was at, still paused", item() !== before && abs(seconds() - 1.2) < 0.05 && pane.view.player?.rate == 0,
      "t \(seconds()) rate \(pane.view.player?.rate ?? -1)")
pane.view.player?.isMuted = true
pane.view.player?.seek(to: .zero)
pane.view.player?.play()
spin(0.2)
pane.show(mp4, audio: false, over: web)
ready()
spin(0.3)
check("reload while playing: plays on", pane.view.player?.rate ?? 0 > 0, "rate \(pane.view.player?.rate ?? -1)")
pane.view.player?.pause()
sought = false
pane.view.player?.seek(to: s(0.8), toleranceBefore: .zero, toleranceAfter: .zero) { _ in sought = true }
spin { sought }
pane.view.player?.play()
pane.show(mp4, audio: false, over: web)
pane.show(mp4, audio: false, over: web)
ready()
spin(0.2)
check("two reloads before the first is ready: still at its time, still playing", pane.view.player?.rate ?? 0 > 0 && seconds() >= 0.8,
      "rate \(pane.view.player?.rate ?? -1) t \(seconds())")
pane.show(wav, audio: true, over: web)
ready()
spin(0.2)
check("another file: paused, from the start", pane.view.player?.rate == 0 && seconds() < 0.05, "rate \(pane.view.player?.rate ?? -1) t \(seconds())")
pane.view.player?.isMuted = false

// ---- a file AVFoundation cannot play: the owner is told, so it can show the info card ----
pane.show(junk, audio: false, over: web)
spin { !failed.isEmpty }
check("not media: reported as failed, for that file", failed == [junk.path], "\(failed)")

// ---- embedded artwork ----
if let m4a {
    pane.show(m4a, audio: true, over: web)
    pane.place(message: msg.merging(["path": m4a.path]) { _, n in n }, in: web)
    spin { pane.art.image?.size == NSSize(width: 40, height: 30) }
    check("audio: the file's embedded artwork replaces its icon", pane.art.image?.size == NSSize(width: 40, height: 30) && !pane.backdrop.isHidden,
          "\(pane.art.image?.size ?? .zero)")
} else {
    print("SKIP no AAC export here: the embedded artwork was not checked")
}

// ---- the formats added for the Space helper: each is routed to the player, and plays ----
var added: [(URL, Bool)] = []
if let m4a { let b = dir.appendingPathComponent("book.m4b"); try? FileManager.default.copyItem(at: m4a, to: b); added.append((b, true)) }
// AMR-NB: the magic, then frames of mode 12.2 (a header byte and 31 bytes of silence each).
let amr = dir.appendingPathComponent("memo.amr")
try! (Data("#!AMR\n".utf8) + Data((0..<50).flatMap { _ in [UInt8(0x3c)] + [UInt8](repeating: 0, count: 31) })).write(to: amr)
added.append((amr, true))
// 3GPP, MPEG-1 and MPEG-2 program streams and an MPEG-2 elementary stream need ffmpeg to make.
for (name, args) in [("clip.3gp", ["-s", "176x144", "-r", "10", "-c:v", "h263", "-c:a", "aac", "-ar", "8000", "-ac", "1"]), ("clip.mpg", ["-c:v", "mpeg1video", "-c:a", "mp2"]), ("clip.mpeg", ["-c:v", "mpeg2video", "-c:a", "mp2", "-f", "vob"]),
                     ("clip.m2v", ["-an", "-c:v", "mpeg2video", "-f", "mpeg2video"])] {
    let ff = Process()
    ff.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    ff.arguments = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc=size=160x120:rate=25", "-f", "lavfi", "-i", "sine",
                    "-t", "1"] + args + [dir.appendingPathComponent(name).path]
    ff.standardError = FileHandle.nullDevice
    try? ff.run()
    ff.waitUntilExit()
    if ff.terminationStatus == 0 { added.append((dir.appendingPathComponent(name), false)) } else { print("SKIP \(name): no ffmpeg here to make one") }
}
for (url, isAudio) in added {
    let kind = FileTypes.kind(name: url.lastPathComponent)
    let view = FileView.payload(path: url.path, kind: kind, root: dir.path, reason: "open", canOpen: true)["view"] as? String
    var playable: Bool?
    Task { playable = (try? await AVURLAsset(url: url).load(.isPlayable)) ?? false }
    spin { playable != nil }
    failed = []
    pane.show(url, audio: isAudio, over: web)
    ready()
    check(".\(url.pathExtension): the \(isAudio ? "audio" : "video") view, and AVFoundation plays it", kind == (isAudio ? .audio : .video)
          && view == (isAudio ? "audio" : "video") && playable == true && item()?.status == .readyToPlay && failed.isEmpty,
          "\(kind) \(view ?? "nil") playable \(playable ?? false) status \(item()?.status.rawValue ?? -1) \(failed)")
}
for ext in ["webm", "mkv", "ogg", "opus"] {
    check(".\(ext) stays an info card", ![FileKind.video, .audio].contains(FileTypes.kind(name: "x.\(ext)")))
}

// ---- teardown: stopped, the item let go, the view gone ----
pane.show(mp4, audio: false, over: web)
ready()
let last = pane.view.player
last?.isMuted = true
last?.play()
spin(0.1)
pane.close()
check("close: stopped and the file let go", last?.rate == 0 && last?.currentItem == nil && pane.view.player == nil)
check("close: removed from the container, hidden, forgotten", pane.view.superview == nil && pane.view.isHidden && pane.path == nil && !pane.placed
      && container.subviews == [web] && pane.art.image == nil)
pane.place(message: msg.merging(["path": mp4.path]) { _, n in n }, in: web)
check("close: a late message does not bring it back", pane.view.superview == nil && pane.view.isHidden)

// ---- the info card's thumbnail (Preview/Thumbnail.swift) ----
// QuickLookThumbnailing can take many seconds on a cold machine (a CI runner): a generous timeout here, and no thumbnail at all
// is a SKIP, not a failure; what a thumbnail is when there is one is still checked.
func skip(_ name: String) { print("SKIP \(name): QuickLookThumbnailing gave nothing on this machine") }
let pic = dir.appendingPathComponent("pic.png")
try! png(width: 800, height: 600).write(to: pic)
var thumb: String?
let got = DispatchSemaphore(value: 0)
DispatchQueue.global().async { thumb = Thumbnail.dataURL(pic, timeout: 30); got.signal() }
spin(until: 65) { got.wait(timeout: .now()) == .success }
let decoded = thumb.flatMap { Data(base64Encoded: String($0.dropFirst("data:image/png;base64,".count))) }.flatMap(NSImage.init(data:))
if thumb == nil { skip("thumbnail: a PNG data: URL of the file") } else {
check("thumbnail: a PNG data: URL of the file, at most 1024 pixels and 2 MB", thumb?.hasPrefix("data:image/png;base64,") == true
      && (thumb?.utf8.count ?? .max) <= Thumbnail.maxBytes && decoded.map { $0.representations[0].pixelsWide <= 1024 && $0.representations[0].pixelsWide > 64 } == true,
      "\(thumb?.prefix(40) ?? "nil") \(decoded?.representations.first?.pixelsWide ?? 0)")
}
let app = URL(fileURLWithPath: "/System/Applications/Calculator.app")
var appThumb: String?, junkThumb: String? = "unset"
let got2 = DispatchSemaphore(value: 0)
DispatchQueue.global().async { appThumb = Thumbnail.dataURL(app, icon: true, timeout: 30); junkThumb = Thumbnail.dataURL(junk, timeout: 30); got2.signal() }
spin(until: 130) { got2.wait(timeout: .now()) == .success }
check("thumbnail: an unknown binary gives nothing rather than a generic icon", junkThumb == nil, "\(junkThumb?.prefix(30) ?? "nil")")
if appThumb == nil { skip("thumbnail: an app gives its large icon") } else {
    check("thumbnail: an app gives its large icon", appThumb?.hasPrefix("data:image/png;base64,") == true, "\(appThumb?.prefix(30) ?? "nil")")
}
let t0 = Date()
_ = Thumbnail.dataURL(dir.appendingPathComponent("pic.png"), timeout: 0.001)
check("thumbnail: never waits past its timeout", Date().timeIntervalSince(t0) < 0.5, "\(Date().timeIntervalSince(t0)) s")

print("\n\(failures == 0 ? "all" : "\(failures) FAILED of the") media view checks")
exit(failures == 0 ? 0 : 1)
