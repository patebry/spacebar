import Foundation

/// spacebar's preferences: `settings.json` in the support folder, beside `themes/*.css` and `custom.css`.
///
/// The file is user-editable, so reading is tolerant: an unknown key is ignored, a value of the wrong type or outside its allowed
/// set falls back to the default, and a number out of range is clamped. Writing merges into the raw JSON object, so keys this
/// version does not know (written by a newer one) survive, and a file that is not a JSON object is never overwritten.
struct Settings: Codable, Equatable {
    var version = 1
    var theme = "apple"
    var appearance = "auto"
    var codeTheme = "auto"
    var userTheme: String? = nil
    var customCSS = true
    var bodyFont = "system"
    var monoFont = "system"
    var fontSize = 15
    var lineHeight = 1.6
    var width = "medium"
    var editorBundleID: String? = nil
    var inlineEditing = true
    var taskToggles = true
    var folderMode = false
    var folderReadmeFirst = true
    var folderSort = "name"
    var sidebarCollapsed = false
    var sidebarWidth = 240
    var showHiddenFiles = false
    var minimalChrome = false
    var frontMatter = "table"
    var toc = "auto"
    var stats = true
    var mdLinks = "preview"
    var webLinks = "browser"
    var math = true
    var mermaid = true
    var rawHTML = "sanitized"
    var remoteImages = false

    static let themes = ["apple", "github", "paper", "solarized", "nord", "contrast"]
    /// Allowed values of every string-enum key. rawHTML has no "on": unsanitized HTML would hand a downloaded document the page.
    static let choices: [String: [String]] = [
        "theme": themes,
        "appearance": ["auto", "light", "dark"],
        "codeTheme": ["auto"] + themes,
        "bodyFont": ["system", "serif", "rounded", "mono"],
        "monoFont": ["system", "menlo", "monaco", "courier"],
        "width": ["narrow", "medium", "wide", "full"],
        "folderSort": ["name", "modified"],
        "frontMatter": ["table", "hide", "raw"],
        "toc": ["auto", "on", "off"],
        "mdLinks": ["preview", "editor"],
        "webLinks": ["browser"],
        "rawHTML": ["off", "sanitized"],
    ]
    static let intRanges: [String: ClosedRange<Int>] = ["fontSize": 12...24, "sidebarWidth": 160...480]
    static let doubleRanges: [String: ClosedRange<Double>] = ["lineHeight": 1.2...2.0]
    static let boolKeys: Set<String> = ["customCSS", "inlineEditing", "taskToggles", "folderMode", "folderReadmeFirst", "stats", "math",
                                        "mermaid", "remoteImages", "sidebarCollapsed", "showHiddenFiles", "minimalChrome"]
    /// Keys whose value is a string or null, each checked by its own pattern.
    static let optionalKeys: Set<String> = ["userTheme", "editorBundleID"]
    static var allKeys: Set<String> { Set(choices.keys).union(intRanges.keys).union(doubleRanges.keys).union(boolKeys).union(optionalKeys) }
    /// The only keys the preview panel may change (its Aa popover and sidebar button). The page renders an untrusted document,
    /// so even a page that was somehow scripted can restyle the preview but never pick a CSS file, an editor app, or what is
    /// rendered or opened.
    static let panelKeys: Set<String> = ["theme", "appearance", "fontSize", "width", "bodyFont", "sidebarCollapsed", "sidebarWidth"]

    /// A panel change as the JSON patch the writer takes, or nil when the key is not a panel key or the value does not
    /// sanitize (sidebarCollapsed takes a JSON boolean only, never a number or a string; sidebarWidth a number, clamped).
    static func panelPatch(_ key: String, _ value: Any) -> Data? {
        guard panelKeys.contains(key), let clean = sanitize(key, value) else { return nil }
        return try? JSONSerialization.data(withJSONObject: [key: clean])
    }

    static let maxFileBytes = 64 << 10

    /// A user theme is a plain file name inside themes/: no separators, no leading dot, .css only.
    static func validUserTheme(_ s: String) -> Bool {
        s.utf8.count <= 64 && s.range(of: #"^[A-Za-z0-9_][A-Za-z0-9 _.-]*\.css$"#, options: .regularExpression) != nil && !s.contains("..")
    }
    static func validBundleID(_ s: String) -> Bool {
        s.utf8.count <= 255 && s.range(of: #"^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$"#, options: .regularExpression) != nil
    }

    /// `value` made valid for `key`, or nil when it cannot be (unknown key, wrong type, value not allowed). NSNull clears an
    /// optional key.
    static func sanitize(_ key: String, _ value: Any) -> Any? {
        let isBool = { (v: Any) -> Bool in (v as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? (v is Bool) }
        if let allowed = choices[key] {
            guard let s = value as? String, allowed.contains(s) else { return nil }
            return s
        }
        if let r = intRanges[key] {
            guard !isBool(value), let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
            return Int(min(max(n.doubleValue.rounded(), Double(r.lowerBound)), Double(r.upperBound)))
        }
        if let r = doubleRanges[key] {
            guard !isBool(value), let n = value as? NSNumber, n.doubleValue.isFinite else { return nil }
            return (min(max(n.doubleValue, r.lowerBound), r.upperBound) * 100).rounded() / 100
        }
        if boolKeys.contains(key) {
            guard isBool(value), let b = value as? Bool else { return nil }
            return b
        }
        if optionalKeys.contains(key) {
            if value is NSNull { return NSNull() }
            guard let s = value as? String else { return nil }
            let ok = key == "userTheme" ? validUserTheme(s) : validBundleID(s)
            return ok ? s : nil
        }
        return nil
    }

    /// Settings from a raw JSON object: every known key that sanitizes is taken, everything else keeps its default.
    init(dictionary raw: [String: Any]) {
        var d = Settings().dictionary
        for (k, v) in raw where Self.allKeys.contains(k) {
            if let clean = Self.sanitize(k, v) { d[k] = clean }
        }
        let data = try! JSONSerialization.data(withJSONObject: d)
        self = (try? JSONDecoder().decode(Settings.self, from: data)) ?? Settings()
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var s = Settings()
        func take<T: Decodable>(_ k: CodingKeys, _ path: WritableKeyPath<Settings, T>) {
            if let v = try? c.decodeIfPresent(T.self, forKey: k), let clean = Self.sanitize(k.stringValue, v as Any) as? T { s[keyPath: path] = clean }
        }
        func takeOptional(_ k: CodingKeys, _ path: WritableKeyPath<Settings, String?>) {
            if (try? c.decodeNil(forKey: k)) == true { s[keyPath: path] = nil; return }
            if let v = try? c.decodeIfPresent(String.self, forKey: k), Self.sanitize(k.stringValue, v) != nil { s[keyPath: path] = v }
        }
        take(.theme, \.theme); take(.appearance, \.appearance); take(.codeTheme, \.codeTheme); takeOptional(.userTheme, \.userTheme)
        take(.customCSS, \.customCSS); take(.bodyFont, \.bodyFont); take(.monoFont, \.monoFont)
        if let n = try? c.decodeIfPresent(Double.self, forKey: .fontSize), let v = Self.sanitize("fontSize", n) as? Int { s.fontSize = v }
        if let n = try? c.decodeIfPresent(Double.self, forKey: .lineHeight), let v = Self.sanitize("lineHeight", n) as? Double { s.lineHeight = v }
        take(.width, \.width); takeOptional(.editorBundleID, \.editorBundleID)
        take(.inlineEditing, \.inlineEditing); take(.taskToggles, \.taskToggles); take(.folderMode, \.folderMode)
        take(.folderReadmeFirst, \.folderReadmeFirst); take(.folderSort, \.folderSort); take(.frontMatter, \.frontMatter)
        take(.sidebarCollapsed, \.sidebarCollapsed); take(.showHiddenFiles, \.showHiddenFiles); take(.minimalChrome, \.minimalChrome)
        if let n = try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth), let v = Self.sanitize("sidebarWidth", n) as? Int { s.sidebarWidth = v }
        take(.toc, \.toc); take(.stats, \.stats); take(.mdLinks, \.mdLinks); take(.webLinks, \.webLinks)
        take(.math, \.math); take(.mermaid, \.mermaid); take(.rawHTML, \.rawHTML); take(.remoteImages, \.remoteImages)
        self = s
    }

    /// Every key, with nil optionals as NSNull, ready for JSONSerialization.
    var dictionary: [String: Any] {
        let data = try! JSONEncoder().encode(self)
        var d = (try! JSONSerialization.jsonObject(with: data)) as! [String: Any]
        for k in Self.optionalKeys where d[k] == nil { d[k] = NSNull() }
        return d
    }

    var json: String { String(data: try! JSONSerialization.data(withJSONObject: dictionary, options: [.sortedKeys]), encoding: .utf8)! }
}

/// Where the settings live, and reading and writing them.
enum SettingsFile {
    /// SPACEBAR_SUPPORT_DIR when set (tests), otherwise ~/Library/Application Support/spacebar of the real home: inside the
    /// sandbox NSHomeDirectory() is the container, so the home comes from the password database.
    static var supportDir: URL {
        if let p = ProcessInfo.processInfo.environment["SPACEBAR_SUPPORT_DIR"], !p.isEmpty { return URL(fileURLWithPath: p, isDirectory: true) }
        return supportDir(in: applicationSupport)
    }
    static let folderName = "spacebar"
    /// The folder's name before the product was renamed.
    static let legacyFolderName = "spacebar.md"

    private static var applicationSupport: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true).appendingPathComponent("Library/Application Support", isDirectory: true)
    }

    /// `spacebar/` in `base`, or the legacy folder while it is the only one: the sandboxed extension cannot move it, so it reads
    /// it in place until the app or a writer has run `migrateLegacySupportDir`.
    static func supportDir(in base: URL) -> URL {
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        return !exists(current) && isDirectory(legacy) ? legacy : current
    }

    /// Renames the legacy folder to `spacebar/` when only the legacy one exists. When both exist the new one wins and the legacy
    /// one is left untouched; RENAME_EXCL keeps that true if another process creates the new folder first. Does nothing under
    /// SPACEBAR_SUPPORT_DIR unless `base` is given. Returns whether it moved the folder.
    @discardableResult
    static func migrateLegacySupportDir(in base: URL? = nil) -> Bool {
        if base == nil, let p = ProcessInfo.processInfo.environment["SPACEBAR_SUPPORT_DIR"], !p.isEmpty { return false }
        let base = base ?? applicationSupport
        let current = base.appendingPathComponent(folderName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyFolderName, isDirectory: true)
        guard !exists(current), isDirectory(legacy) else { return false }
        return renamex_np(legacy.path, current.path, UInt32(RENAME_EXCL)) == 0
    }

    private static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 || errno != ENOENT
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }
    static var url: URL { supportDir.appendingPathComponent("settings.json") }
    static var themesDir: URL { supportDir.appendingPathComponent("themes", isDirectory: true) }
    static var customCSS: URL { supportDir.appendingPathComponent("custom.css") }

    enum Failure: Error, Equatable { case unreadable(String), notAnObject, tooLarge, writeFailed(String) }

    /// The raw JSON object on disk: [:] when there is no file; an error when there is one that must not be overwritten.
    /// `forWriting`: a symlinked settings.json is refused, since the atomic write would replace the link with a file. For reading,
    /// a link to a regular file of this user (a dotfiles setup) is followed.
    static func raw(at url: URL = url, forWriting: Bool = false) -> Result<[String: Any], Failure> {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return errno == ENOENT ? .success([:]) : .failure(.unreadable(String(cString: strerror(errno)))) }
        if st.st_mode & S_IFMT == S_IFLNK {
            guard !forWriting else { return .failure(.unreadable("settings.json is a symbolic link; edit the file it points to")) }
            guard stat(url.path, &st) == 0, st.st_uid == getuid() else { return .failure(.unreadable("link target not readable or not yours")) }
        }
        guard st.st_mode & S_IFMT == S_IFREG else { return .failure(.unreadable("not a regular file")) }
        guard st.st_size <= maxBytes else { return .failure(.tooLarge) }
        guard let data = FileManager.default.contents(atPath: url.path) else { return .failure(.unreadable("read failed")) }
        if data.isEmpty { return .success([:]) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return .failure(.notAnObject) }
        return .success(obj)
    }
    private static var maxBytes: Int64 { Int64(Settings.maxFileBytes) }

    /// The settings to use: defaults for anything missing, invalid, or when the file cannot be read.
    static func load(at url: URL = url) -> Settings {
        if case .success(let raw) = raw(at: url) { return Settings(dictionary: raw) }
        return Settings()
    }

    /// Merges `patch` (only keys in `allowed`, each sanitized) into the file and writes it atomically. Keys the patch does not
    /// name, known or not, are kept as they are. Returns the settings now on disk.
    @discardableResult
    static func update(_ patch: [String: Any], allowed: Set<String> = Settings.allKeys, at url: URL = url) -> Result<Settings, Failure> {
        // The host app and each extension's writer update the same file; the lock keeps one read-merge-write from losing another's.
        let lockFD = open(url.deletingLastPathComponent().appendingPathComponent(".settings.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        if lockFD >= 0 { flock(lockFD, LOCK_EX) }
        defer { if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) } }
        var obj: [String: Any]
        switch raw(at: url, forWriting: true) {
        case .success(let o): obj = o
        case .failure(let f): return .failure(f)
        }
        var changed = false
        for (k, v) in patch where allowed.contains(k) {
            guard let clean = Settings.sanitize(k, v) else { continue }
            obj[k] = clean
            changed = true
        }
        if obj["version"] == nil { obj["version"] = 1; changed = true }
        if changed { if let f = write(obj, to: url) { return .failure(f) } }
        return .success(Settings(dictionary: obj))
    }

    /// The writer's `updateSettings`: a small JSON object from the preview panel, merged with only Settings.panelKeys allowed.
    /// Nil when the patch is not such an object.
    static func updateFromPanel(_ patch: Data, at url: URL = url) -> Result<Settings, Failure>? {
        guard patch.count <= 4096, let obj = (try? JSONSerialization.jsonObject(with: patch)) as? [String: Any] else { return nil }
        return update(obj, allowed: Settings.panelKeys, at: url)
    }

    /// Creates the support folder, themes/, and a settings.json of defaults when none exists. An existing file is never touched.
    static func ensure(at dir: URL = supportDir) -> Failure? {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dir.appendingPathComponent("themes", isDirectory: true), withIntermediateDirectories: true)
        } catch { return .writeFailed(error.localizedDescription) }
        let file = dir.appendingPathComponent("settings.json")
        var st = stat()
        if lstat(file.path, &st) == 0 { return nil }
        return write(Settings().dictionary, to: file)
    }

    private static func write(_ obj: [String: Any], to url: URL) -> Failure? {
        do {
            let data = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try (data + Data("\n".utf8)).write(to: url, options: .atomic)
            return nil
        } catch { return .writeFailed(error.localizedDescription) }
    }
}

/// A user theme: `themes/<file>.css`, named by its first-line header `/* spacebar-theme name="…" appearance=auto */`.
struct UserTheme: Equatable {
    let file: String
    let name: String
    let appearance: String

    static func list(in dir: URL = SettingsFile.themesDir) -> [UserTheme] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return files.filter(Settings.validUserTheme).sorted { $0.localizedStandardCompare($1) == .orderedAscending }.map { f in
            let head = (try? FileHandle(forReadingFrom: dir.appendingPathComponent(f)))
                .flatMap { h in defer { try? h.close() }; return try? h.read(upToCount: 512) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            return parse(file: f, header: head)
        }
    }

    static func parse(file: String, header: String) -> UserTheme {
        let fallback = (file as NSString).deletingPathExtension
        guard let m = header.range(of: #"^\s*/\*\s*spacebar-theme\b[^*]*\*/"#, options: .regularExpression) else {
            return UserTheme(file: file, name: fallback, appearance: "auto")
        }
        let h = String(header[m])
        let name = h.range(of: #"name="[^"\n]{1,64}""#, options: .regularExpression).map { String(h[$0].dropFirst(6).dropLast()) } ?? fallback
        let app = h.range(of: #"appearance=(auto|light|dark)"#, options: .regularExpression).map { String(h[$0].dropFirst(11)) } ?? "auto"
        return UserTheme(file: file, name: name, appearance: app)
    }
}
