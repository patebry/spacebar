import Foundation

/// spacebar's preferences: `settings.json` in the support folder, beside `themes/*.css` and `custom.css`.
///
/// The file is user-editable, so reading is tolerant: an unknown key is ignored, a value of the wrong type or outside its allowed
/// set falls back to the default, and a number out of range is clamped. Writing merges into the raw JSON object, so keys this
/// version does not know (written by a newer one) survive, and a file that is not a JSON object is never overwritten.
struct Settings: Codable, Equatable {
    var version = Settings.currentVersion
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
    /// The app the Open button hands an image to; nil: its default app, never spacebar itself.
    var imageAppBundleID: String? = nil
    var inlineEditing = true
    var taskToggles = true
    var folderMode = true
    var folderReadmeFirst = false
    var folderSort = "name"
    /// Folders above the files in the sidebar: as Finder's own "Keep folders on top" ("finder"), "always" or "never".
    var foldersFirst = "finder"
    var sidebarCollapsed = false
    var sidebarWidth = 240
    var sidebarKeys = true
    /// The folder view's grid or list, remembered for folders mostly of images and video and for every other folder.
    var folderViewMedia = "grid"
    var folderViewOther = "list"
    var showHiddenFiles = false
    var minimalChrome = false
    var frontMatter = "table"
    var toc = "auto"
    var stats = false
    var mdLinks = "preview"
    var webLinks = "browser"
    var math = true
    var mermaid = true
    var rawHTML = "sanitized"
    var remoteImages = false
    /// Scripts in an HTML file made on this Mac: "ask" shows it without them and offers to run them, "local" runs them, "off"
    /// never does. A downloaded file never runs them.
    var htmlScripts = "ask"
    var checkUpdates = true
    var welcomeShown = false
    /// Space in Finder opens spacebar's own panel through the helper (Settings, or the welcome sheet).
    var spaceHelper = false
    /// The welcome sheet has offered the helper once; an upgrade that already dismissed the sheet sees only that step.
    var helperOffered = false
    /// The welcome sheet has offered to make spacebar the default app for Markdown, images and data files once.
    var openerOffered = false
    /// The preview has shown its one-time "Click to edit" hint.
    var editHintShown = false
    /// What the toolbar's Raw toggle once remembered per kind. Raw now lasts only while the preview stays open, so these are
    /// read (old files keep sanitizing) but no longer change what is shown.
    var rawMarkdown = false
    var rawJSON = false
    var rawNotebook = false
    var rawCSV = false
    var rawXML = false
    var rawCSS = false
    /// Long lines wrapped in the text view, remembered per kind: prose (text and logs) and Markdown's source wrap, code does not.
    var wrapText = true
    var wrapMarkdown = true
    var wrapCode = false

    /// 2: folder previews became on by default. A file written before that stores the old default, false, so it reads as on
    /// until SettingsFile.update rewrites it; a user who turns them off afterwards stays off.
    /// 3: reading stats became off by default.
    /// 4: reading stats left the settings window, so a file from before is read and rewritten with them off: its "on" was almost
    /// always the old default, which the window could no longer turn off.
    /// 5: README first became off by default, so the sidebar lists a folder as Finder does; a file from before is read and
    /// rewritten with it off, its "on" being the old default.
    /// 6: HTML scripts became "ask" by default; a file from before that stores "local", the old default, is read and rewritten
    /// as "ask". A "local" chosen afterwards stays.
    static let currentVersion = 6
    static func fileVersion(_ raw: [String: Any]) -> Int { (raw["version"] as? NSNumber)?.intValue ?? 1 }

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
        "folderViewMedia": ["grid", "list"],
        "folderViewOther": ["list", "grid"],
        "foldersFirst": ["finder", "always", "never"],
        "frontMatter": ["table", "hide", "raw"],
        "toc": ["auto", "on", "off"],
        "mdLinks": ["preview", "editor"],
        "webLinks": ["browser"],
        "rawHTML": ["off", "sanitized"],
        "htmlScripts": ["ask", "local", "off"],
    ]
    static let intRanges: [String: ClosedRange<Int>] = ["fontSize": 12...24, "sidebarWidth": 160...480]
    static let doubleRanges: [String: ClosedRange<Double>] = ["lineHeight": 1.2...2.0]
    static let boolKeys: Set<String> = Set(["customCSS", "inlineEditing", "taskToggles", "folderMode", "folderReadmeFirst", "stats", "math",
                                        "mermaid", "remoteImages", "sidebarCollapsed", "sidebarKeys", "showHiddenFiles", "minimalChrome", "checkUpdates",
                                        "welcomeShown", "spaceHelper", "helperOffered", "openerOffered", "editHintShown"]).union(rawKeys).union(wrapKeys)
    static let rawKeys: Set<String> = ["rawMarkdown", "rawJSON", "rawNotebook", "rawCSV", "rawXML", "rawCSS"]
    static let wrapKeys: Set<String> = ["wrapText", "wrapMarkdown", "wrapCode"]
    /// Keys whose value is a string or null, each checked by its own pattern.
    static let optionalKeys: Set<String> = ["userTheme", "editorBundleID", "imageAppBundleID"]
    static var allKeys: Set<String> { Set(choices.keys).union(intRanges.keys).union(doubleRanges.keys).union(boolKeys).union(optionalKeys) }
    /// The only keys the preview panel may change (its Aa popover and sidebar controls). The page renders an untrusted document,
    /// so even a page that was somehow scripted can restyle the preview but never pick a CSS file, an editor app, or what is
    /// rendered or opened. folderSort and foldersFirst only reorder what is listed, and the folder views lay it out as a grid or a
    /// list (a folder of images shows its grid instead of opening its README); showHiddenFiles would list, and so open, more, so
    /// it is changed in the settings window only.
    static let panelKeys: Set<String> = Set(["theme", "appearance", "fontSize", "width", "bodyFont", "sidebarCollapsed", "sidebarWidth", "folderSort", "foldersFirst",
                                             "folderViewMedia", "folderViewOther", "editHintShown"])
        .union(rawKeys).union(wrapKeys)
    /// The keys the settings window shows, on its page and under Advanced. Every other key is changed in the preview (panelKeys),
    /// by spacebar itself, or in settings.json only, and keeps its stored value.
    static let windowKeys: Set<String> = ["theme", "appearance", "fontSize", "spaceHelper", "editorBundleID", "imageAppBundleID", "checkUpdates"]
    static let advancedKeys: Set<String> = ["htmlScripts", "rawHTML", "remoteImages", "inlineEditing", "taskToggles", "showHiddenFiles", "userTheme", "customCSS"]
    /// Kept by Reset to Defaults: resetting must not bring the welcome sheet back or change the Space helper behind its Login Items entry.
    static let keptOnReset = ["welcomeShown", "helperOffered", "openerOffered", "spaceHelper", "editHintShown"]

    /// Reset to Defaults as a patch: every key at its default, including the ones only settings.json can change. The kept keys
    /// are left out, so the file's own values stand.
    static func resetPatch() -> [String: Any] {
        var d = Settings().dictionary
        for k in keptOnReset { d.removeValue(forKey: k) }
        return d
    }

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
        if !raw.isEmpty, Self.fileVersion(raw) < 2 { d["folderMode"] = true }
        if !raw.isEmpty, Self.fileVersion(raw) < 4 { d["stats"] = false }
        if !raw.isEmpty, Self.fileVersion(raw) < 5 { d["folderReadmeFirst"] = false }
        if !raw.isEmpty, Self.fileVersion(raw) < 6, d["htmlScripts"] as? String == "local" { d["htmlScripts"] = "ask" }
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
        take(.width, \.width); takeOptional(.editorBundleID, \.editorBundleID); takeOptional(.imageAppBundleID, \.imageAppBundleID)
        take(.inlineEditing, \.inlineEditing); take(.taskToggles, \.taskToggles); take(.folderMode, \.folderMode)
        take(.folderReadmeFirst, \.folderReadmeFirst); take(.folderSort, \.folderSort); take(.foldersFirst, \.foldersFirst); take(.frontMatter, \.frontMatter)
        take(.folderViewMedia, \.folderViewMedia); take(.folderViewOther, \.folderViewOther)
        take(.sidebarCollapsed, \.sidebarCollapsed); take(.sidebarKeys, \.sidebarKeys); take(.showHiddenFiles, \.showHiddenFiles); take(.minimalChrome, \.minimalChrome)
        if let n = try? c.decodeIfPresent(Double.self, forKey: .sidebarWidth), let v = Self.sanitize("sidebarWidth", n) as? Int { s.sidebarWidth = v }
        take(.toc, \.toc); take(.stats, \.stats); take(.mdLinks, \.mdLinks); take(.webLinks, \.webLinks)
        take(.math, \.math); take(.mermaid, \.mermaid); take(.rawHTML, \.rawHTML); take(.remoteImages, \.remoteImages); take(.checkUpdates, \.checkUpdates); take(.htmlScripts, \.htmlScripts)
        take(.welcomeShown, \.welcomeShown); take(.spaceHelper, \.spaceHelper); take(.helperOffered, \.helperOffered); take(.openerOffered, \.openerOffered)
        take(.editHintShown, \.editHintShown)
        take(.rawMarkdown, \.rawMarkdown); take(.rawJSON, \.rawJSON); take(.rawNotebook, \.rawNotebook); take(.rawCSV, \.rawCSV)
        take(.rawXML, \.rawXML); take(.rawCSS, \.rawCSS)
        take(.wrapText, \.wrapText); take(.wrapMarkdown, \.wrapMarkdown); take(.wrapCode, \.wrapCode)
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

enum WelcomeStep: Equatable { case intro, helper, opener }

extension Settings {
    /// The welcome sheet's pages: the introduction until it is dismissed once, then the helper's offer once, where there is one,
    /// then the default-app offer once, where this copy can make itself the default.
    func welcomeSteps(helperAvailable: Bool, openerAvailable: Bool) -> [WelcomeStep] {
        (welcomeShown ? [] : [.intro]) + (helperAvailable && !helperOffered ? [.helper] : []) + (openerAvailable && !openerOffered ? [.opener] : [])
    }
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
    /// name, known or not, are kept as they are. `when`, checked on the settings read under the lock, must hold for the patch
    /// to be taken. Returns the settings now on disk.
    @discardableResult
    static func update(_ patch: [String: Any], allowed: Set<String> = Settings.allKeys, at url: URL = url,
                       when: ((Settings) -> Bool)? = nil) -> Result<Settings, Failure> {
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
        // Migrated before the patch, so a user's "off" in the same write is kept.
        if Settings.fileVersion(obj) < Settings.currentVersion {
            // No file yet: nothing was written under an older default.
            if !obj.isEmpty, Settings.fileVersion(obj) < 4, obj["stats"] as? Bool == true { obj["stats"] = false }
            if !obj.isEmpty, Settings.fileVersion(obj) < 5, obj["folderReadmeFirst"] as? Bool == true { obj["folderReadmeFirst"] = false }
            if !obj.isEmpty, Settings.fileVersion(obj) < 6, obj["htmlScripts"] as? String == "local" { obj["htmlScripts"] = "ask" }
            if Settings.fileVersion(obj) < 2 { obj["folderMode"] = true }
            obj["version"] = Settings.currentVersion
            changed = true
        }
        let take = when?(Settings(dictionary: obj)) ?? true
        for (k, v) in patch where take && allowed.contains(k) {
            guard let clean = Settings.sanitize(k, v) else { continue }
            obj[k] = clean
            changed = true
        }
        if changed { if let f = write(obj, to: url) { return .failure(f) } }
        return .success(Settings(dictionary: obj))
    }

    /// Brings an existing settings.json up to Settings.currentVersion. Run by the app and the writer, never the sandboxed extension.
    /// A symbolic link (a dotfiles setup) is never written, so it is not migrated: until its target gains the current "version"
    /// it reads as folder previews on whatever its folderMode says, and reading stats and README first off. The failure is
    /// returned for the caller's log.
    @discardableResult
    static func migrate(at url: URL = url) -> Failure? {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        if case .failure(let f) = update([:], at: url) { return f }
        return nil
    }

    /// The writer's `updateSettings`: a small JSON object from the preview panel, merged with only Settings.panelKeys allowed.
    /// Nil when the patch is not such an object.
    static func updateFromPanel(_ patch: Data, at url: URL = url) -> Result<Settings, Failure>? {
        guard patch.count <= 4096, let obj = (try? JSONSerialization.jsonObject(with: patch)) as? [String: Any] else { return nil }
        return update(obj, allowed: Settings.panelKeys, at: url)
    }

    /// The writer's `answerScripts`: the preview's "Run scripts?" bar sets htmlScripts to "local" or "off", and only while it is
    /// "ask", so the preview can answer the question once but never turn scripts back on. Nil when refused.
    static func answerScripts(_ value: String, at url: URL = url) -> Result<Settings, Failure>? {
        guard ["local", "off"].contains(value) else { return nil }
        let r = update(["htmlScripts": value], at: url, when: { $0.htmlScripts == "ask" })
        if case .success(let s) = r, s.htmlScripts != value { return nil }
        return r
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
