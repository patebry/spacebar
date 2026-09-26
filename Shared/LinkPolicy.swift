import AppKit
import UniformTypeIdentifiers

/// What a link in a previewed document may open. The document is untrusted (a downloaded .md), and opening goes through the
/// unsandboxed writer, so a link may only reach a web page or an existing plain document: never an app, bundle, script,
/// installer, disk image, location file, or anything with an execute bit, whose default handler could run code.
enum LinkPolicy {
    static let maxURLBytes = 8192

    /// Why `url` may not be opened, or nil when it may.
    static func refusal(_ url: URL) -> String? {
        guard url.absoluteString.utf8.count <= maxURLBytes else { return "URL too long" }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return (url.host ?? "").isEmpty ? "no host" : nil
        case "file":
            return fileRefusal(url)
        default:
            return "scheme \(url.scheme ?? "none") not allowed"
        }
    }

    private static let allowed: [UTType] = [
        .plainText, .image, .audiovisualContent, .pdf, .rtf, .rtfd, .spreadsheet, .presentation,
    ] + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc"].compactMap { UTType($0) }

    /// Checked before `allowed`: these conform to an allowed type but their default handler can run code or change the system
    /// (a .command is text, an .svg or .xhtml opens in a browser, a profile stages in System Settings, .ics and .vcf import).
    private static let denied: [UTType] = [
        .executable, .application, .applicationBundle, .bundle, .package, .script, .html, .svg, .diskImage, .aliasFile,
        .symbolicLink, .internetLocation, .vCard, .calendarEvent,
    ] + ["com.apple.installer-package-archive", "com.apple.web-internet-location", "com.apple.file-location", "com.apple.mobileconfig",
         "com.apple.configprofile", "com.apple.provisionprofile", "com.apple.ical.ics", "public.xhtml"].compactMap { UTType($0) }

    /// The type a file is opened as: the one LaunchServices reports, or failing that its extension's.
    static func contentType(_ url: URL) -> UTType? {
        (try? url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
    }

    /// The file to open and the app to open it with: the checked, symlink-resolved file in its type's default app. A per-file
    /// "Open With" binding (an xattr a downloaded file can carry) is ignored, since it could name any app, an interpreter included.
    static func opener(for url: URL) -> (file: URL, app: URL)? {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileRefusal(file) == nil, let type = contentType(file), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return (file, app)
    }

    static func fileRefusal(_ url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var st = stat()
        guard lstat(resolved.path, &st) == 0 else { return "no such file" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "not a regular file" }
        guard st.st_mode & 0o111 == 0 else { return "executable file" }
        guard let type = contentType(resolved) else { return "unknown file type" }
        if denied.contains(where: { type.conforms(to: $0) }) { return "file type \(type.identifier) not allowed" }
        guard allowed.contains(where: { type.conforms(to: $0) }) else { return "file type \(type.identifier) not allowed" }
        return nil
    }
}
