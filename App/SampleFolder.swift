import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The welcome sheet's "Try it" folder: a few files of different kinds, made on demand in the home folder, where the user can
/// find it again and no folder macOS guards (Documents, Desktop) asks for access. Files already there are left as they are, so
/// a user's edits to them survive another click.
enum SampleFolder {
    static let name = "spacebar Sample Folder"

    static func url(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(name, isDirectory: true)
    }

    static let files: [(String, String)] = [
        ("README.md", """
        # Welcome to spacebar

        You are looking at a **folder preview**. The sidebar lists everything in this folder; click a file, or use ↑ and ↓.

        Click any text to edit it in place. Changes save as you type, Esc finishes, and ⌘Z undoes.

        - [ ] Click this line to edit it
        - [x] Tick a task: the file on disk changes too

        | Try | What you see |
        | --- | --- |
        | `data.csv` | a table you can sort |
        | `settings.json` | a tree you can fold |
        | `analysis.ipynb` | a notebook, cell by cell |
        | `hello.py` | highlighted code |
        | `keyboard.png` | an image you can zoom |
        | `guide.pdf` | a PDF |

        Quick Look keeps Apple's own preview for images and PDFs in Finder. Turn on **Use spacebar for every file** in
        spacebar's settings, and Space on `keyboard.png` or `guide.pdf` in Finder opens them here too.

        > [!tip] Press Space on any folder in Finder
        > spacebar previews the folder with this sidebar, opening its README first.

        $$e^{i\\pi} + 1 = 0$$

        ```mermaid
        graph LR
          Finder -- Space --> spacebar --> Preview
        ```

        """),
        ("Notes/ideas.md", "# Ideas\n\n- Links between notes: [[README]]\n- #tags and callouts work too\n\n> [!note]\n> Folders nest in the sidebar.\n"),
        ("data.csv", "city;country;population;area km²\nTokyo;Japan;37400068;2194\nDelhi;India;28514000;1484\nShanghai;China;25582000;6341\n"
            + "São Paulo;Brazil;21650000;1521\nMexico City;Mexico;21581000;1485\nCairo;Egypt;20076000;3085\nMumbai;India;19980000;603\n"),
        ("settings.json", #"{"name": "sample", "version": 3, "features": {"tree": true, "raw": false, "levels": [1, 2, 3]}, "owner": null, "tags": ["json", "tree", "demo"]}"# + "\n"),
        ("hello.py", "from dataclasses import dataclass\n\n\n@dataclass\nclass Greeting:\n    name: str\n\n    def __str__(self) -> str:\n        return f\"Hello, {self.name}!\"\n\n\nprint(Greeting(\"spacebar\"))\n"),
        ("analysis.ipynb", #"""
        {"cells": [
          {"cell_type": "markdown", "metadata": {}, "source": ["# A small notebook\n", "Markdown cells render as Markdown."]},
          {"cell_type": "code", "execution_count": 1, "metadata": {}, "outputs": [{"name": "stdout", "output_type": "stream", "text": ["3 cities over 25 million\n"]}],
           "source": ["cities = {\"Tokyo\": 37.4, \"Delhi\": 28.5, \"Shanghai\": 25.6}\n", "print(f\"{len(cities)} cities over 25 million\")"]},
          {"cell_type": "code", "execution_count": 2, "metadata": {}, "outputs": [{"data": {"text/plain": ["37.4"]}, "execution_count": 2, "metadata": {}, "output_type": "execute_result"}],
           "source": ["max(cities.values())"]}
        ], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python"}},
         "nbformat": 4, "nbformat_minor": 5}
        """#),
        ("todo.txt", "Press Space on this folder in Finder.\nOpen a file from the sidebar.\nChange the theme with the Aa button.\n"),
        ("logo.svg", ##"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120" width="480" height="480"><rect width="120" height="120" rx="26" fill="#1f6feb"/><rect x="24" y="74" width="72" height="14" rx="7" fill="#fff"/></svg>"## + "\n"),
    ]

    /// Drawn when the folder is made, so the repository holds no binaries.
    static let drawn: [(String, () -> Data?)] = [("keyboard.png", png), ("guide.pdf", pdf)]

    static var names: [String] { files.map(\.0) + drawn.map(\.0) }

    struct DrawError: LocalizedError {
        let file: String
        var errorDescription: String? { "\(file) could not be drawn" }
    }

    /// Creates the folder and whichever sample files are missing. Returns the folder, or the error that stopped it.
    static func create(in dir: URL = url()) -> Result<URL, Error> {
        let fm = FileManager.default
        let all = files.map { f in (f.0, { Data(f.1.utf8) as Data? }) } + drawn
        do {
            for (rel, make) in all {
                let file = dir.appendingPathComponent(rel)
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                var st = stat()
                if lstat(file.path, &st) == 0 { continue }
                guard let data = make() else { throw DrawError(file: rel) }
                try data.write(to: file, options: .withoutOverwriting)
            }
            return .success(dir)
        } catch {
            return .failure(error)
        }
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    private static func line(_ text: String, size: CGFloat, bold: Bool = false, color: CGColor) -> CTLine {
        let font = CTFontCreateUIFontForLanguage(bold ? .emphasizedSystem : .system, size, nil) ?? CTFontCreateWithName("Helvetica" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [kCTFontAttributeName as NSAttributedString.Key: font, kCTForegroundColorAttributeName as NSAttributedString.Key: color]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
    }

    private static func draw(_ l: CTLine, in ctx: CGContext, centeredAt x: CGFloat, baseline y: CGFloat) {
        let w = CTLineGetTypographicBounds(l, nil, nil, nil)
        ctx.textPosition = CGPoint(x: x - CGFloat(w) / 2, y: y)
        CTLineDraw(l, ctx)
    }

    /// A row of keys with the space bar lit, at twice its point size.
    static func png() -> Data? {
        let w = 1280, h = 720
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(rgb(0xEEF2F8))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let key = { (r: CGRect, fill: CGColor, shadow: CGFloat) in
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: shadow, color: rgb(0x1F2A44, 0.25))
            ctx.setFillColor(fill)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: 22, cornerHeight: 22, transform: nil))
            ctx.fillPath()
            ctx.restoreGState()
        }
        let keyW: CGFloat = 104, gap: CGFloat = 16
        for row in 0..<2 {
            let count = 9 - row
            let total = CGFloat(count) * keyW + CGFloat(count - 1) * gap
            for i in 0..<count {
                key(CGRect(x: (CGFloat(w) - total) / 2 + CGFloat(i) * (keyW + gap), y: 440 - CGFloat(row) * 120, width: keyW, height: keyW), rgb(0xFFFFFF), 12)
            }
        }
        let bar = CGRect(x: 290, y: 150, width: 700, height: 116)
        key(bar, rgb(0x1F6FEB), 24)
        draw(line("space", size: 44, bold: true, color: rgb(0xFFFFFF)), in: ctx, centeredAt: bar.midX, baseline: bar.midY - 15)
        draw(line("Press Space on any file", size: 40, color: rgb(0x1F2A44, 0.8)), in: ctx, centeredAt: CGFloat(w) / 2, baseline: 62)
        guard let image = ctx.makeImage() else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImagePropertyDPIWidth: 144, kCGImagePropertyDPIHeight: 144] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// One US Letter page: a title and a few paragraphs.
    static func pdf() -> Data? {
        let out = NSMutableData()
        var page = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(data: out as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &page, [kCGPDFContextTitle: "spacebar guide", kCGPDFContextCreator: "spacebar"] as CFDictionary)
        else { return nil }
        ctx.beginPDFPage(nil)
        let ink = rgb(0x1D1D1F)
        ctx.setFillColor(rgb(0x1F6FEB))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 72, y: 676, width: 48, height: 48), cornerWidth: 11, cornerHeight: 11, transform: nil))
        ctx.fillPath()
        ctx.setFillColor(rgb(0xFFFFFF))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 81, y: 688, width: 30, height: 6), cornerWidth: 3, cornerHeight: 3, transform: nil))
        ctx.fillPath()
        ctx.textPosition = CGPoint(x: 136, y: 688)
        CTLineDraw(line("A one-page PDF", size: 28, bold: true, color: ink), ctx)
        let body = """
        spacebar shows PDFs in its folder sidebar with the other files here: scroll, zoom, and select text to copy it.

        In Finder, Quick Look keeps Apple's own preview for a PDF. With Use spacebar for every file turned on in spacebar's \
        settings, Space on this file opens it in spacebar's panel instead, with the folder's sidebar beside it.

        Press Space again, or Esc, to close the panel.
        """
        let font = CTFontCreateUIFontForLanguage(.system, 14, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        let style: CTParagraphStyle = {
            var spacing: CGFloat = 5
            return withUnsafePointer(to: &spacing) { p in
                CTParagraphStyleCreate([CTParagraphStyleSetting(spec: .lineSpacingAdjustment, valueSize: MemoryLayout<CGFloat>.size, value: p)], 1)
            }
        }()
        let text = NSAttributedString(string: body, attributes: [kCTFontAttributeName as NSAttributedString.Key: font,
                                                                  kCTForegroundColorAttributeName as NSAttributedString.Key: rgb(0x3A3A3C),
                                                                  kCTParagraphStyleAttributeName as NSAttributedString.Key: style])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0),
                                             CGPath(rect: CGRect(x: 72, y: 380, width: 468, height: 270), transform: nil), nil)
        CTFrameDraw(frame, ctx)
        ctx.endPDFPage()
        ctx.closePDF()
        return out as Data
    }
}
