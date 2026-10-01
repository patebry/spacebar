import Foundation

/// Which folders a folder preview takes, and where a single file's sidebar is rooted.
enum FolderRules {
    /// Folders never previewed, by their resolved path: the top of the system and the disk's own layout.
    static let systemFolders: Set<String> = ["/", "/System", "/Library", "/Applications", "/Users", "/Volumes", "/Network", "/cores", "/dev",
                                             "/opt", "/private", "/private/etc", "/private/tmp", "/private/var", "/usr", "/bin", "/sbin"]
    /// Trees nothing below which is previewed (/usr/local is the one part of /usr that holds people's own files).
    static let systemTrees = ["/System/", "/dev/", "/bin/", "/sbin/", "/usr/"]
    /// Folders that are documents or apps even where the system does not mark them as packages.
    static let packageExtensions: Set<String> = FileTypes.appExtensions.union(["xcodeproj", "xcworkspace", "photoslibrary", "musiclibrary",
                                                                               "tvlibrary", "fcpbundle", "logicx", "band", "rtfd", "pages",
                                                                               "numbers", "key", "sparsebundle", "xcarchive", "playground"])

    static var home: String { getpwuid(getuid()).flatMap { String(validatingUTF8: $0.pointee.pw_dir) } ?? NSHomeDirectory() }

    /// Why the folder at `path` is not previewed, or nil when it is. Only cheap checks (a realpath, two stats and the URL's
    /// resource values), so the answer is known before the preview starts.
    static func declineReason(_ path: String, home: String = FolderRules.home) -> String? {
        guard let real = FolderListing.realPath(path) else { return "cannot read the folder" }
        var st = stat(), parent = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return "not a folder" }
        if systemFolders.contains(real) || real == (FolderListing.realPath(home) ?? home) + "/Library" { return "a system folder" }
        if systemTrees.contains(where: real.hasPrefix), !real.hasPrefix("/usr/local/") { return "inside a system folder" }
        let url = URL(fileURLWithPath: real)
        let values = try? url.resourceValues(forKeys: [.isPackageKey, .isApplicationKey, .isVolumeKey])
        // A mount point sits on another device than its parent.
        if values?.isVolume == true || (stat((real as NSString).deletingLastPathComponent, &parent) == 0 && parent.st_dev != st.st_dev) {
            return "the top of a volume"
        }
        if values?.isPackage == true || values?.isApplication == true || packageExtensions.contains(url.pathExtension.lowercased()) {
            return "a package or app bundle"
        }
        return nil
    }

    /// Whether the file came from the internet (Gatekeeper's quarantine attribute). Such a file keeps its own folder as its root:
    /// rooting it at a vault would let a downloaded note embed or list the rest of the vault.
    static func isQuarantined(_ path: String) -> Bool { getxattr(path, "com.apple.quarantine", nil, 0, 0, 0) >= 0 }

    /// The Obsidian vault a single file sits in: the nearest folder above `dir` (itself included, at most 8 levels up) that holds a
    /// `.obsidian` folder. Never the home folder, a system folder or anything above them. Nil when there is none.
    static func vaultRoot(containing dir: String, home: String = FolderRules.home) -> String? {
        var d = dir
        for _ in 0..<8 {
            // resolvingSymlinksInPath spells /private/tmp and /private/var without /private.
            if d == "/" || d == home || ["/tmp", "/var", "/etc"].contains(d) || systemFolders.contains(d) || d.isEmpty { return nil }
            var st = stat()
            if lstat(d + "/.obsidian", &st) == 0, st.st_mode & S_IFMT == S_IFDIR { return d }
            d = (d as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// A bounded, breadth-first look through a folder: the Markdown a folder preview opens on when the folder itself holds none, and
/// the numbers and recent files of the folder overview. Hidden files and folders (and so `.obsidian` and `.git`) are left out
/// unless `showHidden`; dependency and build folders are never entered; packages count as one item; a symbolic link is taken only
/// when it resolves to a file inside the root, and linked folders are never followed. Call it off the main thread.
enum FolderScan {
    static let maxDepth = 3
    static let maxEntries = 5_000
    static let budget: TimeInterval = 0.25
    static let recentCount = 8
    /// Folders a scan or the link index never enters, whatever `showHidden` says.
    static let skipped: Set<String> = [".obsidian", ".git", ".trash", ".Trash", "node_modules", "__pycache__", ".venv", "venv", "Pods",
                                       "DerivedData", ".build", ".next", ".cache", "bower_components"]
    /// Names that make a note the one to open, in order of preference (compared without extension, lowercased).
    static let preferredNames = ["readme", "index", "home", "welcome", "start here", "start", "overview", "contents", "00 index", "_index"]

    struct Item: Equatable {
        let path: String
        let rel: String
        let depth: Int
        let kind: FileKind
        let size: Int64
        let modified: Double
    }

    struct Result {
        let root: String
        /// Files found, in the order the scan met them (shallow first).
        var files: [Item] = []
        var folders = 0
        var counts: [String: Int] = [:]
        /// False when the entry cap or the time budget cut the scan short.
        var complete = true
        var scanned = 0
        var hasObsidian = false
        var hasGit = false

        /// The Markdown file to open: shallowest first, then a preferred name (the folder's own name counts), then the newest.
        var bestMarkdown: Item? {
            let rootName = (root as NSString).lastPathComponent.lowercased()
            func rank(_ i: Item) -> Int {
                let stem = ((i.path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased()
                if let n = FolderScan.preferredNames.firstIndex(of: stem) { return n }
                return stem == rootName ? FolderScan.preferredNames.count : 99
            }
            return files.filter { $0.kind == .markdown }.min { a, b in
                if a.depth != b.depth { return a.depth < b.depth }
                if rank(a) != rank(b) { return rank(a) < rank(b) }
                if a.modified != b.modified { return a.modified > b.modified }
                return a.rel.localizedStandardCompare(b.rel) == .orderedAscending
            }
        }

        var recent: [Item] { Array(files.sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.rel < $1.rel }.prefix(FolderScan.recentCount)) }

        /// What the page is sent to draw the overview. Every path in it is one the scan found inside the root.
        func payload(reason: String) -> [String: Any] {
            var p = FileView.base(path: root, root: root, reason: reason)
            p["view"] = "overview"
            p["base"] = FileTypes.fileURL(root + "/")!.absoluteString
            p["counts"] = counts
            p["folders"] = folders
            p["total"] = folders + files.count
            p["complete"] = complete
            p["depth"] = FolderScan.maxDepth
            p["label"] = hasObsidian ? "Obsidian vault" : hasGit ? "Git repository" : "Folder"
            p["recent"] = recent.map { ["name": ($0.path as NSString).lastPathComponent, "path": $0.path, "rel": $0.rel, "icon": $0.kind.icon,
                                        "size": $0.size, "modified": $0.modified * 1000] as [String: Any] }
            return p
        }
    }

    /// The count bucket of a file kind in the overview.
    static func bucket(_ k: FileKind) -> String {
        switch k {
        case .markdown: return "markdown"
        case .image: return "image"
        case .pdf: return "pdf"
        case .video, .audio: return "media"
        case .code, .html: return "code"
        case .json, .csv: return "data"
        case .text, .rtf: return "text"
        default: return "other"
        }
    }

    static func scan(_ root: String, showHidden: Bool = false, maxDepth: Int = maxDepth, maxEntries: Int = maxEntries,
                     budget: TimeInterval = budget) -> Result {
        var r = Result(root: root)
        guard let realRoot = FolderListing.realPath(root) else { return r }
        let inside = realRoot == "/" ? "/" : realRoot + "/"
        var st = stat()
        r.hasObsidian = lstat(root + "/.obsidian", &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
        r.hasGit = lstat(root + "/.git", &st) == 0
        let start = Date()
        var queue: [(String, Int)] = [(root, 0)]
        var head = 0
        outer: while head < queue.count {
            let (dir, depth) = queue[head]
            head += 1
            var names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if Date().timeIntervalSince(start) > budget { r.complete = false; break }
            // Finder order for the tie-break between equal notes; a huge folder is taken as it comes rather than sorted past the budget.
            if names.count <= 2_000 { names.sort { $0.localizedStandardCompare($1) == .orderedAscending } }
            for name in names {
                if r.scanned >= maxEntries || Date().timeIntervalSince(start) > budget { r.complete = false; break outer }
                r.scanned += 1
                let path = (dir as NSString).appendingPathComponent(name)
                guard lstat(path, &st) == 0 else { continue }
                if !showHidden && FolderListing.isHidden(name, st) { continue }
                var type = st.st_mode & S_IFMT
                if type == S_IFLNK {
                    guard let real = FolderListing.realPath(path), real.hasPrefix(inside), stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
                    type = S_IFREG
                }
                let rel = String(path.dropFirst(root == "/" ? 1 : root.count + 1))
                if type == S_IFDIR {
                    if skipped.contains(name) { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    let package = !ext.isEmpty && (FolderRules.packageExtensions.contains(ext)
                        || ((try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isPackageKey]))?.isPackage ?? false))
                    if !package {
                        r.folders += 1
                        if depth < maxDepth { queue.append((path, depth + 1)) }
                        continue
                    }
                } else if type != S_IFREG {
                    continue
                }
                let kind = FileTypes.kind(name: name, isDirectory: type == S_IFDIR, isPackage: type == S_IFDIR, executable: st.st_mode & 0o111 != 0)
                r.counts[bucket(kind), default: 0] += 1
                let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
                r.files.append(Item(path: path, rel: rel, depth: depth, kind: kind, size: type == S_IFREG ? Int64(st.st_size) : 0, modified: modified))
            }
        }
        return r
    }
}

/// Obsidian-style `[[wikilinks]]` and `![[embeds]]`: a bounded index of the files under the root by name, and what a document's
/// links resolve to. Resolution never leaves the root: every target is a file the index found inside it (symbolic links only when
/// they resolve inside it, linked folders never followed), and is checked again against the root when it is resolved.
final class LinkIndex {
    static let maxEntries = 20_000
    static let maxDepth = 12
    static let budget: TimeInterval = 0.4
    static let maxTargets = 500
    static let maxTargetBytes = 400
    static let maxEmbeds = 16
    static let maxEmbedBytes = 64 << 10

    let root: String
    /// The root with symlinks resolved, taken once: every resolution is checked against it.
    let realRoot: String?
    /// Lowercased, NFC file names (and Markdown names without their extension) to the paths that have them.
    private(set) var byName: [String: [String]] = [:]
    private(set) var byRel: [String: String] = [:]
    private(set) var complete = true
    private(set) var count = 0
    let built = Date()

    init(root: String) {
        self.root = root
        realRoot = FolderListing.realPath(root)
    }

    static func key(_ s: String) -> String { s.precomposedStringWithCanonicalMapping.lowercased() }

    /// Builds the index; call it off the main thread.
    static func build(root: String, showHidden: Bool = false, maxEntries: Int = maxEntries, maxDepth: Int = maxDepth,
                      budget: TimeInterval = budget) -> LinkIndex {
        let idx = LinkIndex(root: root)
        guard let realRoot = FolderListing.realPath(root) else { return idx }
        let inside = realRoot == "/" ? "/" : realRoot + "/"
        let start = Date()
        var queue: [(String, Int)] = [(root, 0)]
        var head = 0
        var st = stat()
        outer: while head < queue.count {
            let (dir, depth) = queue[head]
            head += 1
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            if Date().timeIntervalSince(start) > budget { idx.complete = false; break }
            for name in names {
                if idx.count >= maxEntries || Date().timeIntervalSince(start) > budget { idx.complete = false; break outer }
                idx.count += 1
                let path = (dir as NSString).appendingPathComponent(name)
                guard lstat(path, &st) == 0 else { continue }
                if !showHidden && FolderListing.isHidden(name, st) { continue }
                var type = st.st_mode & S_IFMT
                if type == S_IFLNK {
                    guard let real = FolderListing.realPath(path), real.hasPrefix(inside), stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { continue }
                    type = S_IFREG
                }
                if type == S_IFDIR {
                    let ext = (name as NSString).pathExtension.lowercased()
                    if !FolderScan.skipped.contains(name), depth < maxDepth, !FolderRules.packageExtensions.contains(ext) { queue.append((path, depth + 1)) }
                    continue
                }
                guard type == S_IFREG else { continue }
                idx.add(path)
            }
        }
        return idx
    }

    private func add(_ path: String) {
        let name = (path as NSString).lastPathComponent
        byName[Self.key(name), default: []].append(path)
        if FileTypes.markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
            byName[Self.key((name as NSString).deletingPathExtension), default: []].append(path)
        }
        byRel[Self.key(String(path.dropFirst(root == "/" ? 1 : root.count + 1)))] = path
    }

    /// A link's parts: `target#heading|alias`. `\|` (a pipe escaped inside a table) counts as the alias separator.
    static func parse(_ inner: String) -> (target: String, heading: String, alias: String) {
        let s = inner.replacingOccurrences(of: "\\|", with: "|")
        let bar = s.firstIndex(of: "|")
        let head = bar.map { String(s[..<$0]) } ?? s
        let alias = bar.map { String(s[s.index(after: $0)...]) } ?? ""
        let hash = head.firstIndex(of: "#")
        let target = hash.map { String(head[..<$0]) } ?? head
        let heading = hash.map { String(head[head.index(after: $0)...]) } ?? ""
        return (target.trimmingCharacters(in: .whitespaces), heading.trimmingCharacters(in: .whitespaces), alias.trimmingCharacters(in: .whitespaces))
    }

    /// Every distinct link in `text`, in order: its target (as the page keys it) and whether it is an embed. At most `max`.
    static func links(in text: String, max: Int = maxTargets) -> [(target: String, embed: Bool)] {
        var out: [(String, Bool)] = []
        var seen: Set<String> = []
        // A UTF-16 copy: the expression reads a native (UTF-8) string through its bridge ten times slower than the copy costs.
        let ns = NSMutableString(string: text) as String as NSString
        guard let re = try? NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]{1,400})\]\]"#) else { return [] }
        for m in re.matches(in: ns as String, range: NSRange(location: 0, length: ns.length)) {
            let embed = m.range(at: 1).length > 0
            let t = parse(ns.substring(with: m.range(at: 2))).target
            guard !t.isEmpty, seen.insert((embed ? "!" : "") + t).inserted else { continue }
            out.append((t, embed))
            if out.count >= max { break }
        }
        return out
    }

    /// The file `target` names, as Obsidian finds it: a path from the root (`folder/Note`), or a file name anywhere under the root,
    /// with or without `.md`. Several matches: the one in `from`'s folder, then the shallowest, then by name. Nil when nothing
    /// under the root matches, or the target has an empty, `.` or `..` step.
    func resolve(_ target: String, from current: String?) -> String? {
        var t = target.trimmingCharacters(in: .whitespaces)
        while t.hasPrefix("/") { t.removeFirst() }
        guard !t.isEmpty, t.utf8.count <= Self.maxTargetBytes, !t.contains("\0") else { return nil }
        let steps = t.split(separator: "/", omittingEmptySubsequences: false)
        guard !steps.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        var candidates: [String]
        if steps.count > 1 {
            let k = Self.key(t)
            if let p = byRel[k] ?? FileTypes.markdownExtensions.lazy.compactMap({ self.byRel[k + "." + $0] }).first {
                candidates = [p]
            } else {
                // A partial path: the name, in a folder whose path ends with the rest.
                let tail = "/" + k
                candidates = (byName[Self.key(String(steps.last!))] ?? []).filter { p in
                    let lower = Self.key(p)
                    return lower.hasSuffix(tail) || FileTypes.markdownExtensions.contains { lower.hasSuffix(tail + "." + $0) }
                }
            }
        } else {
            candidates = byName[Self.key(t)] ?? []
        }
        let here = current.map { ($0 as NSString).deletingLastPathComponent }
        let best = candidates.min { a, b in
            let ha = (a as NSString).deletingLastPathComponent == here, hb = (b as NSString).deletingLastPathComponent == here
            if ha != hb { return ha }
            let da = a.split(separator: "/").count, db = b.split(separator: "/").count
            if da != db { return da < db }
            return a < b
        }
        guard let best, let realRoot, FolderListing.isPlainPath(best, under: root), let real = FolderListing.realPath(best),
              real.hasPrefix(realRoot == "/" ? "/" : realRoot + "/") else { return nil }
        return best
    }

    /// What a Markdown render is sent about its links: `links` maps each target to the file it resolves to (path, icon and, for
    /// an image, its `file` URL); `embeds` holds the text of each embedded note (one level: an embedded note's own links are
    /// resolved, its embeds are not expanded). `paths` is every file named, which the page may then ask to open.
    func payload(text: String, current: String?) -> (links: [String: Any], embeds: [String: Any], paths: Set<String>) {
        var links: [String: Any] = [:], embeds: [String: Any] = [:], paths: Set<String> = []
        var embedBytes = 0
        func link(_ target: String, from: String?) -> (String, FileKind)? {
            if let done = links[target] as? [String: Any], let p = done["path"] as? String { return (p, FileTypes.kind(name: (p as NSString).lastPathComponent)) }
            guard let p = resolve(target, from: from) else { return nil }
            let kind = FileTypes.kind(name: (p as NSString).lastPathComponent)
            var e: [String: Any] = ["path": p, "icon": kind.icon, "name": (p as NSString).lastPathComponent, "kind": kind.rawValue]
            if kind == .image, let src = Self.imageURL(p) { e["src"] = src }
            links[target] = e
            paths.insert(p)
            return (p, kind)
        }
        let own = Self.links(in: text)
        // The document's own links first, so a target it shares with an embedded note resolves from the document.
        for (target, _) in own { _ = link(target, from: current) }
        for (target, embed) in own {
            guard let found = link(target, from: current), embed, found.1 == .markdown, embeds[target] == nil, embeds.count < Self.maxEmbeds,
                  embedBytes < Self.maxEmbedBytes * 4, let body = Self.readNote(found.0) else { continue }
            let p = found.0
            embedBytes += body.utf8.count
            embeds[target] = ["path": p, "text": body]
            // An embedded note's links are resolved from its own folder (the page keys them by target, so the document's own
            // link to the same target wins).
            for (t, _) in Self.links(in: body, max: 100) where links.count < Self.maxTargets { _ = link(t, from: p) }
        }
        return (links, embeds, paths)
    }

    /// An image's `file` URL, versioned by its modification time; nil past the image size limit.
    static func imageURL(_ path: String) -> String? {
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, Int64(st.st_size) <= FileTypes.maxImageBytes else { return nil }
        return FileTypes.fileURL(path, version: "\(st.st_mtimespec.tv_sec)\(st.st_mtimespec.tv_nsec)")?.absoluteString
    }

    /// The first 64 KB of a note, when it is a regular file that reads as text.
    static func readNote(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { close(fd); return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let read = { (try? h.read(upToCount: maxEmbedBytes)) ?? Data() }
        let data = st.st_size <= FolderListing.maxDocumentBytes ? FileTypes.materializing(read) : read()
        guard FileTypes.looksLikeText(data) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

/// The sidebar filter's Contents mode: the text of the files the sidebar lists under the root, matched as case-insensitive
/// plain text. The files are those FolderListing lists (hidden files by the setting, each folder within the listing caps, links
/// only inside the root), folder by folder from the root down; dependency and build folders (FolderScan.skipped) are never
/// entered, and a folder reached twice through a link is searched once. Only Markdown, code, JSON, CSV and text are read, at
/// most `maxFileBytes` of each (what the text view shows), and only what TextDecoding reads as text: binary is skipped, and a
/// file iCloud has evicted is skipped rather than downloaded. `Limits` bound the files, the bytes, the results and the time; a
/// search cut short says why. Searches run one at a time on `queue`; `Cancel` stops one between files. The list of files is
/// kept for `listTTL`, so the keystrokes of one word walk the tree once.
enum ContentSearch {
    struct Limits {
        var maxFiles = 20_000
        var maxFileBytes = FileTypes.maxTextBytes
        var maxTotalBytes = 64 << 20
        var maxResults = 500
        var budget: TimeInterval = 2
        /// Listing the tree has a budget of its own.
        var walkBudget: TimeInterval = 1
        var maxDepth = 32
    }
    static let queue = DispatchQueue(label: "md.spacebar.search", qos: .userInitiated)
    static let listTTL: TimeInterval = 5
    static let maxQueryBytes = 256
    /// Matches in one file are counted up to this.
    static let maxCount = 9_999
    static let snippetBytes = 160
    static let snippetLead = 20
    static let kinds: Set<FileKind> = [.markdown, .code, .json, .csv, .text]

    struct Hit: Equatable {
        let path: String
        let count: Int
        /// 1-based line of the first match.
        let line: Int
        let snippet: String
    }

    /// One report: the hits found since the last one, and where the search is.
    struct Progress {
        var hits: [Hit] = []
        var searched = 0
        var total = 0
        var done = false
        /// A folder had more entries than the listing shows: only its listed files were searched.
        var listedOnly = false
        /// Why a finished search did not look at every file: "files", "bytes", "time" or "results".
        var stopped: String?
    }

    final class Cancel {
        private let lock = NSLock()
        private var flag = false
        func cancel() { lock.lock(); flag = true; lock.unlock() }
        var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }

    /// The query lowercased; an ASCII query is matched against ASCII-folded bytes, anything else against the lowercased text.
    struct Matcher {
        let needle: [UInt8]
        let ascii: Bool

        init?(_ query: String) {
            let q = query.lowercased()
            guard !q.isEmpty, q.utf8.count <= ContentSearch.maxQueryBytes else { return nil }
            needle = Array(q.utf8)
            ascii = needle.allSatisfy { $0 < 0x80 }
        }

        /// The number of non-overlapping matches (at most maxCount) and the byte offset of the first, in `hay`.
        func scan(_ hay: UnsafeBufferPointer<UInt8>, fold: Bool) -> (count: Int, first: Int) {
            let m = needle.count, n = hay.count
            guard m <= n else { return (0, -1) }
            var count = 0, first = -1, i = 0
            let lead = needle[0]
            needle.withUnsafeBufferPointer { nd in
                while i <= n - m {
                    let b = hay[i]
                    if (fold && b &- 65 < 26 ? b | 0x20 : b) == lead {
                        var j = 1
                        while j < m {
                            let c = hay[i + j]
                            if (fold && c &- 65 < 26 ? c | 0x20 : c) != nd[j] { break }
                            j += 1
                        }
                        if j == m {
                            if first < 0 { first = i }
                            count += 1
                            if count >= ContentSearch.maxCount { return }
                            i += m
                            continue
                        }
                    }
                    i += 1
                }
            }
            return (count, first)
        }

        /// The hit for `text`, the file at `path`, or nil when nothing matches.
        func hit(_ text: String, path: String) -> Hit? {
            var t = TextDecoding.nativeUTF8(text)
            if ascii {
                return t.withUTF8 { buf -> Hit? in
                    let (count, first) = scan(buf, fold: true)
                    guard count > 0 else { return nil }
                    return Hit(path: path, count: count, line: ContentSearch.line(buf, at: first), snippet: ContentSearch.snippet(buf, at: first))
                }
            }
            var low = TextDecoding.nativeUTF8(t.lowercased())
            let found = low.withUTF8 { buf -> (count: Int, line: Int, chars: Int)? in
                let (count, first) = scan(buf, fold: false)
                guard count > 0 else { return nil }
                let start = ContentSearch.lineStart(buf, at: first)
                let before = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<first]), as: UTF8.self)
                return (count, ContentSearch.line(buf, at: first), before.count)
            }
            guard let found else { return nil }
            // Lowercasing keeps every line break and, but for rare letters, every character: the match is as many characters
            // into the same line of the original text.
            return t.withUTF8 { buf -> Hit in
                var start = 0, n = 1
                while n < found.line, let nl = UnsafeBufferPointer(rebasing: buf[start...]).firstIndex(of: 0x0A) { start += nl + 1; n += 1 }
                var end = start
                while end < buf.count && buf[end] != 0x0A { end += 1 }
                let line = String(decoding: UnsafeBufferPointer(rebasing: buf[start..<end]), as: UTF8.self)
                let at = line.index(line.startIndex, offsetBy: found.chars, limitedBy: line.endIndex) ?? line.endIndex
                let offset = line.utf8.distance(from: line.startIndex, to: at)
                return Hit(path: path, count: found.count, line: found.line, snippet: ContentSearch.snippet(buf, at: start + offset))
            }
        }
    }

    static func lineStart(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
        var s = min(i, buf.count)
        while s > 0 && buf[s - 1] != 0x0A { s -= 1 }
        return s
    }

    static func line(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> Int {
        var n = 1
        for k in 0..<min(i, buf.count) where buf[k] == 0x0A { n += 1 }
        return n
    }

    /// The line holding byte `i`, from a little before it (a sidebar row shows about 40 characters) to at most `snippetBytes`,
    /// cut on character boundaries and trimmed.
    static func snippet(_ buf: UnsafeBufferPointer<UInt8>, at i: Int) -> String {
        let s = lineStart(buf, at: i)
        var e = min(i, buf.count)
        while e < buf.count && buf[e] != 0x0A { e += 1 }
        var a = i - s > snippetLead + 4 ? i - snippetLead : s
        while a > s && buf[a] & 0xC0 == 0x80 { a -= 1 }
        var b = min(e, a + snippetBytes)
        while b < e && buf[b] & 0xC0 == 0x80 { b -= 1 }
        let text = String(decoding: UnsafeBufferPointer(rebasing: buf[a..<b]), as: UTF8.self)
            .replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r", with: "")
            .trimmingCharacters(in: .whitespaces)
        return (a > s ? "…" : "") + text + (b < e ? "…" : "")
    }

    /// What the page is sent for one report of search `seq`.
    static func payload(_ p: Progress, seq: Int) -> [String: Any] {
        var d: [String: Any] = ["seq": seq, "searched": p.searched, "total": p.total, "done": p.done, "listedOnly": p.listedOnly,
                                "hits": p.hits.map { h -> [String: Any] in
                                    let name = (h.path as NSString).lastPathComponent
                                    return ["path": h.path, "name": name, "icon": FileTypes.glyph(name: name, kind: FileTypes.kind(name: name)),
                                            "count": h.count, "line": h.line, "snippet": h.snippet]
                                }]
        if let s = p.stopped { d["stopped"] = s }
        return d
    }

    /// The files to search, in the order they are searched: each folder's files as it lists them, the root's first.
    static func files(root: String, sort: String, readmeFirst: Bool, showHidden: Bool, only: Set<String>? = nil, limits: Limits,
                      until deadline: Date, cancel: Cancel) -> (paths: [String], listedOnly: Bool, stopped: String?) {
        var paths: [String] = [], listedOnly = false
        var queue: [(String, Int)] = [(root, 0)], head = 0
        var seen: Set<String> = FolderListing.realPath(root).map { [$0] } ?? []
        while head < queue.count {
            if cancel.isCancelled { return (paths, listedOnly, "cancelled") }
            if Date() > deadline { return (paths, listedOnly, "time") }
            let (dir, depth) = queue[head]
            head += 1
            var l = FolderListing.list(dir, root: root, sort: sort, readmeFirst: readmeFirst, showHidden: showHidden)
            if let only { l = FolderListing.only(l, selection: only) }
            if l.more > 0 { listedOnly = true }
            for e in l.entries where !e.broken {
                if e.isDirectory {
                    guard depth < limits.maxDepth, !FolderScan.skipped.contains(e.name), let real = FolderListing.realPath(e.path),
                          seen.insert(real).inserted else { continue }
                    queue.append((e.path, depth + 1))
                } else if kinds.contains(e.kind) {
                    if paths.count >= limits.maxFiles { return (paths, listedOnly, "files") }
                    paths.append(e.path)
                }
            }
        }
        return (paths, listedOnly, nil)
    }

    /// The text of the file at `path` from its first `cap` bytes (nil when it cannot be read without a download, or is not text),
    /// and how many bytes were read. `inside` is the resolved root with a trailing slash: a file swapped for a link out of the
    /// root since it was listed is not read.
    static func read(_ path: String, cap: Int, inside: String) -> (text: String?, bytes: Int) {
        guard let real = FolderListing.realPath(path), real.hasPrefix(inside) else { return (nil, 0) }
        let fd = open(real, O_RDONLY | O_NONBLOCK | O_CLOEXEC | O_NOFOLLOW)
        guard fd >= 0 else { return (nil, 0) }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & 0x4000_0000 == 0, st.st_size > 0,
              let data = try? h.read(upToCount: cap), !data.isEmpty else { return (nil, 0) }
        return (TextDecoding.decode(data, truncated: Int64(data.count) < Int64(st.st_size))?.text, data.count)
    }

    /// The last tree walked, reused within `listTTL`. Read and written only on `queue` (or a test's one thread).
    private static var cached: (key: String, at: Date, files: (paths: [String], listedOnly: Bool, stopped: String?))?

    /// Searches for `query`, calling `report` (on this thread) with the first hit at once, then at most every `every` seconds,
    /// and once when done. Nothing is reported after `cancel`.
    static func run(query: String, root: String, sort: String = "name", readmeFirst: Bool = false, showHidden: Bool, only: Set<String>? = nil,
                    limits: Limits = Limits(), every: TimeInterval = 0.05, cancel: Cancel, report: (Progress) -> Void) {
        if cancel.isCancelled { return }
        guard let matcher = Matcher(query), let realRoot = FolderListing.realPath(root) else { return report(Progress(done: true)) }
        let inside = realRoot == "/" ? "/" : realRoot + "/"
        let key = [root, sort, "\(readmeFirst)", "\(showHidden)", only.map { $0.sorted().joined(separator: "\n") } ?? "", "\(limits.maxFiles)", "\(limits.maxDepth)"]
            .joined(separator: "\0")
        var found: (paths: [String], listedOnly: Bool, stopped: String?)
        if let c = cached, c.key == key, Date().timeIntervalSince(c.at) < listTTL {
            found = c.files
        } else {
            found = files(root: root, sort: sort, readmeFirst: readmeFirst, showHidden: showHidden, only: only, limits: limits,
                          until: Date().addingTimeInterval(limits.walkBudget), cancel: cancel)
            if found.stopped == "cancelled" { return }
            cached = (key, Date(), found)
        }
        let start = Date(), deadline = start.addingTimeInterval(limits.budget)
        var p = Progress(total: found.paths.count, listedOnly: found.listedOnly, stopped: found.stopped)
        var bytes = 0, results = 0, sent = start, firstOut = false
        for path in found.paths {
            if cancel.isCancelled { return }
            let now = Date()
            if now > deadline { p.stopped = "time"; break }
            if bytes >= limits.maxTotalBytes { p.stopped = "bytes"; break }
            if results >= limits.maxResults { p.stopped = "results"; break }
            // The first hit goes at once; after it, what was found (or only how far the search got) goes every `every`.
            if (!firstOut && !p.hits.isEmpty) || now.timeIntervalSince(sent) >= every {
                firstOut = firstOut || !p.hits.isEmpty
                report(p)
                p.hits = []
                sent = now
            }
            p.searched += 1
            let (text, n) = read(path, cap: min(limits.maxFileBytes, limits.maxTotalBytes - bytes), inside: inside)
            bytes += n
            guard let text, let hit = matcher.hit(text, path: path) else { continue }
            results += 1
            p.hits.append(hit)
        }
        if cancel.isCancelled { return }
        p.done = true
        report(p)
    }
}
