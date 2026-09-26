// Draws the app icon and builds App/AppIcon.icns:
//   xcrun swiftc -parse-as-library -D MAKE_ICON App/make_icon.swift -o /tmp/make_icon && /tmp/make_icon [App/AppIcon.icns] [icon-1024.png]
// The whole file is behind MAKE_ICON so the app build, which compiles App/*.swift, skips it.
#if MAKE_ICON
import AppKit

/// Everything is laid out on a 1024-point canvas and scaled to each size.
func drawIcon(in ctx: CGContext) {
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(colorSpace: rgb, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
    }
    func gradient(_ a: UInt32, _ b: UInt32) -> CGGradient {
        CGGradient(colorsSpace: rgb, colors: [color(a), color(b)] as CFArray, locations: [0, 1])!
    }
    /// A superellipse-cornered rectangle, close to the continuous corners of macOS icons.
    func squircle(_ r: CGRect, radius: CGFloat) -> CGPath {
        let p = CGMutablePath()
        let n: CGFloat = 5, steps = 24
        let corners: [(CGPoint, CGFloat)] = [
            (CGPoint(x: r.maxX - radius, y: r.maxY - radius), 0), (CGPoint(x: r.minX + radius, y: r.maxY - radius), .pi / 2),
            (CGPoint(x: r.minX + radius, y: r.minY + radius), .pi), (CGPoint(x: r.maxX - radius, y: r.minY + radius), 3 * .pi / 2),
        ]
        for (i, (c, start)) in corners.enumerated() {
            for s in 0...steps {
                let t = start + CGFloat(s) / CGFloat(steps) * .pi / 2
                let ct = cos(t), st = sin(t)
                let x = c.x + radius * (ct < 0 ? -1 : 1) * pow(abs(ct), 2 / n)
                let y = c.y + radius * (st < 0 ? -1 : 1) * pow(abs(st), 2 / n)
                if i == 0 && s == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
        }
        p.closeSubpath()
        return p
    }

    // Body: the standard 824-point tile inside a 100-point margin, with the soft drop shadow macOS icons carry.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(body, radius: 230)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.32))
    ctx.addPath(tile); ctx.setFillColor(color(0x1F6FEB)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(tile); ctx.clip()
    ctx.drawLinearGradient(gradient(0x5AB0FF, 0x1452D8), start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // A faint sheen across the top half.
    ctx.drawRadialGradient(CGGradient(colorsSpace: rgb, colors: [color(0xFFFFFF, 0.22), color(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
                           startCenter: CGPoint(x: 512, y: 1000), startRadius: 0, endCenter: CGPoint(x: 512, y: 1000), endRadius: 620, options: [])
    ctx.restoreGState()

    // The spacebar keycap: a wide cap whose darker skirt shows below its top face.
    let cap = CGRect(x: 160, y: 318, width: 704, height: 340)
    let capPath = CGPath(roundedRect: cap, cornerWidth: 84, cornerHeight: 84, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 40, color: color(0x062A78, 0.55))
    ctx.addPath(capPath); ctx.setFillColor(color(0xC9D6EA)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(capPath); ctx.clip()
    ctx.drawLinearGradient(gradient(0xDCE5F2, 0xAFC1DC), start: CGPoint(x: 512, y: cap.maxY), end: CGPoint(x: 512, y: cap.minY), options: [])
    ctx.restoreGState()

    let face = CGRect(x: cap.minX + 30, y: cap.minY + 58, width: cap.width - 60, height: cap.height - 82)
    let facePath = CGPath(roundedRect: face, cornerWidth: 62, cornerHeight: 62, transform: nil)
    ctx.saveGState()
    ctx.addPath(facePath); ctx.clip()
    ctx.drawLinearGradient(gradient(0xFFFFFF, 0xEDF2F9), start: CGPoint(x: 512, y: face.maxY), end: CGPoint(x: 512, y: face.minY), options: [])
    ctx.restoreGState()
    ctx.addPath(facePath); ctx.setStrokeColor(color(0xFFFFFF, 0.9)); ctx.setLineWidth(3); ctx.strokePath()

    // The Markdown mark (M and down arrow), from the 208×128 markdown-mark geometry, y flipped for CoreGraphics.
    let m: [CGPoint] = [(30, 98), (30, 30), (50, 30), (70, 55), (90, 30), (110, 30), (110, 98), (90, 98), (90, 59), (70, 84), (50, 59), (50, 98)]
        .map { CGPoint(x: $0.0, y: $0.1) }
    let arrow: [CGPoint] = [(155, 98), (125, 65), (145, 65), (145, 30), (165, 30), (165, 65), (185, 65)].map { CGPoint(x: $0.0, y: $0.1) }
    let scale: CGFloat = 2.3
    let markW = 155 * scale, markH = 68 * scale
    let origin = CGPoint(x: face.midX - markW / 2, y: face.midY - markH / 2)
    func place(_ pts: [CGPoint]) -> CGPath {
        let p = CGMutablePath()
        p.addLines(between: pts.map { CGPoint(x: origin.x + ($0.x - 30) * scale, y: origin.y + (98 - $0.y) * scale) })
        p.closeSubpath()
        return p
    }
    ctx.saveGState()
    ctx.addPath(place(m)); ctx.addPath(place(arrow)); ctx.clip()
    ctx.drawLinearGradient(gradient(0x2F80F5, 0x1452D8), start: CGPoint(x: 512, y: origin.y + markH), end: CGPoint(x: 512, y: origin.y), options: [])
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    let ctx = g.cgContext
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    drawIcon(in: ctx)
    g.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

@main
enum MakeIcon {
    static func main() {
        let args = CommandLine.arguments
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let icns = args.count > 1 ? URL(fileURLWithPath: args[1]) : here.appendingPathComponent("AppIcon.icns")
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("AppIcon-\(getpid()).iconset")
        try? fm.removeItem(at: set)
        try! fm.createDirectory(at: set, withIntermediateDirectories: true)
        for size in [16, 32, 128, 256, 512] {
            try! png(pixels: size).write(to: set.appendingPathComponent("icon_\(size)x\(size).png"))
            try! png(pixels: size * 2).write(to: set.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
        }
        if args.count > 2 { try! png(pixels: 1024).write(to: URL(fileURLWithPath: args[2])) }
        let iconutil = Process()
        iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        iconutil.arguments = ["-c", "icns", "-o", icns.path, set.path]
        try! iconutil.run()
        iconutil.waitUntilExit()
        try? fm.removeItem(at: set)
        guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
        print("wrote \(icns.path)")
    }
}
#endif
