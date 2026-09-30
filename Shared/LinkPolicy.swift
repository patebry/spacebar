import AppKit
import UniformTypeIdentifiers

/// What a link in a previewed document may open. The document is untrusted (a downloaded .md), and opening goes through the
/// unsandboxed writer, so a link may only reach a web page or an existing plain document: never an app, bundle, script,
/// installer, disk image, location file, or anything with an execute bit, whose default handler could run code.
enum LinkPolicy {
    static let maxURLBytes = 8192

    /// Why `url` may not be opened, or nil when it may. `allowArchives` only for the viewer's own Open button on the archive
    /// on screen: a link in a document never opens one (Archive Utility would extract it beside itself).
    static func refusal(_ url: URL, allowArchives: Bool = false) -> String? {
        guard url.absoluteString.utf8.count <= maxURLBytes else { return "URL too long" }
        switch url.scheme?.lowercased() {
        case "http", "https":
            return (url.host ?? "").isEmpty ? "no host" : nil
        case "file":
            return fileRefusal(url, allowArchives: allowArchives)
        default:
            return "scheme \(url.scheme ?? "none") not allowed"
        }
    }

    private static let allowed: [UTType] = [
        .plainText, .image, .audiovisualContent, .pdf, .rtf, .rtfd, .spreadsheet, .presentation, .json,
    ] + ["org.openxmlformats.wordprocessingml.document", "com.microsoft.word.doc", "public.yaml"].compactMap { UTType($0) }

    /// Allowed by exact type only: a property list's default app is an editor, but a type that conforms to one can run code
    /// when opened (a .terminal file runs its command in Terminal).
    private static let allowedExactlyAlways: [UTType] = [.propertyList]

    /// Archives, by exact type only: Archive Utility, their usual default app, only extracts. A type that merely conforms to
    /// one of these can run code when opened (a .jar is a zip, and opens in Jar Launcher), so conformance is not enough.
    private static let allowedExactly: [UTType] = [
        "public.zip-archive", "public.tar-archive", "org.gnu.gnu-zip-archive", "org.gnu.gnu-zip-tar-archive", "public.bzip2-archive",
        "org.tukaani.xz-archive", "org.7-zip.7-zip-archive", "public.tar-bzip2-archive", "org.tukaani.tar-xz-archive",
        "md.spacebar.type.rar", "md.spacebar.type.zst", "md.spacebar.type.tzst",
    ].compactMap { UTType($0) }

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
    static func opener(for url: URL, allowArchives: Bool = false) -> (file: URL, app: URL)? {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        guard fileRefusal(file, allowArchives: allowArchives) == nil, let type = contentType(file), let app = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return (file, app)
    }

    static func fileRefusal(_ url: URL, allowArchives: Bool = false) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var st = stat()
        guard lstat(resolved.path, &st) == 0 else { return "no such file" }
        // An RTFD is a package: the one folder that opens, in its word processor.
        if st.st_mode & S_IFMT == S_IFDIR, resolved.pathExtension.lowercased() == "rtfd", contentType(resolved) == .rtfd { return nil }
        guard st.st_mode & S_IFMT == S_IFREG else { return "not a regular file" }
        guard st.st_mode & 0o111 == 0 else { return "executable file" }
        guard let type = contentType(resolved) else { return "unknown file type" }
        if denied.contains(where: { type.conforms(to: $0) }) { return "file type \(type.identifier) not allowed" }
        guard allowed.contains(where: { type.conforms(to: $0) }) || allowedExactlyAlways.contains(type) || (allowArchives && allowedExactly.contains(type)) else {
            return "file type \(type.identifier) not allowed"
        }
        return nil
    }

    // MARK: opening a file in a text editor

    /// Types still refused in an editor: a browser-like or system handler could act on them even as text (a web page, a location
    /// file, a profile, a calendar or contact import), and anything that is not a single file. Scripts and executables are not
    /// here: an editor shows them, it never runs them.
    private static let deniedInEditor: [UTType] = [
        .application, .applicationBundle, .bundle, .package, .html, .svg, .diskImage, .aliasFile, .symbolicLink, .internetLocation, .vCard, .calendarEvent,
    ] + ["com.apple.installer-package-archive", "com.apple.web-internet-location", "com.apple.file-location", "com.apple.mobileconfig",
         "com.apple.configprofile", "com.apple.provisionprofile", "com.apple.ical.ics", "public.xhtml", "com.apple.terminal.settings"].compactMap { UTType($0) }

    /// Why the file at `url` may not be opened in a text editor, or nil. Looser than `fileRefusal` in one way only: a script, or
    /// a file with an execute bit, may open, because a text editor shows it and never runs it (its default app, Terminal or an
    /// interpreter, would). Types spacebar declares for files that often hold secrets (.env, .npmrc, a CSR: data, not text)
    /// never leave the preview.
    static func editorRefusal(_ url: URL) -> String? {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        var st = stat()
        guard lstat(resolved.path, &st) == 0 else { return "no such file" }
        guard st.st_mode & S_IFMT == S_IFREG else { return "not a regular file" }
        let type = contentType(resolved) ?? .data
        if deniedInEditor.contains(where: { type.conforms(to: $0) }) { return "file type \(type.identifier) not allowed in an editor" }
        if type.identifier.hasPrefix("md.spacebar.type."), !type.conforms(to: .text) { return "file type \(type.identifier) kept in the preview" }
        // LaunchServices sees no extension in a dotfile's name, so a plain `.env` or `.npmrc` is public.data, not the declared type.
        let name = resolved.lastPathComponent
        if resolved.pathExtension.isEmpty, name.hasPrefix("."), let t = UTType(filenameExtension: String(name.dropFirst())),
           t.identifier.hasPrefix("md.spacebar.type."), !t.conforms(to: .text) { return "file type \(t.identifier) kept in the preview" }
        return nil
    }

    /// Apps that are never an editor, whatever they declare: terminals and script runners open a file by running it.
    static let notEditors: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "io.alacritty", "org.alacritty",
        "com.github.wez.wezterm", "co.zeit.hyper", "com.mitchellh.ghostty", "com.apple.ScriptEditor2", "com.apple.Automator",
        "com.apple.automator.runner", "com.apple.installer", "org.python.PythonLauncher", "com.apple.archiveutility", "com.apple.systempreferences",
    ]
    private static let editorTypes: Set<String> = [
        "public.plain-text", "public.text", "public.source-code", "public.script", "public.shell-script", "public.python-script", "public.json",
        "public.xml", "public.yaml", "net.daringfireball.markdown",
    ]

    /// Whether the app at `app` is a text editor: it declares the Editor role for plain text, source code or Markdown, and is
    /// not a terminal or script runner. A browser (Viewer role) is not one: it would run a script it opens as a page.
    /// Office suites are never editors either: they sniff a file's content whatever its type and can run its macros.
    static let notEditorPrefixes = ["md.spacebar", "org.libreoffice", "org.openoffice", "com.microsoft.Word", "com.microsoft.Excel",
                                    "com.microsoft.Powerpoint", "com.apple.iWork."]

    static func isTextEditor(_ app: URL) -> Bool {
        guard let b = Bundle(url: app), let id = b.bundleIdentifier, !notEditors.contains(id),
              !notEditorPrefixes.contains(where: { id.lowercased().hasPrefix($0.lowercased()) }),
              let types = b.infoDictionary?["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
        return types.contains { d in
            guard d["CFBundleTypeRole"] as? String == "Editor" else { return false }
            let utis = d["LSItemContentTypes"] as? [String] ?? []
            let exts = (d["CFBundleTypeExtensions"] as? [String] ?? []).map { $0.lowercased() }
            return utis.contains(where: editorTypes.contains) || exts.contains { ["txt", "text", "md", "markdown"].contains($0) }
        }
    }

    /// The app with bundle ID `id`, preferring a copy in /Applications, /System/Applications or ~/Applications to one elsewhere
    /// (a copy in Downloads or on a mounted disk image may carry the same ID).
    static func application(_ id: String) -> URL? {
        let ws = NSWorkspace.shared
        let homeApps = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        let preferred = ["/Applications/", "/System/Applications/", homeApps]
        if #available(macOS 12.0, *) {
            let all = ws.urlsForApplications(withBundleIdentifier: id)
            if let u = all.first(where: { u in preferred.contains { u.resolvingSymlinksInPath().path.hasPrefix($0) } }) { return u }
        }
        return ws.urlForApplication(withBundleIdentifier: id)
    }

    /// What the viewer's Open button does with a file it shows as text (code, JSON, CSV, text): open it in `editor` (the bundle ID
    /// chosen in the settings) when that is a text editor; else in its default app when `opener` allows that; else in the default
    /// plain-text app when that is a text editor. `editor` true when the app is opened as an editor. Nil: nothing may open it.
    static func textOpener(for url: URL, editor id: String?) -> (file: URL, app: URL, editor: Bool)? {
        let file = url.standardizedFileURL.resolvingSymlinksInPath()
        let ws = NSWorkspace.shared
        if let id, editorRefusal(file) == nil, let app = application(id), isTextEditor(app) { return (file, app, true) }
        if let o = opener(for: file) { return (o.file, o.app, false) }
        if editorRefusal(file) == nil, let app = ws.urlForApplication(toOpen: .plainText), isTextEditor(app) { return (file, app, true) }
        return nil
    }
}
