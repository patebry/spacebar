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

    // Drawn in the SVG's y-down coordinates, so the numbers match the source art one for one.
    ctx.translateBy(x: 0, y: 1024); ctx.scaleBy(x: 1, y: -1)
    // Shadows are in device space, which the scale above does not reach: offset (down) and blur scale with the size by hand.
    let px = ctx.userSpaceToDeviceSpaceTransform.a
    func shadow(dy: CGFloat, blur: CGFloat, alpha: CGFloat) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * px), blur: blur * px, color: color(0x000000, alpha))
    }
    func fill(_ path: CGPath, _ g: CGGradient, from top: CGFloat, to bottom: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: top), end: CGPoint(x: 512, y: bottom), options: [])
        ctx.restoreGState()
    }

    // Body: the standard 824-point tile inside a 100-point margin, dark, with the soft drop shadow macOS icons carry.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tile = squircle(body, radius: 230)
    ctx.saveGState()
    shadow(dy: 12, blur: 28, alpha: 0.32)
    ctx.addPath(tile); ctx.setFillColor(color(0x1C1C1E)); ctx.fillPath()
    ctx.restoreGState()
    fill(tile, CGGradient(colorsSpace: rgb, colors: [color(0x3A3A3D), color(0x1C1C1E), color(0x0E0E10)] as CFArray, locations: [0, 0.5, 1])!,
         from: body.minY, to: body.maxY)
    ctx.addPath(tile); ctx.setStrokeColor(color(0xFFFFFF, 0.2)); ctx.setLineWidth(5); ctx.strokePath()

    // The space bar: one wide keycap whose darker skirt shows below its top face.
    let cap = CGRect(x: 150, y: 346, width: 724, height: 320)
    let capPath = CGPath(roundedRect: cap, cornerWidth: 84, cornerHeight: 84, transform: nil)
    ctx.saveGState()
    shadow(dy: 14, blur: 32, alpha: 0.5)
    ctx.addPath(capPath); ctx.setFillColor(color(0xC0C4CC)); ctx.fillPath()
    ctx.restoreGState()
    fill(capPath, gradient(0xD7DAE0, 0xA9AEB8), from: cap.minY, to: cap.maxY)
    let face = CGRect(x: 175.3, y: 368.4, width: 673.3, height: 233.6)
    fill(CGPath(roundedRect: face, cornerWidth: 67.2, cornerHeight: 67.2, transform: nil), gradient(0xFFFFFF, 0xECEEF2), from: face.minY, to: face.maxY)

    // The open-box space symbol (U+2423). At 32 pixels and below a round 58-point stroke blurs into a blob, so there the stroke is a
    // whole number of pixels (1 at 16, 2 at 32) laid on the pixel grid, its ends cut flat on a pixel edge.
    let small = px * 1024 <= 32
    let width = small ? (px * 1024 / 16).rounded() / px : 58
    func snap(_ v: CGFloat) -> CGFloat { small ? ((v * px - width * px / 2).rounded() + width * px / 2) / px : v }
    let (left, right, top, bottom) = (snap(380), snap(644), small ? snap(430) - width / 2 : 430, snap(530))
    let glyph = CGMutablePath()
    glyph.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom), CGPoint(x: right, y: top)])
    ctx.addPath(glyph)
    ctx.setStrokeColor(color(0x0A84FF)); ctx.setLineWidth(width)
    ctx.setLineCap(small ? .butt : .round); ctx.setLineJoin(small ? .miter : .round); ctx.strokePath()
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
