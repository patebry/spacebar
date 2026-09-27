import Foundation

/// The contents of an archive, for the preview's archive view. The sandboxed extension cannot start a process, so the writer
/// runs /usr/bin/bsdtar (`list`) and sends the page JSON: {entries: [{name, size, modified, isDir}], truncated}, `size` in
/// bytes or null, `modified` in ms since 1970 or null. Nothing is extracted.
///
/// The archive is untrusted (a download) and the writer is not sandboxed, so bsdtar runs under sandbox-exec with a profile that
/// denies every file read outside the system, every write and the network, and reads the archive only from the descriptor
/// the writer opened: a bug in libarchive's parsers reaches nothing of the user's.
enum ArchiveListing {
    struct Entry: Equatable {
        let name: String
        let size: Int64?
        let modified: Double?
        let isDir: Bool
    }

    static let tool = "/usr/bin/bsdtar"
    static let sandboxExec = "/usr/bin/sandbox-exec"
    static let profile = """
        (version 1)
        (deny default)
        (import "bsd.sb")
        (allow process-exec (literal "/usr/bin/bsdtar"))
        (allow file-read* (literal "/usr/bin/bsdtar"))
        """
    static let maxEntries = 5_000
    static let maxOutputBytes = 2 << 20
    static let timeout: TimeInterval = 5
    /// What the writer lists: FileTypes.archiveExtensions (checked equal by test/settings).
    static let extensions: Set<String> = ["zip", "tar", "gz", "gzip", "tgz", "bz2", "bz", "tbz", "tbz2", "xz", "txz", "7z", "rar", "zst", "tzst"]
    /// A single compressed file: what bsdtar cannot list unless it holds a tar.
    static let compressedExtensions: Set<String> = ["gz", "gzip", "bz2", "bz", "xz", "zst"]

    struct Run { var output: String; var status: Int32; var truncated: Bool }

    /// The listing of the archive at `path` as JSON, or nil when it cannot be listed: not an archive by name, not a regular
    /// file, evicted by iCloud, unreadable, or in a format bsdtar does not read. Blocks for up to `timeout` and a second;
    /// call it off the main thread.
    static func list(_ path: String) -> Data? {
        guard extensions.contains((path as NSString).pathExtension.lowercased()) else { return nil }
        // O_NONBLOCK: a file swapped for a FIFO cannot hang the open; fstat checks what was actually opened.
        let fd = open(path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var st = stat()
        // Evicted by iCloud (SF_DATALESS): listing it would download all of it.
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_flags & 0x4000_0000 == 0 else { return nil }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        guard let run = runTool(handle) else { return nil }
        var entries = parse(run.output, now: Date())
        var truncated = run.truncated
        if run.status != 0 && !run.truncated {
            // bsdtar reads a lone compressed file as a one-line mtree spec and fails: it is the one file inside.
            if isLoneCompressed(path) {
                entries = [loneEntry(path, st, handle)]
            } else if entries.isEmpty {
                return nil
            } else {
                truncated = true
            }
        }
        return json(entries, truncated: truncated)
    }

    static func isLoneCompressed(_ path: String) -> Bool {
        let lower = (path as NSString).lastPathComponent.lowercased()
        let ext = (lower as NSString).pathExtension
        return compressedExtensions.contains(ext) && (lower as NSString).deletingPathExtension.lowercased().hasSuffix(".tar") == false
    }

    /// The one file a lone compressed file holds: its name without the extension, and for gzip the size its trailer records.
    static func loneEntry(_ path: String, _ st: stat, _ h: FileHandle) -> Entry {
        let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        var size: Int64?
        if ["gz", "gzip"].contains((path as NSString).pathExtension.lowercased()), st.st_size >= 18,
           (try? h.seek(toOffset: UInt64(st.st_size - 4))) != nil, let t = try? h.read(upToCount: 4), t.count == 4 {
            // ISIZE: the size modulo 2^32, little-endian.
            size = t.reversed().reduce(Int64(0)) { $0 << 8 | Int64($1) }
        }
        return Entry(name: name, size: size, modified: Double(st.st_mtimespec.tv_sec) * 1000, isDir: false)
    }

    /// Runs `bsdtar -tvf -` on `input` under the sandbox: argv only, no shell, stderr dropped, output cut at `maxOutputBytes`
    /// or past `maxEntries` lines, SIGTERM after `timeout` and SIGKILL a second later. PATH is the system's alone, so a filter
    /// bsdtar would start as a program (zstd) is never one installed elsewhere. Nil when it could not start, or had not ended
    /// a second after the kill (a read stuck on a network volume): the caller answers in bounded time either way.
    static func runTool(_ input: FileHandle) -> Run? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: sandboxExec)
        p.arguments = ["-p", profile, tool, "-tvf", "-"]
        // A UTF-8 locale prints names as UTF-8; without one every non-ASCII byte comes as an octal escape.
        p.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "en_US.UTF-8", "TZ": TimeZone.current.identifier]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = input
        do { try p.run() } catch { return nil }
        let pid = p.processIdentifier
        let term = DispatchWorkItem { if p.isRunning { p.terminate() } }
        let kill9 = DispatchWorkItem { if p.isRunning { kill(pid, SIGKILL) } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: term)
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout + 1, execute: kill9)
        defer { term.cancel(); kill9.cancel() }
        let lock = NSLock()
        var data = Data()
        var truncated = false
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let reader = out.fileHandleForReading
            var lines = 0
            while true {
                let chunk = reader.availableData
                if chunk.isEmpty { break }
                lock.lock()
                data.append(chunk)
                let size = data.count
                lock.unlock()
                lines += chunk.reduce(0) { $0 + ($1 == 10 ? 1 : 0) }
                if size >= maxOutputBytes || lines > maxEntries {
                    lock.lock(); truncated = true; lock.unlock()
                    if p.isRunning { p.terminate() }
                    break
                }
            }
            p.waitUntilExit()
            finished.signal()
        }
        guard finished.wait(timeout: .now() + timeout + 2) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        let timedOut = p.terminationReason == .uncaughtSignal && !truncated
        // A line cut by the limit is dropped by `parse`, which only takes complete lines.
        return Run(output: String(decoding: data.prefix(maxOutputBytes), as: UTF8.self),
                   status: p.terminationReason == .uncaughtSignal ? -1 : p.terminationStatus, truncated: truncated || timedOut)
    }

    /// Parses `bsdtar -tv` lines: `mode links owner group size month day time-or-year name`. A date with a time is within half
    /// a year of `now` (bsdtar's rule), and its year is the one that puts it there. Symbolic and hard link targets are dropped.
    /// Only complete lines (ending in a newline) count, at most `maxEntries`.
    static func parse(_ text: String, now: Date, timeZone: TimeZone = .current) -> [Entry] {
        var entries: [Entry] = []
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        lines.removeLast()
        for line in lines {
            guard entries.count < maxEntries, let e = parseLine(line, now: now, timeZone: timeZone) else { continue }
            entries.append(e)
        }
        return entries
    }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    static func parseLine(_ line: Substring, now: Date, timeZone: TimeZone) -> Entry? {
        // `mode links owner group size month day time-or-year`, one space, then the name, which may hold spaces. An owner or
        // group name from the archive may hold spaces too, so the date is found first: the first month, day and time or year
        // after the fourth field, with the size just before it.
        var fields: [(Substring, String.Index)] = []
        var i = line.startIndex
        while i < line.endIndex, fields.count < 64 {
            while i < line.endIndex, line[i] == " " { i = line.index(after: i) }
            guard i < line.endIndex else { break }
            let start = i
            while i < line.endIndex, line[i] != " " { i = line.index(after: i) }
            fields.append((line[start..<i], i))
        }
        guard fields.count >= 9, let type = fields[0].0.first, fields[0].0.count >= 10 else { return nil }
        let isTime = { (s: Substring) in s.contains(":") || (s.count == 4 && Int(s) != nil) }
        guard let k = (5..<(fields.count - 3)).first(where: {
            months.contains(String(fields[$0].0)) && Int(fields[$0 + 1].0) != nil && isTime(fields[$0 + 2].0) && Int64(fields[$0 - 1].0) != nil
        }) else { return nil }
        let end = fields[k + 2].1
        guard end < line.endIndex else { return nil }
        var name = String(line[line.index(after: end)...])
        if type == "l", let r = name.range(of: " -> ", options: .backwards) { name = String(name[..<r.lowerBound]) }
        if type == "h", let r = name.range(of: " link to ", options: .backwards) { name = String(name[..<r.lowerBound]) }
        name = unescape(name)
        guard !name.isEmpty, let month = months.firstIndex(of: String(fields[k].0)), let day = Int(fields[k + 1].0) else { return nil }
        let isDir = type == "d" || name.hasSuffix("/")
        return Entry(name: name, size: isDir ? nil : Int64(fields[k - 1].0),
                     modified: date(month: month + 1, day: day, timeOrYear: fields[k + 2].0, now: now, timeZone: timeZone), isDir: isDir)
    }

    static func date(month: Int, day: Int, timeOrYear: Substring, now: Date, timeZone: TimeZone) -> Double? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        var c = DateComponents(month: month, day: day)
        if let colon = timeOrYear.firstIndex(of: ":") {
            guard let h = Int(timeOrYear[..<colon]), let m = Int(timeOrYear[timeOrYear.index(after: colon)...]) else { return nil }
            c.hour = h
            c.minute = m
            let year = cal.component(.year, from: now)
            let half: TimeInterval = 365 * 86_400 / 2
            for y in [year, year - 1, year + 1] {
                c.year = y
                if let d = cal.date(from: c), abs(d.timeIntervalSince(now)) <= half { return d.timeIntervalSince1970 * 1000 }
            }
            return nil
        }
        guard let y = Int(timeOrYear) else { return nil }
        c.year = y
        return cal.date(from: c).map { $0.timeIntervalSince1970 * 1000 }
    }

    /// Undoes bsdtar's escapes: `\\`, the C letter escapes, and `\ooo` for any other byte (then read as UTF-8).
    static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var bytes: [UInt8] = []
        let u = Array(s.utf8)
        var i = 0
        let letters: [UInt8: UInt8] = [UInt8(ascii: "a"): 7, UInt8(ascii: "b"): 8, UInt8(ascii: "f"): 12, UInt8(ascii: "n"): 10,
                                       UInt8(ascii: "r"): 13, UInt8(ascii: "t"): 9, UInt8(ascii: "v"): 11, UInt8(ascii: "\\"): 92]
        let isOctal = { (b: UInt8) in b >= UInt8(ascii: "0") && b <= UInt8(ascii: "7") }
        while i < u.count {
            if u[i] == UInt8(ascii: "\\"), i + 1 < u.count {
                if let l = letters[u[i + 1]] { bytes.append(l); i += 2; continue }
                if i + 3 < u.count, isOctal(u[i + 1]), isOctal(u[i + 2]), isOctal(u[i + 3]) {
                    let v = Int(u[i + 1] - 48) * 64 + Int(u[i + 2] - 48) * 8 + Int(u[i + 3] - 48)
                    if v <= 255 { bytes.append(UInt8(v)); i += 4; continue }
                }
            }
            bytes.append(u[i])
            i += 1
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func json(_ entries: [Entry], truncated: Bool = false) -> Data {
        let list: [[String: Any]] = entries.map {
            ["name": $0.name, "size": $0.size.map { NSNumber(value: $0) } ?? NSNull(), "modified": $0.modified.map { NSNumber(value: $0) } ?? NSNull(), "isDir": $0.isDir]
        }
        return (try? JSONSerialization.data(withJSONObject: ["entries": list, "truncated": truncated] as [String: Any])) ?? Data("{\"entries\":[]}".utf8)
    }
}
