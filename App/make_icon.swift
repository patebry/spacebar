// Draws the app icon and builds App/AppIcon.icns:
//   xcrun swiftc -parse-as-library -D MAKE_ICON App/make_icon.swift -o /tmp/make_icon && /tmp/make_icon [App/AppIcon.icns] [icon-1024.png]
// The whole file is behind MAKE_ICON so the app build, which compiles App/*.swift, skips it.
#if MAKE_ICON
import AppKit

let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: rgb, components: [CGFloat(hex >> 16 & 0xFF) / 255, CGFloat(hex >> 8 & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, a])!
}
func gradient(_ stops: [(UInt32, CGFloat)], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: rgb, colors: stops.map { color($0.0, $0.1) } as CFArray, locations: locations)!
}

/// A rounded rectangle with smoothed (continuous) corners: Figma's construction at 60% smoothing, a cubic, an arc and a cubic per
/// corner. The same path as the site's public/icon.svg, which was generated from it.
func squircle(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, radius: CGFloat, smoothing s: CGFloat = 0.6) -> CGPath {
    let r = min(radius, w / 2, h / 2)
    let p = min((1 + s) * r, w / 2, h / 2)
    let sweep = 90 * (1 - s) * .pi / 180
    let arcLength = sin(sweep / 2) * r * 2.squareRoot()
    let alpha = (.pi / 2 - sweep) / 2
    let c = r * tan(alpha / 2) * cos(45 * s * .pi / 180)
    let d = c * tan(45 * s * .pi / 180)
    let b = (p - arcLength - c - d) / 3, a = 2 * b
    let (R, B) = (x + w, y + h)
    let path = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    func arc(about center: CGPoint, to end: CGPoint) {
        let a0 = atan2(path.currentPoint.y - center.y, path.currentPoint.x - center.x)
        var a1 = atan2(end.y - center.y, end.x - center.x)
        if a1 - a0 > .pi { a1 -= 2 * .pi } else if a0 - a1 > .pi { a1 += 2 * .pi }
        for i in 1...16 { let t = a0 + (a1 - a0) * CGFloat(i) / 16; path.addLine(to: pt(center.x + r * cos(t), center.y + r * sin(t))) }
    }
    path.move(to: pt(x + p, y))
    path.addLine(to: pt(R - p, y))
    path.addCurve(to: pt(R - p + a + b + c, y + d), control1: pt(R - p + a, y), control2: pt(R - p + a + b, y))
    arc(about: pt(R - r, y + r), to: pt(R - d, y + p - a - b - c))
    path.addCurve(to: pt(R, y + p), control1: pt(R, y + p - a - b), control2: pt(R, y + p - a))
    path.addLine(to: pt(R, B - p))
    path.addCurve(to: pt(R - d, B - p + a + b + c), control1: pt(R, B - p + a), control2: pt(R, B - p + a + b))
    arc(about: pt(R - r, B - r), to: pt(R - p + a + b + c, B - d))
    path.addCurve(to: pt(R - p, B), control1: pt(R - p + a + b, B), control2: pt(R - p + a, B))
    path.addLine(to: pt(x + p, B))
    path.addCurve(to: pt(x + p - a - b - c, B - d), control1: pt(x + p - a, B), control2: pt(x + p - a - b, B))
    arc(about: pt(x + r, B - r), to: pt(x + d, B - p + a + b + c))
    path.addCurve(to: pt(x, B - p), control1: pt(x, B - p + a + b), control2: pt(x, B - p + a))
    path.addLine(to: pt(x, y + p))
    path.addCurve(to: pt(x + d, y + p - a - b - c), control1: pt(x, y + p - a), control2: pt(x, y + p - a - b))
    arc(about: pt(x + r, y + r), to: pt(x + p - a - b - c, y + d))
    path.addCurve(to: pt(x + p, y), control1: pt(x + p - a - b, y), control2: pt(x + p - a, y))
    path.closeSubpath()
    return path
}

/// The art for one small size, in whole pixels, y down. Scaled down as drawn, the bar reads as a minus sign: here it sits lower, is
/// taller for its width, and its lip (the key's front edge) is at least a whole pixel.
struct Small {
    var tile: CGFloat, radius: CGFloat           // the tile's inset on every side, and its corner radius
    var left: CGFloat, right: CGFloat            // the bar's sides
    var top: CGFloat, face: CGFloat, lip: CGFloat // the bar's top, the face's bottom, and the lip's bottom
    var corner: CGFloat, shadow: CGFloat         // the bar's corner radius; the depth of its shadow (0 for none)
}
let smallArt: [Int: Small] = [
    16: Small(tile: 1, radius: 3.2, left: 3, right: 13, top: 9, face: 12, lip: 13, corner: 1, shadow: 1),
    32: Small(tile: 3, radius: 6, left: 6, right: 26, top: 18, face: 23, lip: 25, corner: 2, shadow: 1),
    64: Small(tile: 6, radius: 12, left: 12, right: 52, top: 36, face: 46, lip: 49, corner: 4, shadow: 2),
]

func drawIcon(in ctx: CGContext, pixels: Int) {
    let small = smallArt[pixels]
    let canvas: CGFloat = small == nil ? 1024 : CGFloat(pixels)
    // Drawn in the SVG's y-down coordinates, so the numbers match the source art one for one.
    ctx.scaleBy(x: CGFloat(pixels) / canvas, y: CGFloat(pixels) / canvas)
    ctx.translateBy(x: 0, y: canvas); ctx.scaleBy(x: 1, y: -1)
    // Shadows are in device space, which the scale above does not reach: offset (down) and blur scale with the size by hand.
    let px = ctx.userSpaceToDeviceSpaceTransform.a
    func shadow(dy: CGFloat, deviation: CGFloat, _ c: CGColor) {
        ctx.setShadow(offset: CGSize(width: 0, height: -dy * px), blur: 2 * deviation * px, color: c)
    }
    func fill(_ path: CGPath, _ g: CGGradient, from top: CGFloat, to bottom: CGFloat) {
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    let tileGradient = gradient([(0x2E8CFF, 1), (0x0A57D6, 1)], [0, 1])
    let faceGradient = gradient([(0xFFFFFF, 1), (0xE4EEFC, 1)], [0, 1])

    if let s = small {
        let tile = squircle(s.tile, s.tile, canvas - 2 * s.tile, canvas - 2 * s.tile, radius: s.radius)
        if s.shadow > 0 {
            ctx.saveGState(); shadow(dy: s.shadow / 2, deviation: s.shadow / 2, color(0, 0.25))
            ctx.addPath(tile); ctx.setFillColor(color(0x0A57D6)); ctx.fillPath(); ctx.restoreGState()
        }
        fill(tile, tileGradient, from: s.tile, to: canvas - s.tile)
        ctx.saveGState(); ctx.addPath(tile); ctx.clip()
        func bar(to bottom: CGFloat) -> CGPath {
            CGPath(roundedRect: CGRect(x: s.left, y: s.top, width: s.right - s.left, height: bottom - s.top), cornerWidth: s.corner, cornerHeight: s.corner, transform: nil)
        }
        ctx.saveGState()
        if s.shadow > 0 { shadow(dy: s.shadow, deviation: s.shadow, color(0x002A6B, 0.45)) }
        ctx.addPath(bar(to: s.lip)); ctx.setFillColor(color(0x9DBBEA)); ctx.fillPath()
        ctx.restoreGState()
        // Nearly flat: a face that fades over three pixels reads as two bands, not one surface.
        fill(bar(to: s.face), gradient([(0xFFFFFF, 1), (0xEEF4FD, 1)], [0, 1]), from: s.top, to: s.face)
        ctx.restoreGState()
        return
    }

    // The tile: the standard 824-point body inside a 100-point margin, under a contact shadow and an ambient one.
    let tile = squircle(100, 100, 824, 824, radius: 185.4)
    ctx.saveGState()
    ctx.setFillColor(color(0x0A57D6))
    shadow(dy: 4, deviation: 4, color(0, 0.14)); ctx.addPath(tile); ctx.fillPath()
    shadow(dy: 14, deviation: 14, color(0, 0.22)); ctx.addPath(tile); ctx.fillPath()
    ctx.restoreGState()
    fill(tile, tileGradient, from: 100, to: 924)

    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.drawRadialGradient(gradient([(0xFFFFFF, 0.14), (0xFFFFFF, 0)], [0, 1]), startCenter: CGPoint(x: 512, y: 80), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 80), endRadius: 700, options: [])
    // The space bar, low on the tile like the bottom row of a keyboard: its lip (the whole bar) under a shadow, then its top face.
    let bar = squircle(212, 572, 600, 152, radius: 52)
    ctx.saveGState()
    ctx.setFillColor(color(0xBFD3F2))
    shadow(dy: 4, deviation: 4, color(0x00307A, 0.30)); ctx.addPath(bar); ctx.fillPath()
    shadow(dy: 22, deviation: 24, color(0x00307A, 0.35)); ctx.addPath(bar); ctx.fillPath()
    ctx.restoreGState()
    fill(squircle(212, 572, 600, 128, radius: 52), faceGradient, from: 572, to: 700)
    ctx.restoreGState()

    // A 4-point edge inside the tile, bright at the top and gone by the middle.
    ctx.saveGState(); ctx.addPath(tile); ctx.clip()
    ctx.addPath(tile); ctx.setLineWidth(4); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0xFFFFFF, 0.38), (0xFFFFFF, 0), (0xFFFFFF, 0.06)], [0, 0.5, 1]),
                           start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])
    ctx.restoreGState()
}

func png(pixels: Int) -> Data {
    // An sRGB context: in a device RGB one the sRGB blues overshoot along anti-aliased edges.
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: rgb,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.interpolationQuality = .high
    ctx.setShouldAntialias(true)
    drawIcon(in: ctx, pixels: pixels)
    return NSBitmapImageRep(cgImage: ctx.makeImage()!).representation(using: .png, properties: [:])!
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
