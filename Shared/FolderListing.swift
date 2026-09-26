import Foundation

/// The Markdown files of one folder, as the preview's sidebar lists them, for a single file and a folder alike.
///
/// Hidden files (a leading dot or the hidden flag) are skipped. A symbolic link is listed only when it resolves to a regular
/// file inside the folder, so the list never reaches outside it. Files over the preview's size limit are left out, as are
/// FIFOs and devices. The order is `sort` ("name" or "modified", newest first), with a README moved to the top when
/// `readmeFirst`; at most `cap` files are listed and `more` counts the rest.
enum FolderListing {
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mkdn"]
    static let cap = 500
    static let maxDocumentBytes = 64 << 20

    struct Entry: Equatable {
        let name: String
        /// `dir/name`, the path the page shows and asks to open.
        let path: String
        /// The file it resolves to (itself unless it is a link), for matching the document on screen.
        let resolved: String
    }

    struct Listing: Equatable {
        let dir: String
        let files: [Entry]
        let more: Int

        /// What the page is sent; `active` is the entry of the document on screen, if listed.
        func payload(active: String?) -> [String: Any] {
            ["dir": dir, "dirName": (dir as NSString).lastPathComponent, "files": files.map { ["name": $0.name, "path": $0.path] },
             "more": more, "active": active ?? NSNull()]
        }

        func entry(resolving path: String?) -> Entry? {
            guard let path, let real = FolderListing.realPath(path) else { return nil }
            return files.first { $0.resolved == real }
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    static func isReadme(_ name: String) -> Bool { (name as NSString).deletingPathExtension.lowercased() == "readme" }

    /// Reads the folder; call it off the main thread. `pinned` (the document on screen) is listed even past the cap.
    static func list(_ dir: String, sort: String, readmeFirst: Bool, cap: Int = cap, pinned: String? = nil) -> Listing {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        let inside = (realPath(dir) ?? dir) + "/"
        var found: [(entry: Entry, modified: Double)] = []
        for name in names where !name.hasPrefix(".") && markdownExtensions.contains((name as NSString).pathExtension.lowercased()) {
            let path = (dir as NSString).appendingPathComponent(name)
            var st = stat()
            guard lstat(path, &st) == 0, st.st_flags & UInt32(UF_HIDDEN) == 0 else { continue }
            var resolved = inside + name
            if st.st_mode & S_IFMT == S_IFLNK {
                guard let real = realPath(path), real.hasPrefix(inside), stat(real, &st) == 0 else { continue }
                resolved = real
            }
            guard st.st_mode & S_IFMT == S_IFREG, st.st_size <= maxDocumentBytes else { continue }
            let modified = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            found.append((Entry(name: name, path: path, resolved: resolved), modified))
        }
        found.sort { a, b in
            if sort == "modified", a.modified != b.modified { return a.modified > b.modified }
            return a.entry.name.localizedStandardCompare(b.entry.name) == .orderedAscending
        }
        var files = found.map(\.entry)
        if readmeFirst, let i = files.firstIndex(where: { isReadme($0.name) }) { files.insert(files.remove(at: i), at: 0) }
        var shown = Array(files.prefix(max(cap, 0)))
        if let real = pinned.flatMap(realPath), !shown.contains(where: { $0.resolved == real }),
           let pin = files.first(where: { $0.resolved == real }) {
            shown.append(pin)
        }
        return Listing(dir: dir, files: shown, more: files.count - shown.count)
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
