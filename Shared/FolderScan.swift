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
        case .code, .html: return "code"
        case .json, .csv: return "data"
        case .text: return "text"
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
        let ns = text as NSString
        guard let re = try? NSRegularExpression(pattern: #"(!?)\[\[([^\[\]\n]{1,400})\]\]"#) else { return [] }
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
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
