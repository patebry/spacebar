import Foundation
import UniformTypeIdentifiers

/// What a file is, from its name alone: the sidebar's icon, how the panel previews it, and the content type the `file` host
/// serves it as. Nothing here reads the file; a file of an unknown kind is sniffed as text or not when it is opened.
enum FileKind: String {
    case folder, markdown, image, pdf, html, video, audio, code, json, csv, text, archive, app, other

    /// One of the nine icons the folder overview counts by.
    var icon: String {
        switch self {
        case .json, .csv: return "data"
        case .html: return "code"
        case .video, .audio: return "media"
        case .app, .archive: return "other"
        default: return rawValue
        }
    }
}

enum FileTypes {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    static let htmlExtensions: Set<String> = ["html", "htm"]
    /// Played by AVFoundation. WebM, Ogg and Matroska are not: AVFoundation cannot open them.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "caf"]
    /// Rendered as `<img>` only. SVG is here: as an image it runs no script.
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "avif", "bmp", "tif", "tiff", "ico", "svg"]
    static let jsonExtensions: Set<String> = ["json", "geojson", "jsonc", "json5", "webmanifest", "har", "ipynb"]
    static let csvExtensions: Set<String> = ["csv", "tsv"]
    /// Listed by the writer with bsdtar. A lone compressed file (notes.txt.gz) is shown as the one file it holds.
    static let archiveExtensions: Set<String> = ["zip", "tar", "gz", "gzip", "tgz", "bz2", "bz", "tbz", "tbz2", "xz", "txz", "7z", "rar", "zst", "tzst"]
    static let textExtensions: Set<String> = ["txt", "text", "log", "out", "err", "rst", "adoc", "asciidoc", "org", "tex", "bib", "srt", "vtt", "nfo",
                                              "diz", "cfg", "conf", "properties", "lock", "sum", "mod", "example", "sample", "gitignore",
                                              "gitattributes", "gitmodules", "dockerignore", "editorconfig", "npmrc", "nvmrc", "env", "csr", "pem"]
    /// Source code, by extension, with its highlight.js language (nil: shown as plain text with line numbers).
    static let codeLanguages: [String: String?] = [
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "jsx": "javascript", "ts": "typescript", "mts": "typescript",
        "javascript": "javascript", "jscript": "javascript",
        "cts": "typescript", "tsx": "typescript", "py": "python", "pyi": "python", "rb": "ruby", "rbw": "ruby", "go": "go", "rs": "rust", "swift": "swift",
        "sh": "bash", "bash": "bash", "zsh": "bash", "fish": "bash", "ksh": "bash", "command": "bash", "tool": "bash", "c": "c", "h": "c", "m": "objectivec",
        "mm": "objectivec", "cc": "cpp", "cp": "cpp", "cpp": "cpp", "cxx": "cpp", "c++": "cpp", "hpp": "cpp", "hp": "cpp", "hh": "cpp", "hxx": "cpp", "h++": "cpp",
        "ipp": "cpp", "java": "java", "jav": "java", "kt": "kotlin",
        "kts": "kotlin", "cs": "csharp", "css": "css", "scss": "scss", "sass": "scss", "less": "less", "html": "xml", "htm": "xml",
        "xhtml": "xml", "xml": "xml", "plist": "xml", "xsd": "xml", "xsl": "xml", "vue": "xml", "svelte": "xml", "yaml": "yaml",
        "yml": "yaml", "toml": "ini", "ini": "ini", "sql": "sql", "php": "php", "php3": "php", "php4": "php", "ph3": "php", "ph4": "php", "phtml": "php", "pl": "perl", "pm": "perl", "lua": "lua", "r": "r",
        "graphql": "graphql", "gql": "graphql", "diff": "diff", "patch": "diff", "mk": "makefile", "mak": "makefile", "make": "makefile", "gmk": "makefile", "gradle": "java", "groovy": "java",
        "vb": "vbnet", "wat": "wasm", "dart": nil, "scala": nil, "ex": nil, "exs": nil, "erl": nil, "hs": nil, "clj": nil, "ml": nil,
        "zig": nil, "nim": nil, "proto": nil, "tf": nil, "hcl": nil, "cmake": nil, "bat": nil, "ps1": nil, "applescript": nil, "dockerfile": nil,
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
    /// Kinds shown as `.other` that still get an icon of their own in the sidebar and on the info card.
    static let glyphExtensions: [String: Set<String>] = [
        "font": ["ttf", "otf", "woff", "woff2", "ttc", "dfont", "fon", "pfb"],
        "doc": ["doc", "docx", "pages", "rtf", "rtfd", "odt", "wpd", "epub"],
        "sheet": ["xls", "xlsx", "xlsm", "numbers", "ods"],
        "slides": ["ppt", "pptx", "key", "odp"],
        "model": ["obj", "stl", "usdz", "usd", "usda", "usdc", "fbx", "glb", "gltf", "3ds", "dae", "blend", "ply", "reality", "3mf"],
        "video": ["webm", "mkv", "avi", "ogv", "wmv", "flv", "mpg", "mpeg", "3gp", "m2v"],
        "audio": ["ogg", "oga", "opus", "wma", "mid", "midi", "ape", "alac"],
    ]

    /// The sidebar's and info card's icon: finer than `FileKind.icon`, from the kind and then the extension.
    static func glyph(name: String, kind: FileKind) -> String {
        switch kind {
        case .folder, .markdown, .image, .pdf, .code, .text, .archive, .app, .video, .audio: return kind.rawValue
        case .html: return "code"
        case .json, .csv: return "data"
        default:
            let ext = (name as NSString).pathExtension.lowercased()
            return glyphExtensions.first { $0.value.contains(ext) }?.key ?? "other"
        }
    }

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
        if htmlExtensions.contains(ext) { return .html }
        if videoExtensions.contains(ext) { return .video }
        if audioExtensions.contains(ext) { return .audio }
        if jsonExtensions.contains(ext) { return .json }
        if csvExtensions.contains(ext) { return .csv }
        if archiveExtensions.contains(ext) { return .archive }
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

    /// Runs `body` with this thread allowed to download a file iCloud has evicted (dataless). Quick Look starts the extension
    /// with materialization off for the whole process, so without this every read of an evicted file other than the one Finder
    /// previewed fails with EDEADLK: a sidebar click does nothing, a CSV shows empty, a PDF shows its info card.
    static func materializing<T>(_ body: () throws -> T) rethrows -> T {
        let type = IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES
        let old = getiopolicy_np(type, IOPOL_SCOPE_THREAD)
        setiopolicy_np(type, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_ON)
        defer { setiopolicy_np(type, IOPOL_SCOPE_THREAD, old >= 0 ? old : IOPOL_MATERIALIZE_DATALESS_FILES_DEFAULT) }
        return try body()
    }

    /// Whether iCloud has evicted the file at `path` (it reads only after a download). stat reads the flag without downloading.
    static func isDataless(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_flags & 0x4000_0000 != 0
    }
}

/// Runs a file read off the main thread; results come back on the main thread. The read decides what it downloads from iCloud
/// (`materializing` around exactly those reads), so an evicted file it only stats is never fetched. One load at a time: a new
/// load or `cancel` drops the one in flight, and a load with `timesOut` still running after `timeout` reports `.timedOut`
/// instead. A read blocked on a download cannot be interrupted: its thread finishes on its own and its result is dropped.
/// Main thread only.
final class FileLoader {
    enum Outcome<T> { case done(T), timedOut }
    static let downloadTimeout: TimeInterval = 15
    static let queue = DispatchQueue(label: "md.spacebar.read", qos: .userInitiated, attributes: .concurrent)
    let timeout: TimeInterval
    private var active = 0
    private var issued = 0

    init(timeout: TimeInterval = FileLoader.downloadTimeout) { self.timeout = timeout }

    /// Whether load `id` is still the one in flight.
    func isActive(_ id: Int) -> Bool { id != 0 && active == id }

    @discardableResult
    func load<T>(timesOut: Bool = true, _ read: @escaping () -> T, done: @escaping (Outcome<T>) -> Void) -> Int {
        dispatchPrecondition(condition: .onQueue(.main))
        issued += 1
        let id = issued
        active = id
        Self.queue.async {
            let r = read()
            DispatchQueue.main.async { [weak self] in
                guard let self, self.active == id else { return }
                self.active = 0
                done(.done(r))
            }
        }
        guard timesOut else { return id }
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, self.active == id else { return }
            self.active = 0
            done(.timedOut)
        }
        return id
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        active = 0
    }
}

/// What the page is sent to show a file: `view` says how (markdown, image, pdf, html, video, audio, code, json, csv, text or info),
/// and nothing in it is ever rendered as HTML. A PDF, an HTML file and media are drawn natively; the page only reserves their place.
enum FileView {
    /// What every render names: the file, its folder as the page's base URL, and the sidebar's root.
    static func base(path: String, root: String, reason: String) -> [String: Any] {
        ["path": path, "base": FileTypes.fileURL((path as NSString).deletingLastPathComponent + "/")!.absoluteString,
         "name": (path as NSString).lastPathComponent, "reason": reason, "root": root, "rootName": (root as NSString).lastPathComponent]
    }

    /// A Markdown document's text, downloaded first when iCloud has evicted it.
    static func readDocument(_ url: URL) throws -> String {
        try FileTypes.materializing { try String(contentsOf: url, encoding: .utf8) }
    }

    /// The info card of a file that could not be read in time: `cloud` when iCloud had it evicted (a download that did not
    /// finish, or no network). Reveal in Finder only. Nothing here reads the file.
    static func unavailable(path: String, kind: FileKind, root: String, reason: String, cloud: Bool) -> [String: Any] {
        var p = base(path: path, root: root, reason: reason)
        var st = stat()
        if stat(path, &st) == 0 {
            p["size"] = st.st_mode & S_IFMT == S_IFREG ? Int64(st.st_size) : NSNull()
            p["modified"] = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec / 1_000_000)
        }
        p["kindName"] = UTType(filenameExtension: (path as NSString).pathExtension).flatMap(\.localizedDescription) ?? "Document"
        p["icon"] = FileTypes.glyph(name: (path as NSString).lastPathComponent, kind: kind)
        p["canOpen"] = false
        p["view"] = "info"
        p["note"] = cloud ? "This file is in iCloud and couldn’t be downloaded." : "This file couldn’t be read."
        return p
    }

    /// A binary property list as XML text, or nil when `data` is not a whole binary plist (a file cut at 2 MB is not). A
    /// binary plist can name one object many times, so a small file can stand for an exponentially large tree, or one large
    /// string or blob written out thousands of times: past `maxPlistNodes` objects, or an estimate of `maxTextBytes` of XML
    /// (text as is, data as base64, a tag's worth per object), counted as written out, it is not converted.
    static let maxPlistNodes = 100_000
    static func binaryPlistAsXML(_ data: Data) -> Data? {
        guard data.starts(with: Data("bplist".utf8)),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) else { return nil }
        var nodes = maxPlistNodes
        var bytes = FileTypes.maxTextBytes
        func fits(_ o: Any) -> Bool {
            nodes -= 1
            bytes -= 16
            switch o {
            case let s as String: bytes -= s.utf8.count
            case let d as Data: bytes -= (d.count + 2) / 3 * 4
            default: break
            }
            if nodes < 0 || bytes < 0 { return false }
            if let a = o as? [Any] { return a.allSatisfy(fits) }
            if let d = o as? [String: Any] { return d.allSatisfy { fits($0.key) && fits($0.value) } }
            return true
        }
        guard fits(obj), let xml = try? PropertyListSerialization.data(fromPropertyList: obj, format: .xml, options: 0),
              xml.count <= FileTypes.maxTextBytes else { return nil }
        return xml
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
        p["icon"] = FileTypes.glyph(name: (path as NSString).lastPathComponent, kind: kind)
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
        case .html where regular && size <= FolderListing.maxDocumentBytes:
            view = "html"
        case .video where regular && size <= FileTypes.maxFileBytes, .audio where regular && size <= FileTypes.maxFileBytes:
            view = kind.rawValue
        // Its contents come later, from the writer. An archive in iCloud is not downloaded to list it.
        case .archive where regular && !FileTypes.isDataless(path):
            view = "archive"
        case .code, .json, .csv, .text, .other, .app:
            // O_NONBLOCK and fstat: a file swapped for a FIFO since the stat can neither hang the open nor be read.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            guard regular, size > 0 || kind != .other, fd >= 0 else { if fd >= 0 { close(fd) }; break }
            var fst = stat()
            guard fstat(fd, &fst) == 0, fst.st_mode & S_IFMT == S_IFREG else { close(fd); break }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let read = { try? h.read(upToCount: FileTypes.maxTextBytes) ?? Data() }
            // Only a text kind is downloaded when evicted, and within Markdown's bound: the download is the whole file, and
            // anything else only turns into its info card.
            let fetch = [.code, .json, .csv, .text].contains(kind) && size <= FolderListing.maxDocumentBytes
            guard var data = fetch ? FileTypes.materializing(read) : read() else { break }
            if ext.lowercased() == "plist", let xml = FileView.binaryPlistAsXML(data) {
                data = xml
                p["kindName"] = "Binary property list, shown as XML"
            }
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
    /// The page draws only the rows in view, so a listing this long costs its transfer, not its drawing.
    static let cap = 5_000
    /// Past this many names a folder is listed from its first names only (see `list`).
    static let statCap = 10_000
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
             "entries": entries.map { e -> [String: Any] in
                 var d: [String: Any] = ["name": e.name, "path": e.path, "dir": e.isDirectory, "icon": FileTypes.glyph(name: e.name, kind: e.kind),
                                         "modified": (e.modified * 1000).rounded()]
                 if !e.isDirectory { d["size"] = e.size }
                 return d
             },
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
