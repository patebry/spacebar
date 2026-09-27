import Foundation
import UniformTypeIdentifiers

/// What a file is, from its name alone: the sidebar's icon, how the panel previews it, and the content type the `file` host
/// serves it as. Nothing here reads the file; a file of an unknown kind is sniffed as text or not when it is opened.
enum FileKind: String {
    case folder, markdown, image, pdf, code, json, csv, text, app, other

    /// One of the sidebar's eight icons.
    var icon: String {
        switch self {
        case .json, .csv: return "data"
        case .app: return "other"
        default: return rawValue
        }
    }
}

enum FileTypes {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    /// Rendered as `<img>` only. SVG is here: as an image it runs no script.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico", "svg"]
    static let jsonExtensions: Set<String> = ["json", "geojson", "jsonc", "json5", "webmanifest", "har", "ipynb"]
    static let csvExtensions: Set<String> = ["csv", "tsv"]
    static let textExtensions: Set<String> = ["txt", "text", "log", "out", "err", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt", "nfo",
                                              "diz", "cfg", "conf", "properties", "lock", "sum", "mod", "example", "sample", "gitignore",
                                              "gitattributes", "gitmodules", "dockerignore", "editorconfig", "npmrc", "nvmrc", "env", "csr", "pem"]
    /// Source code, by extension, with its highlight.js language (nil: shown as plain text with line numbers).
    static let codeLanguages: [String: String?] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript", "ts": "typescript", "mts": "typescript",
        "cts": "typescript", "tsx": "typescript", "py": "python", "pyi": "python", "rb": "ruby", "go": "go", "rs": "rust", "swift": "swift",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ksh": "bash", "command": "bash", "c": "c", "h": "c", "m": "objectivec",
        "mm": "objectivec", "cc": "cpp", "cpp": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp", "java": "java", "kt": "kotlin",
        "kts": "kotlin", "cs": "csharp", "css": "css", "scss": "scss", "sass": "scss", "less": "less", "html": "xml", "htm": "xml",
        "xhtml": "xml", "xml": "xml", "plist": "xml", "xsd": "xml", "xsl": "xml", "vue": "xml", "svelte": "xml", "yaml": "yaml",
        "yml": "yaml", "toml": "ini", "ini": "ini", "sql": "sql", "php": "php", "pl": "perl", "pm": "perl", "lua": "lua", "r": "r",
        "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff", "mk": "makefile", "gradle": "java", "groovy": "java",
        "vb": "vbnet", "wat": "wasm", "dart": nil, "scala": nil, "ex": nil, "exs": nil, "erl": nil, "hs": nil, "clj": nil, "ml": nil,
        "zig": nil, "nim": nil, "proto": nil, "tf": nil, "hcl": nil, "cmake": nil, "bat": nil, "ps1": nil, "applescript": nil,
    ]
    /// Files known by their whole name (lowercased), with their language.
    static let codeNames: [String: String?] = [
        "dockerfile": nil, "containerfile": nil, "makefile": "makefile", "gnumakefile": "makefile", "gemfile": "ruby", "rakefile": "ruby",
        "podfile": "ruby", "brewfile": "ruby", "vagrantfile": "ruby", "fastfile": "ruby", "procfile": nil, "jenkinsfile": nil,
        "justfile": nil, ".bashrc": "bash", ".zshrc": "bash", ".profile": "bash", ".bash_profile": "bash", ".zprofile": "bash",
    ]
    static let textNames: Set<String> = ["license", "licence", "copying", "authors", "contributors", "changelog", "changes", "news",
                                         "notice", "readme", "todo", "version", "codeowners", ".env.example", "env.example"]
    static let appExtensions: Set<String> = ["app", "pkg", "mpkg", "dmg", "exe", "msi", "dylib", "so", "o", "a", "bin", "workflow",
                                             "shortcut", "prefpane", "appex", "kext", "framework", "bundle", "plugin", "qlgenerator", "saver"]

    /// The explicit map behind every `file` URL; anything missing is application/octet-stream, which the `file` host never serves.
    static let contentTypes: [String: String] = [
        "png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp", "heic": "image/heic",
        "heif": "image/heif", "avif": "image/avif", "bmp": "image/bmp", "tif": "image/tiff", "tiff": "image/tiff", "ico": "image/x-icon",
        "svg": "image/svg+xml", "pdf": "application/pdf",
    ]
    static let octetStream = "application/octet-stream"
    /// Past these an image or any other file gets the info card, and the `file` host does not serve it.
    static let maxImageBytes: Int64 = 50 << 20
    static let maxFileBytes: Int64 = 512 << 20
    /// Text and code past this show their first 2 MB, with a note.
    static let maxTextBytes = 2 << 20

    /// The `file` URL of an absolute path, as the page loads it; `version` busts the cache after a change on disk.
    static func fileURL(_ path: String, version: String? = nil) -> URL? {
        var c = URLComponents()
        c.scheme = "spacebar"
        c.host = "file"
        c.path = path
        if let version { c.queryItems = [URLQueryItem(name: "v", value: version)] }
        return c.url
    }

    static func contentType(forPath path: String) -> String {
        contentTypes[(path as NSString).pathExtension.lowercased()] ?? octetStream
    }

    /// The kind of `name`. A package (an app, a document bundle) is a single item, never a folder to expand.
    static func kind(name: String, isDirectory: Bool = false, isPackage: Bool = false, executable: Bool = false) -> FileKind {
        let ext = (name as NSString).pathExtension.lowercased()
        if isDirectory && !isPackage { return .folder }
        if isDirectory { return ext == "app" || appExtensions.contains(ext) ? .app : .other }
        let lower = name.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if jsonExtensions.contains(ext) { return .json }
        if csvExtensions.contains(ext) { return .csv }
        if codeLanguages[ext] != nil || codeNames[lower] != nil || lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return .code }
        if textNames.contains(lower) || textNames.contains((lower as NSString).deletingPathExtension) || textExtensions.contains(ext)
            || (lower.hasPrefix(".env.") && lower.hasSuffix("example")) { return .text }
        if appExtensions.contains(ext) || (executable && ext.isEmpty) { return .app }
        return .other
    }

    /// The highlight.js language of a code file, or nil for plain text.
    static func language(name: String) -> String? {
        let lower = name.lowercased()
        if let l = codeNames[lower] { return l }
        if lower.hasPrefix("dockerfile.") || lower.hasSuffix(".dockerfile") { return nil }
        if let l = codeLanguages[(lower as NSString).pathExtension] { return l }
        return nil
    }

    /// Whether the bytes look like text: no NUL in them and valid UTF-8 apart from a character cut at the end.
    static func looksLikeText(_ data: Data) -> Bool {
        let head = data.prefix(8192)
        if head.contains(0) { return false }
        if String(data: head, encoding: .utf8) != nil { return true }
        // A multi-byte character may be cut at the end of the sample.
        for cut in 1...3 where head.count > cut {
            if String(data: head.dropLast(cut), encoding: .utf8) != nil { return true }
        }
        return false
    }
}

/// What the page is sent to show a file: `view` says how (markdown, image, pdf, code, json, csv, text or info), and nothing in
/// it is ever rendered as HTML. A PDF is drawn natively (PDFPane); the page only reserves its place.
enum FileView {
    /// What every render names: the file, its folder as the page's base URL, and the sidebar's root.
    static func base(path: String, root: String, reason: String) -> [String: Any] {
        ["path": path, "base": FileTypes.fileURL((path as NSString).deletingLastPathComponent + "/")!.absoluteString,
         "name": (path as NSString).lastPathComponent, "reason": reason, "root": root, "rootName": (root as NSString).lastPathComponent]
    }

    /// A file that is not Markdown. `canOpen`: whether the link policy lets the writer open it (else Reveal in Finder only).
    static func payload(path: String, kind: FileKind, root: String, reason: String, canOpen: Bool) -> [String: Any] {
        var p = base(path: path, root: root, reason: reason)
        var st = stat()
        guard stat(path, &st) == 0 else { p["view"] = "info"; return p }
        let regular = st.st_mode & S_IFMT == S_IFREG
        let size = Int64(st.st_size)
        let ext = (path as NSString).pathExtension
        p["size"] = regular ? size : NSNull()
        p["modified"] = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec / 1_000_000)
        let type = UTType(filenameExtension: ext)
        p["kindName"] = type.flatMap(\.localizedDescription) ?? (regular ? "Document" : "Folder")
        p["icon"] = kind.icon
        p["canOpen"] = canOpen
        // A text file whose extension the system takes for something else (.ts is also an MPEG transport stream) is named by
        // what it holds, and is never handed to that other type's app.
        if [.code, .json, .csv, .text].contains(kind), type?.conforms(to: .text) != true {
            p["kindName"] = kind == .code ? "Source code" : "Plain text"
            p["canOpen"] = false
        }
        var view = "info"
        let version = "\(st.st_mtimespec.tv_sec)\(st.st_mtimespec.tv_nsec)"
        switch kind {
        case .image where regular && size <= FileTypes.maxImageBytes:
            view = "image"
            p["src"] = FileTypes.fileURL(path, version: version)!.absoluteString
        case .pdf where regular && size <= FileTypes.maxFileBytes:
            view = "pdf"
        case .code, .json, .csv, .text, .other, .app:
            // O_NONBLOCK and fstat: a file swapped for a FIFO since the stat can neither hang the open nor be read.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard regular, size > 0 || kind != .other, fd >= 0 else { if fd >= 0 { close(fd) }; break }
            var fst = stat()
            guard fstat(fd, &fst) == 0, fst.st_mode & S_IFMT == S_IFREG else { close(fd); break }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = (try? h.read(upToCount: FileTypes.maxTextBytes)) ?? Data()
            guard size == 0 || FileTypes.looksLikeText(data) else { break }
            view = kind == .code ? "code" : kind == .json ? "json" : kind == .csv ? "csv" : "text"
            p["text"] = String(decoding: data, as: UTF8.self)
            p["truncated"] = size > FileTypes.maxTextBytes
            p["lang"] = kind == .code ? FileTypes.language(name: (path as NSString).lastPathComponent) ?? NSNull() : NSNull()
            if ext.lowercased() == "tsv" { p["tsv"] = true }
        default:
            break
        }
        p["view"] = view
        return p
    }
}

/// One folder of the sidebar's tree, for a single file and a folder alike: folders first, then files, each sorted by `sort`
/// ("name", or "modified", newest first), with a README first among the files when `readmeFirst`.
///
/// Hidden files (a leading dot or the hidden flag) are skipped unless `showHidden`. A symbolic link is listed only when it
/// resolves inside the root to a regular file or a folder, so the tree never reaches outside the root. FIFOs, sockets and
/// devices are skipped. A package (an app, a document bundle) is listed as one item. At most `cap` entries are listed and `more`
/// counts the rest.
enum FolderListing {
    static let markdownExtensions = FileTypes.markdownExtensions
    static let cap = 500
    /// Past this many names a folder is listed from its first names only (see `list`).
    static let statCap = 5_000
    static let maxDocumentBytes = 64 << 20

    struct Entry: Equatable {
        let name: String
        /// `dir/name`: the path the page shows and asks to open or expand.
        let path: String
        let isDirectory: Bool
        let kind: FileKind
        let size: Int64
        let modified: Double

        var isMarkdown: Bool { kind == .markdown }
    }

    struct Listing: Equatable {
        let dir: String
        let entries: [Entry]
        let more: Int

        var files: [Entry] { entries.filter { !$0.isDirectory } }
        var folders: [Entry] { entries.filter(\.isDirectory) }

        /// What the page is sent for this folder of the tree rooted at `root`.
        func payload(root: String) -> [String: Any] {
            ["root": root, "rootName": (root as NSString).lastPathComponent, "dir": dir,
             "entries": entries.map { ["name": $0.name, "path": $0.path, "dir": $0.isDirectory, "icon": $0.kind.icon] as [String: Any] },
             "more": more]
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// Whether `path`, symlinks resolved, is `root` itself or inside it (`root` is resolved too).
    static func isInside(_ path: String, root: String, allowRoot: Bool = false) -> Bool {
        guard let real = realPath(path), let r = realPath(root) else { return false }
        return (allowRoot && real == r) || real.hasPrefix(r == "/" ? "/" : r + "/")
    }

    /// Whether `path` is spelled as a plain path at or below `root`: absolute, no `.` or `..` step, no empty component.
    static func isPlainPath(_ path: String, under root: String) -> Bool {
        guard path == root || path.hasPrefix(root == "/" ? "/" : root + "/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        return !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." } || path == "/"
    }

    static func isReadme(_ name: String) -> Bool { (name as NSString).deletingPathExtension.lowercased() == "readme" }

    static func isHidden(_ name: String, _ st: stat) -> Bool { name.hasPrefix(".") || st.st_flags & UInt32(UF_HIDDEN) != 0 }

    /// Reads one folder of the tree rooted at `root`; call it off the main thread. `pinned` (the document on screen) is listed
    /// even past the cap. A folder outside the root lists nothing.
    static func list(_ dir: String, root: String? = nil, sort: String, readmeFirst: Bool, showHidden: Bool = false, cap: Int = cap,
                     pinned: String? = nil) -> Listing {
        let root = root ?? dir
        guard let realRoot = realPath(root), isInside(dir, root: root, allowRoot: true) else { return Listing(dir: dir, entries: [], more: 0) }
        let inside = realRoot == "/" ? "/" : realRoot + "/"
        var names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        // A huge folder: only the first `statCap` names (by name) are looked at; the rest are counted, never stat'ed.
        var unseen = 0
        if names.count > statCap {
            names.sort()
            unseen = names.count - statCap
            let pin = pinned.map { ($0 as NSString).lastPathComponent }
            let keep = names.prefix(statCap)
            if let pin, (pinned as NSString?)?.deletingLastPathComponent == dir, !keep.contains(pin), names.contains(pin) {
                names = Array(keep) + [pin]
                unseen -= 1
            } else {
                names = Array(keep)
            }
        }
        var found: [Entry] = []
        for name in names {
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0 else { continue }
            if !showHidden && isHidden(name, st) { continue }
            if st.st_mode & S_IFMT == S_IFLNK {
                guard let real = realPath(path), real.hasPrefix(inside), stat(real, &st) == 0 else { continue }
                // A link to a folder that holds the link itself would nest without end.
                if st.st_mode & S_IFMT == S_IFDIR, let parent = realPath(dir), (parent + "/").hasPrefix(real + "/") { continue }
            }
            let type = st.st_mode & S_IFMT
            guard type == S_IFREG || type == S_IFDIR else { continue }
            let isDir = type == S_IFDIR
            let isPackage = isDir && !(name as NSString).pathExtension.isEmpty
                && ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false)
            let kind = FileTypes.kind(name: name, isDirectory: isDir, isPackage: isPackage, executable: st.st_mode & 0o111 != 0)
            let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            found.append(Entry(name: name, path: path, isDirectory: kind == .folder, kind: kind, size: isDir ? 0 : Int64(st.st_size), modified: modified))
        }
        found.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            if sort == "modified", a.modified != b.modified { return a.modified > b.modified }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        if readmeFirst, let i = found.firstIndex(where: { !$0.isDirectory && $0.kind == .markdown && isReadme($0.name) }),
           let first = found.firstIndex(where: { !$0.isDirectory }) {
            found.insert(found.remove(at: i), at: first)
        }
        var shown = Array(found.prefix(max(cap, 0)))
        if let pinned, !shown.contains(where: { $0.path == pinned }), let pin = found.first(where: { $0.path == pinned }) {
            shown.append(pin)
        }
        return Listing(dir: dir, entries: shown, more: found.count - shown.count + unseen)
    }

    /// The Markdown file a folder preview opens on when the folder itself holds one: its README, else its first Markdown file in
    /// the sidebar's order. Nil sends the preview to FolderScan.
    static func firstDocument(_ l: Listing) -> Entry? {
        l.files.first { $0.isMarkdown && isReadme($0.name) } ?? l.files.first(where: \.isMarkdown)
    }
}

/// Watches a folder for files added, removed or renamed (a directory's vnode reports those as writes), 100 ms debounce. A folder
/// that is itself deleted or renamed is no longer watched.
final class FolderWatch {
    private var source: DispatchSourceFileSystemObject?
    private var pending = false

    init?(path: String, onChange: @escaping () -> Void) {
        let fd = open(path, O_EVTONLY | O_NONBLOCK | O_DIRECTORY)
        guard fd >= 0 else { return nil }
        let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .link, .delete, .rename], queue: .main)
        src.setEventHandler { [weak self, unowned src] in
            guard let self else { return }
            if !src.data.isDisjoint(with: [.delete, .rename]) { src.cancel(); self.source = nil; return }
            guard !self.pending else { return }
            self.pending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                guard let self, self.source != nil else { return }
                self.pending = false
                onChange()
            }
        }
        src.setCancelHandler { close(fd) }
        src.resume()
        source = src
    }

    deinit { source?.cancel() }
}
