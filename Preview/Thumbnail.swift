import AppKit
import QuickLookThumbnailing

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
