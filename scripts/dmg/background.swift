// Draws the background of spacebar.dmg's Finder window at 1x and 2x and joins them into background.tiff beside this file:
//   swift scripts/dmg/background.swift
// The layout matches settings.py (window 660x420 pt, icons centred at x 170 and 490, y 190). Finder draws icon labels in
// black over a background picture in light and dark mode alike, so the picture stays light.
import AppKit

let size = CGSize(width: 660, height: 420)
let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-dmg-bg-\(getpid())")
try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tmp) }

func gray(_ v: CGFloat) -> NSColor { NSColor(srgbRed: v / 255, green: v / 255, blue: v / 255, alpha: 1) }

func render(scale: Int) throws -> URL {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width) * scale, pixelsHigh: Int(size.height) * scale,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    gray(246).setFill()
    NSRect(origin: .zero, size: size).fill()

    let y = size.height - 190, from: CGFloat = 282, to: CGFloat = 378, head: CGFloat = 9
    let arrow = NSBezierPath()
    arrow.move(to: NSPoint(x: from, y: y))
    arrow.line(to: NSPoint(x: to, y: y))
    arrow.move(to: NSPoint(x: to - head, y: y - head))
    arrow.line(to: NSPoint(x: to, y: y))
    arrow.line(to: NSPoint(x: to - head, y: y + head))
    arrow.lineWidth = 2.5
    arrow.lineCapStyle = .round
    arrow.lineJoinStyle = .round
    gray(178).setStroke()
    arrow.stroke()

    let caption = NSAttributedString(string: "Drag spacebar to Applications", attributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .regular),
        .foregroundColor: gray(134),
    ])
    let w = caption.size()
    caption.draw(at: NSPoint(x: ((size.width - w.width) / 2).rounded(), y: (size.height - 318 - w.height).rounded()))

    NSGraphicsContext.restoreGraphicsState()
    let url = tmp.appendingPathComponent(scale == 1 ? "background.png" : "background@\(scale)x.png")
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    return url
}

let one = try render(scale: 1), two = try render(scale: 2)
let tiffutil = Process()
tiffutil.executableURL = URL(fileURLWithPath: "/usr/bin/tiffutil")
tiffutil.arguments = ["-cathidpicheck", one.path, two.path, "-out", here.appendingPathComponent("background.tiff").path]
try tiffutil.run()
tiffutil.waitUntilExit()
exit(tiffutil.terminationStatus)
