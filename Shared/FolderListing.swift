import Foundation
import UniformTypeIdentifiers

/// What a file is, from its name alone: the sidebar's icon, how the panel previews it, and the content type the `file` host
/// serves it as. Nothing here reads the file; a file of an unknown kind is sniffed as text or not when it is opened.
enum FileKind: String {
    case folder, markdown, image, pdf, html, video, audio, code, json, csv, text, rtf, archive, app, other

    /// One of the nine icons the folder overview counts by.
    var icon: String {
        switch self {
        case .json, .csv: return "data"
        case .rtf: return "text"
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
    /// Played by AVFoundation (test/mediapane plays each). WebM, Ogg, Opus and Matroska are not: AVFoundation cannot open them.
    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "3gp", "mpg", "mpeg", "m2v"]
    static let audioExtensions: Set<String> = ["mp3", "m4a", "m4b", "aac", "wav", "aif", "aiff", "flac", "caf", "amr"]
    /// Media AVFoundation cannot play, by the name its info card gives it where macOS declares no type.
    static let unplayableMedia: [String: String] = ["webm": "WebM video", "mkv": "Matroska video", "mka": "Matroska audio", "ogg": "Ogg audio",
                                                    "oga": "Ogg audio", "ogv": "Ogg video", "opus": "Opus audio", "avi": "AVI movie",
                                                    "wmv": "Windows Media video", "wma": "Windows Media audio", "flv": "Flash video"]
    /// Images. SVG is here: as an image (`<img>`) it runs no script.
    static let imageExtensions = Set(["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico", "svg"]).union(nativeImageExtensions)
    /// Images the panel decodes with ImageIO (Preview/ImagePane.swift) rather than as `<img>`: WebKit's decoding of these is
    /// missing (RAW, PSD, EXR, TGA, JPEG 2000, ICNS) or unreliable (HEIC, AVIF and TIFF, above all on macOS 13).
    static let nativeImageExtensions: Set<String> = ["heic", "heif", "avif", "tif", "tiff", "dng", "cr2", "cr3", "nef", "arw", "orf", "raf", "rw2",
                                                     "psd", "exr", "tga", "jp2", "icns"]
    static let jsonExtensions: Set<String> = ["json", "geojson", "jsonc", "json5", "webmanifest", "har", "ipynb"]
    static let csvExtensions: Set<String> = ["csv", "tsv"]
    /// Drawn natively from AppKit's RTF reader. `.rtfd` is a package (a folder) or, flattened, a single file.
    static let richTextExtensions: Set<String> = ["rtf", "rtfd"]
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
        "video": ["webm", "mkv", "avi", "ogv", "wmv", "flv"],
        "audio": ["ogg", "oga", "opus", "wma", "mid", "midi", "ape", "alac"],
    ]

    /// The sidebar's and info card's icon: finer than `FileKind.icon`, from the kind and then the extension.
    static func glyph(name: String, kind: FileKind) -> String {
        switch kind {
        case .folder, .markdown, .image, .pdf, .code, .text, .archive, .app, .video, .audio: return kind.rawValue
        case .html: return "code"
        case .rtf: return "doc"
        case .json, .csv: return "data"
        default:
            let ext = (name as NSString).pathExtension.lowercased()
            return glyphExtensions.first { $0.value.contains(ext) }?.key ?? "other"
        }
    }

    /// Shown by Apple's own Quick Look in a QLPreviewView over the panel (Preview/QLFallbackPane.swift): a file of no kind of
    /// spacebar's own whose declared type Quick Look may have a generator for (Office, iWork, fonts, 3D, certificates, calendars,
    /// e-books). QLPreviewView hands a file to whichever extension Quick Look would pick, spacebar included, so a type spacebar
    /// claims, or one that conforms to a type it claims, is never shown this way (test/qlpane checks every claim). Nor is a folder,
    /// a package (bar iWork's documents), an app, an archive or a disk image, anything spacebar shows itself, web content or mail
    /// (Apple's previews of those load what they link to), or a vCard: its preview reads Contacts in this process.
    static func appleQuickLookType(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, let claims = quickLookClaims,
              let t = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.contentTypeKey]).contentType else { return nil }
        let isDir = st.st_mode & S_IFMT == S_IFDIR
        guard kind(name: (path as NSString).lastPathComponent, isDirectory: isDir, isPackage: isDir, executable: st.st_mode & 0o111 != 0) == .other
        else { return nil }
        return quickLookEligible(t, claims: claims) ? t.identifier : nil
    }

    /// iWork's package documents: the one kind of package Quick Look is asked to show.
    static let quickLookPackages: Set<String> = ["com.apple.iwork.pages.pages", "com.apple.iwork.numbers.numbers", "com.apple.iwork.keynote.key"]
    static let quickLookRefused: [UTType] = [.folder, .directory, .package, .bundle, .application, .executable, .archive, .zip, .diskImage,
                                             .plainText, .sourceCode, .script, .json, .xml, .html, .propertyList, .image, .audiovisualContent,
                                             .pdf, .rtf, .rtfd, .flatRTFD, .webArchive, .emailMessage, .vCard, .symbolicLink, .aliasFile]
        + ["com.apple.mail.email", "com.apple.mail.emlx", "com.apple.log"].compactMap { UTType($0) }

    static func quickLookEligible(_ t: UTType, claims: Set<String>) -> Bool {
        guard t.isDeclared, !t.isDynamic, !claims.contains(t.identifier) else { return false }
        // Folders are refused below, iWork's packages aside; everything is data.
        let claimed = claims.compactMap { [UTType.data, .folder, .directory].map(\.identifier).contains($0) ? nil : UTType($0) }
        if claimed.contains(where: { t.conforms(to: $0) }) { return false }
        if quickLookPackages.contains(t.identifier) { return true }
        // Text stays on spacebar's text view (.strings, .pbxproj, playlists, crash reports), bar the text formats Apple draws.
        if t.conforms(to: .text), !quickLookDrawnText.contains(t.identifier) { return false }
        return !quickLookRefused.contains { t.conforms(to: $0) }
    }
    /// Declared as text, but Apple's preview draws them: a calendar's events and a Wavefront model.
    static let quickLookDrawnText: Set<String> = ["com.apple.ical.ics", "public.geometry-definition-format"]

    /// Every type spacebar's preview extension claims (scripts/quicklook-types.txt, which build.sh copies into each bundle that
    /// shows files), and the folder and routing types. Nil when the list is missing: then nothing is handed to Quick Look.
    static var quickLookClaims: Set<String>? = Bundle.main.url(forResource: "quicklook-types", withExtension: "txt")
        .flatMap { try? String(contentsOf: $0, encoding: .utf8) }.map(claims)

    /// The types a quicklook-types.txt claims: each `claim`, `md.spacebar.type.<first extension>` for each `declare`, and
    /// md.spacebar.qlmanage, public.folder and public.directory.
    static func claims(_ text: String) -> Set<String> {
        var out: Set<String> = ["md.spacebar.qlmanage", "public.folder", "public.directory"]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.count > 1, f[0] == "claim" { out.insert(String(f[1])) }
            if f.count > 1, f[0] == "declare", let ext = f[1].split(separator: ",").first { out.insert("md.spacebar.type." + ext) }
        }
        return out
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
    /// A CSV or TSV is read this far for its table: 50,000 typical rows. Editing stays within maxTextBytes.
    static let maxTableBytes = 16 << 20

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
        if isDirectory && ext == "rtfd" { return .rtf }
        if isDirectory { return ext == "app" || appExtensions.contains(ext) ? .app : .other }
        let lower = name.lowercased()
        if markdownExtensions.contains(ext) { return .markdown }
        if imageExtensions.contains(ext) { return .image }
        if ext == "pdf" { return .pdf }
        if richTextExtensions.contains(ext) { return .rtf }
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

/// Reads text that may not be UTF-8: a byte order mark first (UTF-8, UTF-16 or UTF-32, either byte order), then UTF-16 without
/// one when every other byte is zero, then UTF-8 (a few stray invalid bytes among real multibyte text allowed, each shown as
/// U+FFFD), then the legacy encoding Foundation's detector names from a short list (Windows-1252, Mac Roman, Shift JIS, EUC-JP,
/// GB 18030, EUC-KR, Big5, Windows-1251, KOI8-R), else Windows-1252 or Latin-1. The legacy encoding is chosen, and the
/// plausibility check made, on the first 64 KB; the whole is then decoded once. Binary is never text: a NUL in anything but
/// UTF-16 or UTF-32, or control characters in more than 2 in 100 of the first characters, and it is refused. `truncated`: the
/// data is the start of a longer file (its first 2 MB), so a code unit or character cut at the end is dropped.
enum TextDecoding {
    struct Decoded: Equatable {
        let text: String
        /// Shown beside the file's kind when it is not UTF-8.
        let name: String
        /// What the text goes back to disk as (EditableText.Source): the encoding and the byte order mark it was read with.
        var encoding: String.Encoding = .utf8
        var bom = Data()
        var isUTF8: Bool { name == "UTF-8" }

        static func == (a: Decoded, b: Decoded) -> Bool { a.text == b.text && a.name == b.name }
    }

    private static func cf(_ e: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(e.rawValue)))
    }
    static let legacy: [String.Encoding] = [.windowsCP1252, .macOSRoman, .shiftJIS, .japaneseEUC, cf(.GB_18030_2000), cf(.EUC_KR), cf(.big5),
                                            .windowsCP1251, cf(.KOI8_R)]
    private static let singleByte: Set<String.Encoding> = [.windowsCP1252, .macOSRoman, .windowsCP1251, cf(.KOI8_R), .isoLatin1]
    private static let names: [String.Encoding: String] = [
        .windowsCP1252: "Windows-1252", .macOSRoman: "Mac Roman", .shiftJIS: "Shift JIS", .japaneseEUC: "EUC-JP", cf(.GB_18030_2000): "GB 18030",
        cf(.EUC_KR): "EUC-KR", cf(.big5): "Big5", .windowsCP1251: "Windows-1251", cf(.KOI8_R): "KOI8-R", .isoLatin1: "ISO Latin 1",
    ]
    /// How much of the text the legacy detector and the plausibility check look at.
    static let sampleBytes = 64 << 10

    /// `s` in native UTF-8 storage, which a render copies its bytes out of at once (PageBody). makeContiguousUTF8 goes through a
    /// bridged NSString a character at a time (0.3 s for 16 MB of Windows-1252); this is one transcoding and one validation.
    static func nativeUTF8(_ s: String) -> String {
        s.utf8.withContiguousStorageIfAvailable { _ in s } ?? String(decoding: Data(s.utf8), as: UTF8.self)
    }

    static func decode(_ data: Data, truncated: Bool = false) -> Decoded? {
        let d = Data(data)
        if d.starts(with: [0xEF, 0xBB, 0xBF]) {
            return utf8(d.dropFirst(3)).flatMap { plausible($0) ? Decoded(text: $0, name: "UTF-8", bom: d.prefix(3)) : nil }
        }
        if d.starts(with: [0xFF, 0xFE, 0, 0]) { return wide(d.dropFirst(4), unit: 4, .utf32LittleEndian, "UTF-32 LE", bom: d.prefix(4)) }
        if d.starts(with: [0, 0, 0xFE, 0xFF]) { return wide(d.dropFirst(4), unit: 4, .utf32BigEndian, "UTF-32 BE", bom: d.prefix(4)) }
        if d.starts(with: [0xFF, 0xFE]) { return wide(d.dropFirst(2), unit: 2, .utf16LittleEndian, "UTF-16 LE", bom: d.prefix(2)) }
        if d.starts(with: [0xFE, 0xFF]) { return wide(d.dropFirst(2), unit: 2, .utf16BigEndian, "UTF-16 BE", bom: d.prefix(2)) }
        if let e = bomlessUTF16(d) { return wide(d, unit: 2, e, e == .utf16LittleEndian ? "UTF-16 LE" : "UTF-16 BE") }
        if d.contains(0) { return nil }
        if let s = utf8(d) ?? mostlyUTF8(d) { return plausible(s) ? Decoded(text: s, name: "UTF-8") : nil }
        return eightBit(d, truncated: truncated)
    }

    /// UTF-8, allowing a character cut at the end.
    private static func utf8(_ d: Data) -> String? {
        for cut in 0...3 where d.count >= cut {
            if let s = String(data: d.dropLast(cut), encoding: .utf8) { return s }
        }
        return nil
    }

    /// UTF-8 with a few invalid bytes (a log with one stray byte), each read as U+FFFD, when the rest has real multibyte
    /// characters: at most 1 in 1,000 characters replaced, or at least 4 valid multibyte characters for every replacement. Legacy
    /// text has almost no valid multibyte sequences and many invalid bytes, so it never passes.
    private static func mostlyUTF8(_ d: Data) -> String? {
        let s = String(decoding: d, as: UTF8.self)
        var n = 0, bad = 0, multi = 0
        for u in s.unicodeScalars {
            n += 1
            if u == "\u{FFFD}" { bad += 1 } else if u.value > 0x7F { multi += 1 }
        }
        return multi > 0 && (bad * 1000 <= n || bad * 4 <= multi) ? s : nil
    }

    /// UTF-16 or UTF-32: whole code units only, a surrogate pair cut at the end dropped, and no NUL or run of controls.
    private static func wide(_ body: Data, unit: Int, _ e: String.Encoding, _ name: String, bom: Data = Data()) -> Decoded? {
        var d = Data(body.prefix(body.count - body.count % unit))
        if unit == 2, d.count >= 2 {
            let last = e == .utf16LittleEndian ? UInt16(d[d.count - 2]) | UInt16(d[d.count - 1]) << 8 : UInt16(d[d.count - 2]) << 8 | UInt16(d[d.count - 1])
            if (0xD800...0xDBFF).contains(last) { d.removeLast(2) }
        }
        guard let s = String(data: d, encoding: e), !s.unicodeScalars.contains("\u{0}"), plausible(s) else { return nil }
        return Decoded(text: s, name: name, encoding: e, bom: Data(bom))
    }

    /// UTF-16 with no byte order mark, as Windows tools write it: in the first 4 KB, zero in at least 40 in 100 of one lane of
    /// bytes and in almost none of the other.
    private static func bomlessUTF16(_ d: Data) -> String.Encoding? {
        let head = d.prefix(4096)
        guard head.count >= 16 else { return nil }
        var even = 0, odd = 0
        for (i, b) in head.enumerated() where b == 0 { if i % 2 == 0 { even += 1 } else { odd += 1 } }
        let half = head.count / 2
        if odd * 10 >= half * 4 && even * 50 <= half { return .utf16LittleEndian }
        if even * 10 >= half * 4 && odd * 50 <= half { return .utf16BigEndian }
        return nil
    }

    /// A legacy encoding: chosen on the first 64 KB, cut after its last line break (a line feed is never part of a multibyte
    /// character in these encodings), then the whole decoded once.
    private static func eightBit(_ d: Data, truncated: Bool) -> Decoded? {
        var head = d.prefix(sampleBytes)
        if head.count < d.count, let nl = head.lastIndex(of: 0x0A), nl - head.startIndex >= sampleBytes / 2 { head = head[...nl] }
        // Only a sample that ends where the file was cut may end inside a character.
        let cut = truncated && head.count == d.count
        guard let e = detect(Data(head), cut: cut) else { return nil }
        var text: String?
        for drop in 0...(truncated ? 3 : 0) where d.count > drop {
            if let s = String(data: d.dropLast(drop), encoding: e) { text = s; break }
        }
        if let text { return Decoded(text: text, name: names[e] ?? "\(e)", encoding: e) }
        // Past the sample the bytes do not fit the encoding after all: Latin-1 reads any byte.
        guard let s = String(data: d, encoding: .isoLatin1), plausible(s) else { return nil }
        return Decoded(text: s, name: names[.isoLatin1]!, encoding: .isoLatin1)
    }

    /// The encoding the detector names for `head`, when that reads as text. With `cut`, up to 3 bytes at the end may belong to a
    /// character cut in two: a multibyte encoding found with them dropped is preferred to a single-byte one found without.
    private static func detect(_ head: Data, cut: Bool) -> String.Encoding? {
        var single: String.Encoding?
        for drop in 0...(cut ? 3 : 0) where head.count > drop {
            var converted: NSString?
            var lossy: ObjCBool = false
            let raw = NSString.stringEncoding(for: head.dropLast(drop), encodingOptions: [.suggestedEncodingsKey: legacy.map { NSNumber(value: $0.rawValue) },
                                                                                        .useOnlySuggestedEncodingsKey: true, .allowLossyKey: false],
                                              convertedString: &converted, usedLossyConversion: &lossy)
            guard raw != 0, let s = converted as String?, !lossy.boolValue, plausible(s) else { continue }
            let e = String.Encoding(rawValue: raw)
            if !singleByte.contains(e) { return e }
            if single == nil { single = e }
        }
        if let single { return single }
        if let s = String(data: head, encoding: .windowsCP1252) { return plausible(s) ? .windowsCP1252 : nil }
        if let s = String(data: head, encoding: .isoLatin1) { return plausible(s) ? .isoLatin1 : nil }
        return nil
    }

    /// Text has few control characters: tab, line breaks, form feed and escape (a log's colours) aside, at most 2 in 100 of the
    /// first 64 K characters.
    static func plausible(_ s: String) -> Bool {
        var n = 0, bad = 0
        for u in s.unicodeScalars.prefix(sampleBytes) {
            n += 1
            if (u.value < 0x20 && ![0x09, 0x0A, 0x0B, 0x0C, 0x0D, 0x1B].contains(u.value)) || u.value == 0x7F || (0x80..<0xA0).contains(u.value) { bad += 1 }
        }
        return bad * 50 <= n
    }
}

/// Which files spacebar edits in place and how their text goes back to disk. Markdown is edited block by block; code, JSON,
/// CSV, text and dotfile config (`.env`, `.gitignore`) as a whole. The writer applies `writeRefusal` to every write.
enum EditableText {
    static let maxMarkdownBytes = 64 << 20

    /// Markdown, the code, JSON, CSV and text kinds, and dotfile config: a name that is a dot and no extension, or `.env.<name>`.
    /// Files that often hold secrets are edited like any other: an edit is written back to the same file and is never handed to
    /// another app (LinkPolicy still keeps them from being opened elsewhere).
    static func allowed(name: String) -> Bool {
        switch FileTypes.kind(name: name) {
        case .markdown, .code, .json, .csv, .text: return true
        case .other:
            let lower = name.lowercased()
            return lower.count > 1 && lower.hasPrefix(".") && ((lower as NSString).pathExtension.isEmpty || lower.hasPrefix(".env."))
        default: return false
        }
    }

    static func isMarkdown(_ name: String) -> Bool { FileTypes.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) }

    /// Whether the file at `path` may be edited by its names: the named path and the file it resolves to are both of an allowed
    /// name, and unless both are Markdown they have the same extension (the same name, for a name without one), so a
    /// `notes.txt` that links to `~/.zshrc` is not editable.
    static func allowed(path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let a = URL(fileURLWithPath: path).lastPathComponent, b = resolved.lastPathComponent
        guard allowed(name: a), allowed(name: b), !runsCode(resolved) else { return false }
        if isMarkdown(a), isMarkdown(b) { return true }
        let ea = (a as NSString).pathExtension.lowercased(), eb = (b as NSString).pathExtension.lowercased()
        return ea.isEmpty || eb.isEmpty ? a.lowercased() == b.lowercased() : ea == eb
    }

    /// Files the shell, git or launchd run or read as commands on their own: a paste into one (the extension can fill the
    /// pasteboard) would run later, so they are never edited, whatever else allows them.
    static let runsCodeNames: Set<String> = [".zshrc", ".zshenv", ".zprofile", ".zlogin", ".zlogout", ".bashrc", ".bash_profile", ".bash_login",
                                             ".bash_logout", ".profile", ".kshrc", ".cshrc", ".tcshrc", ".inputrc", ".gitconfig", ".npmrc", ".yarnrc"]
    static func runsCode(_ resolved: URL) -> Bool {
        let name = resolved.lastPathComponent.lowercased(), ext = resolved.pathExtension.lowercased()
        let parts = resolved.pathComponents.map { $0.lowercased() }
        return runsCodeNames.contains(name) || ["command", "tool"].contains(ext) || parts.contains("launchagents") || parts.contains("launchdaemons")
            || zip(parts, parts.dropFirst()).contains { $0 == ".git" && $1 == "hooks" }
    }

    /// Why the writer refuses to write `data` over `base` at `path`, or nil. The path must be `allowed`, and the file it resolves
    /// to an existing regular file. Markdown is bounded at 64 MB. Anything else at the 2 MB spacebar reads of it, on disk and in
    /// both buffers (so a buffer that is the start of a longer file is never saved), what is on disk must read as text
    /// (TextDecoding, a heuristic: no NUL and few control characters in its first 64 K characters), and neither may be a binary
    /// property list. What may be written into such a file is checked by the writer against what was typed (TypedTexts).
    static func writeRefusal(path: String, data: Data, base: Data) -> String? {
        guard path.hasPrefix("/") else { return "not an absolute path" }
        guard allowed(path: path) else { return "not a file spacebar edits" }
        let named = URL(fileURLWithPath: path), resolved = named.resolvingSymlinksInPath()
        var st = stat()
        guard stat(resolved.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return "not an existing regular file" }
        if isMarkdown(named.lastPathComponent), isMarkdown(resolved.lastPathComponent) {
            return data.count <= maxMarkdownBytes && base.count <= maxMarkdownBytes ? nil : "larger than 64 MB"
        }
        guard st.st_size <= FileTypes.maxTextBytes, data.count <= FileTypes.maxTextBytes, base.count <= FileTypes.maxTextBytes else {
            return "larger than 2 MB"
        }
        let plist = Data("bplist".utf8)
        guard !data.starts(with: plist), !base.starts(with: plist) else { return "a binary property list" }
        guard base.isEmpty || TextDecoding.decode(base) != nil else { return "not text" }
        return nil
    }

    /// How a text file's bytes become the text that is edited, and back: its encoding and byte order mark, and CRLF when every
    /// line ends in one (the text is edited with LF). Only a file whose bytes come back exactly from its text is editable, so
    /// nothing is converted behind the user's back: not a file with bytes read as U+FFFD, nor one cut at 2 MB.
    struct Source: Equatable {
        let encoding: String.Encoding
        let bom: Data
        let crlf: Bool
        /// Named in a refusal: "UTF-8", "Windows-1252"…
        let name: String

        /// The file's bytes for `text`, or nil when a character in it has no form in the file's encoding.
        func bytes(_ text: String) -> Data? {
            (crlf ? text.replacingOccurrences(of: "\n", with: "\r\n") : text).data(using: encoding, allowLossyConversion: false).map { bom + $0 }
        }

        /// The first character of `text` the encoding cannot hold, for the refusal.
        func unencodable(_ text: String) -> Character? {
            text.first { String($0).data(using: encoding, allowLossyConversion: false) == nil }
        }
    }

    /// What changed from `old` to `new`, in UTF-16 offsets as the page counts them: [from, to) of `old` became `insert`; nil when
    /// nothing did. Never between the halves of a surrogate pair, so `insert` is whole characters.
    static func change(from old: String, to new: String) -> (from: Int, to: Int, insert: String)? {
        let a = Array(old.utf16), b = Array(new.utf16)
        var from = 0
        while from < a.count, from < b.count, a[from] == b[from] { from += 1 }
        if from == a.count, from == b.count { return nil }
        var tail = 0
        while tail < a.count - from, tail < b.count - from, a[a.count - 1 - tail] == b[b.count - 1 - tail] { tail += 1 }
        if from > 0, UTF16.isLeadSurrogate(a[from - 1]) { from -= 1 }
        if tail > 0, UTF16.isTrailSurrogate(a[a.count - tail]) { tail -= 1 }
        return (from, a.count - tail, String(decoding: b[from..<(b.count - tail)], as: UTF16.self))
    }

    struct Opened {
        let source: Source
        /// The text as edited: LF line breaks when the file's are all CRLF.
        let text: String
        let bytes: Data
    }

    /// The editable form of the file at `path` as it is on disk now, or nil: the writer's own read when an edit starts.
    static func read(path: String) -> Opened? {
        guard allowed(path: path) else { return nil }
        let fd = Darwin.open(URL(fileURLWithPath: path).resolvingSymlinksInPath().path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size <= FileTypes.maxTextBytes,
              let data = try? h.read(upToCount: FileTypes.maxTextBytes + 1) ?? Data(), data.count == st.st_size else { return nil }
        let decoded = data.isEmpty ? TextDecoding.Decoded(text: "", name: "UTF-8") : TextDecoding.decode(data)
        return decoded.flatMap { open(data, decoded: $0) }
    }

    /// The editable form of a whole file's `bytes`, read as `decoded`; nil when they would not come back byte for byte.
    static func open(_ bytes: Data, decoded: TextDecoding.Decoded) -> Opened? {
        let raw = decoded.text
        let crlf = raw.contains("\r\n") && !raw.replacingOccurrences(of: "\r\n", with: "").utf8.contains(10)
        let source = Source(encoding: decoded.encoding, bom: Data(decoded.bom), crlf: crlf, name: decoded.name)
        let text = crlf ? raw.replacingOccurrences(of: "\r\n", with: "\n") : raw
        guard source.bytes(text) == bytes else { return nil }
        return Opened(source: source, text: text, bytes: bytes)
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

/// What the page is sent to show a file: `view` says how (markdown, image, pdf, html, video, audio, quicklook, code, json, csv, text
/// or info), and nothing in it is ever rendered as HTML. A PDF, an HTML file, media and Apple's previews are drawn natively; the page
/// only reserves their place.
enum FileView {
    /// What every render names: the file, its folder as the page's base URL, and the sidebar's root.
    static func base(path: String, root: String, reason: String) -> [String: Any] {
        let dir = (path as NSString).deletingLastPathComponent
        return ["path": path, "base": FileTypes.fileURL(dir + "/")!.absoluteString, "folder": tildePath(dir),
                "name": (path as NSString).lastPathComponent, "reason": reason, "root": root, "rootName": (root as NSString).lastPathComponent]
    }

    /// `path` with the user's home as `~`: the real home, since inside the sandbox NSHomeDirectory() is the container.
    static func tildePath(_ path: String, home: String = getpwuid(getuid()).flatMap({ String(validatingUTF8: $0.pointee.pw_dir) }) ?? NSHomeDirectory()) -> String {
        guard !home.isEmpty else { return path }
        return path == home ? "~" : path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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

    /// Why an item cannot be opened at all, as the info card says it: a link that loops or leads nowhere, no permission, or not
    /// a regular file.
    static func openRefusal(_ path: String) -> String {
        var ls = stat(), st = stat()
        let link = lstat(path, &ls) == 0 && ls.st_mode & S_IFMT == S_IFLNK
        if stat(path, &st) != 0 {
            let err = errno
            if link && err == ELOOP { return "This item can’t be opened (a link that loops)." }
            if link && err == ENOENT { return "This item can’t be opened (a link to an item that is missing)." }
            if err == EACCES { return "This item can’t be opened (no permission to read it)." }
            return "This item can’t be opened."
        }
        if st.st_mode & S_IFMT != S_IFREG && st.st_mode & S_IFMT != S_IFDIR { return "This item can’t be opened (not a regular file)." }
        if st.st_size > FolderListing.maxDocumentBytes { return "This item can’t be opened (too large to preview)." }
        return "This item couldn’t be read."
    }

    /// The info card of an item that cannot be opened at all (openRefusal). Nothing here reads the file.
    static func unopenable(path: String, root: String, note: String) -> [String: Any] {
        var p = base(path: path, root: root, reason: "open")
        var ls = stat()
        let link = lstat(path, &ls) == 0 && ls.st_mode & S_IFMT == S_IFLNK
        p["kindName"] = link ? "Broken link" : UTType(filenameExtension: (path as NSString).pathExtension).flatMap(\.localizedDescription) ?? "Document"
        p["icon"] = FileTypes.glyph(name: (path as NSString).lastPathComponent, kind: .other)
        p["size"] = NSNull()
        p["canOpen"] = false
        p["view"] = "info"
        p["note"] = note
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
    /// `quickLook`: false once Apple's preview of the file showed only an icon; it is then shown as text if it is text.
    static func payload(path: String, kind: FileKind, root: String, reason: String, canOpen: Bool, quickLook: Bool = true) -> [String: Any] {
        payloadAndText(path: path, kind: kind, root: root, reason: reason, canOpen: canOpen, quickLook: quickLook).payload
    }

    /// The payload, and for a text view of a whole file that EditableText allows and can write back as it was read, that text's
    /// editable form: the payload then carries `editable` and the text as edited.
    static func payloadAndText(path: String, kind: FileKind, root: String, reason: String, canOpen: Bool,
                               quickLook: Bool = true) -> (payload: [String: Any], edit: EditableText.Opened?) {
        var opened: EditableText.Opened?
        var p = base(path: path, root: root, reason: reason)
        var st = stat()
        guard stat(path, &st) == 0 else { p["view"] = "info"; return (p, nil) }
        let regular = st.st_mode & S_IFMT == S_IFREG
        let size = Int64(st.st_size)
        let ext = (path as NSString).pathExtension
        p["size"] = regular ? size : NSNull()
        p["modified"] = Double(st.st_mtimespec.tv_sec) * 1000 + Double(st.st_mtimespec.tv_nsec / 1_000_000)
        let type = (regular ? nil : UTType(filenameExtension: ext, conformingTo: .package)) ?? UTType(filenameExtension: ext)
        p["kindName"] = type.flatMap(\.localizedDescription) ?? (regular ? "Document" : "Folder")
        let media = FileTypes.unplayableMedia[ext.lowercased()]
        if let media, type?.isDynamic != false { p["kindName"] = media }
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
        case .image where regular && size <= FileTypes.maxImageBytes && FileTypes.nativeImageExtensions.contains(ext.lowercased()):
            view = "bitmap"
        case .image where regular && size <= FileTypes.maxImageBytes:
            view = "image"
            p["src"] = FileTypes.fileURL(path, version: version)!.absoluteString
        case .pdf where regular && size <= FileTypes.maxFileBytes:
            view = "pdf"
        case .html where regular && size <= FolderListing.maxDocumentBytes:
            view = "html"
        // Drawn natively (RichTextPane): an .rtf file, or an .rtfd package or flattened file.
        case .rtf where regular ? size <= FolderListing.maxDocumentBytes : st.st_mode & S_IFMT == S_IFDIR && ext.lowercased() == "rtfd":
            view = "rtf"
        case .video where regular && size <= FileTypes.maxFileBytes, .audio where regular && size <= FileTypes.maxFileBytes:
            view = kind.rawValue
        case .other where quickLook && (regular ? size <= FileTypes.maxFileBytes : st.st_mode & S_IFMT == S_IFDIR) && FileTypes.appleQuickLookType(path) != nil:
            view = "quicklook"
        // Its contents come later, from the writer. An archive in iCloud is not downloaded to list it.
        case .archive where regular && !FileTypes.isDataless(path):
            view = "archive"
        case .code, .json, .csv, .text, .other, .app:
            // O_NONBLOCK and fstat: a file swapped for a FIFO since the stat can neither hang the open nor be read.
            let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
            // No read permission: no app of the user's can read it either. (A sandbox's refusal is EPERM, and the writer may still open it.)
            if fd < 0, regular, errno == EACCES {
                p["note"] = "This file couldn’t be read."
                p["canOpen"] = false
                break
            }
            guard regular, size > 0 || kind != .other, fd >= 0 else { if fd >= 0 { close(fd) }; break }
            var fst = stat()
            guard fstat(fd, &fst) == 0, fst.st_mode & S_IFMT == S_IFREG else { close(fd); break }
            let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let cap = kind == .csv ? FileTypes.maxTableBytes : FileTypes.maxTextBytes
            let read = { try? h.read(upToCount: cap) ?? Data() }
            // Only a text kind is downloaded when evicted, and within Markdown's bound: the download is the whole file, and
            // anything else only turns into its info card.
            let fetch = [.code, .json, .csv, .text].contains(kind) && size <= FolderListing.maxDocumentBytes
            guard var data = fetch ? FileTypes.materializing(read) : read() else { break }
            var converted = false
            if ext.lowercased() == "plist", let xml = FileView.binaryPlistAsXML(data) {
                data = xml
                converted = true
                p["kindName"] = "Binary property list, shown as XML"
            }
            guard let decoded = size == 0 ? TextDecoding.Decoded(text: "", name: "UTF-8") : TextDecoding.decode(data, truncated: size > cap) else { break }
            view = kind == .code ? "code" : kind == .json ? "json" : kind == .csv ? "csv" : "text"
            p["text"] = decoded.text
            if !converted, size <= FileTypes.maxTextBytes, Int64(data.count) == size, EditableText.allowed(path: path),
               let o = EditableText.open(data, decoded: decoded) {
                opened = o
                p["text"] = o.text
                p["editable"] = true
            }
            if !decoded.isUTF8 {
                p["encoding"] = decoded.name
                p["kindName"] = "\(p["kindName"] as? String ?? "Plain text") (\(decoded.name))"
            }
            p["truncated"] = size > cap
            p["readCap"] = cap
            p["lang"] = kind == .code ? FileTypes.language(name: (path as NSString).lastPathComponent) ?? NSNull() : NSNull()
            if ext.lowercased() == "tsv" { p["tsv"] = true }
        default:
            break
        }
        if view == "info", regular, media != nil, p["note"] == nil { p["note"] = "macOS can’t play this format; open it in another app." }
        p["view"] = view
        return (p, opened)
    }
}

/// One folder of the sidebar's tree, for a single file and a folder alike: folders first, then files, each sorted by `sort`
/// ("name", or "modified", newest first), with a README first among the files when `readmeFirst`.
///
/// Hidden files (a leading dot or the hidden flag) are skipped unless `showHidden`. A symbolic link is listed only when it
/// resolves inside the root to a regular file or a folder, so the tree never reaches outside the root; one that loops or leads
/// nowhere is listed as broken, by its name only, and is never opened. FIFOs, sockets and
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
        /// -1 for anything that is a directory on disk, a package included: it has no size of its own.
        let size: Int64
        let modified: Double
        /// A symbolic link that loops or leads nowhere: listed greyed, never opened.
        var broken = false

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
                 if e.size >= 0 { d["size"] = e.size }
                 if e.broken { d["broken"] = true }
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
                guard let real = realPath(path) else {
                    let e = errno
                    if e == ELOOP || e == ENOENT {
                        found.append(Entry(name: name, path: path, isDirectory: false, kind: .other, size: -1, modified: 0, broken: true))
                    }
                    continue
                }
                guard real.hasPrefix(inside), stat(real, &st) == 0 else { continue }
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
            found.append(Entry(name: name, path: path, isDirectory: kind == .folder, kind: kind, size: isDir ? -1 : Int64(st.st_size), modified: modified))
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
    /// `l` with only the entries named in `names`: the sidebar of a multiple selection, which moves among the selected items.
    /// Entries past the listing's caps are not in `l` (but for the pinned file on screen).
    static func only(_ l: Listing, names: Set<String>) -> Listing {
        Listing(dir: l.dir, entries: l.entries.filter { names.contains($0.name) }, more: 0)
    }

    static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return stat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

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

/// One file inside an archive, previewed without extracting it (ArchiveEntry streams it through the writer's sandboxed bsdtar):
/// what may be read, how much, and the read-only payload the page shows it with. The payload names the archive as its `path`,
/// so every check of "the file on screen" still means the archive; `entry` names the file inside it.
enum ArchiveEntryView {
    static let maxTextBytes = 2 << 20
    static let maxImageBytes = 20 << 20
    /// Decoded by WebKit as `<img>`, from a blob the page makes of one read of `spacebar://entry/<token>`. No SVG.
    static let webImages: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "ico"]
    /// Decoded by ImageIO in the extension (ImagePane), from the bytes the writer sent.
    static let nativeImages: Set<String> = ["heic", "heif", "avif", "tif", "tiff"]

    enum Kind: Equatable { case markdown, code, json, csv, text, image, bitmap, archive, other }

    static func kind(_ entry: String) -> Kind {
        let name = displayName(entry)
        let ext = (name as NSString).pathExtension.lowercased()
        if webImages.contains(ext) { return .image }
        if nativeImages.contains(ext) { return .bitmap }
        switch FileTypes.kind(name: name) {
        case .markdown: return .markdown
        case .code: return .code
        case .json: return .json
        case .csv: return .csv
        case .text: return .text
        case .archive: return .archive
        default: return .other
        }
    }

    /// How many bytes of the entry may be read, or nil when it is not read at all (shown as its info card).
    static func cap(for entry: String) -> Int? {
        switch kind(entry) {
        case .markdown, .code, .json, .csv, .text: return maxTextBytes
        case .image, .bitmap: return maxImageBytes
        case .archive, .other: return nil
        }
    }

    /// The entry's own name: its last path component (a folder's trailing slash and a leading `./` do not count).
    static func displayName(_ entry: String) -> String {
        entry.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? entry
    }

    /// The entry's path as the breadcrumb shows it, without a leading `./`.
    static func shownPath(_ entry: String) -> String {
        var s = Substring(entry)
        while s.hasPrefix("./") { s = s.dropFirst(2) }
        return String(s)
    }

    static let notes: [String: String] = [
        "tooLarge": "This file is too large to preview inside the archive.",
        "bomb": "This file expands far more than its archive could hold, so it wasn’t read.",
        "timedOut": "Reading this file from the archive took too long.",
        "archive": "An archive inside an archive isn’t opened.",
        "other": "Only text, code, Markdown, data and images are shown from inside an archive.",
        "unreadable": "This file couldn’t be read from the archive.",
        "binary": "This file isn’t text, so it can’t be shown here.",
    ]

    /// What the page is sent for `entry` of the archive at `archive`: its text or image view when `data` was read, else its info
    /// card saying why (`failure`, one of `notes`' keys, or a reason the writer gave). Never editable, never opened.
    static func payload(archive: String, root: String, entry: String, size: Int64?, modified: Double?, data: Data?, failure: String?) -> [String: Any] {
        var p = FileView.base(path: archive, root: root, reason: "entry")
        let name = displayName(entry), shown = shownPath(entry)
        let archiveName = (archive as NSString).lastPathComponent
        let k = kind(entry)
        p["name"] = name
        // Relative links and images in an entry resolve to nothing: never to files beside the archive.
        p["base"] = "spacebar://entry/"
        p["entry"] = ["name": entry, "path": shown, "archive": archiveName]
        let inner = (shown as NSString).deletingLastPathComponent
        p["folder"] = inner.isEmpty ? archiveName : "\(archiveName) › \(inner)"
        p["size"] = size.map { NSNumber(value: $0) } ?? NSNull()
        p["modified"] = modified.map { NSNumber(value: $0) } ?? NSNull()
        p["kindName"] = UTType(filenameExtension: (name as NSString).pathExtension).flatMap(\.localizedDescription) ?? "Document"
        let fk: FileKind = k == .bitmap || k == .image ? .image : FileTypes.kind(name: name)
        p["icon"] = FileTypes.glyph(name: name, kind: fk)
        p["canOpen"] = false
        p["view"] = "info"
        func info(_ why: String) -> [String: Any] {
            p["note"] = notes[why] ?? notes["unreadable"]!
            return p
        }
        switch k {
        case .archive: return info("archive")
        case .other: return info("other")
        default: break
        }
        if let failure { return info(failure) }
        guard let data else { return info("unreadable") }
        switch k {
        case .image, .bitmap:
            p["view"] = k == .image ? "image" : "bitmap"
            p["size"] = NSNumber(value: data.count)
            return p
        case .markdown, .code, .json, .csv, .text:
            guard let decoded = data.isEmpty ? TextDecoding.Decoded(text: "", name: "UTF-8") : TextDecoding.decode(data) else { return info("binary") }
            p["view"] = k == .markdown ? "markdown" : k == .code ? "code" : k == .json ? "json" : k == .csv ? "csv" : "text"
            p["text"] = decoded.text
            p["size"] = NSNumber(value: data.count)
            if [.code, .json, .csv, .text].contains(k), UTType(filenameExtension: (name as NSString).pathExtension)?.conforms(to: .text) != true {
                p["kindName"] = k == .code ? "Source code" : "Plain text"
            }
            if !decoded.isUTF8 { p["kindName"] = "\(p["kindName"] as? String ?? "Plain text") (\(decoded.name))" }
            if k == .code { p["lang"] = FileTypes.language(name: name) ?? NSNull() }
            if (name as NSString).pathExtension.lowercased() == "tsv" { p["tsv"] = true }
            return p
        default:
            return info("unreadable")
        }
    }
}
