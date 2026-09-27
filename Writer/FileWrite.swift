import Foundation

private let writeLock = NSLock()

/// Holds the writer's exit on SIGTERM while a write is in flight. Writes rewrite the file in place, so a kill in the middle
/// would leave it partly written (the installer quits the writer this way when it updates the app). After the signal no new
/// write starts; the process exits `grace` seconds after the last one ends (so its reply still reaches the preview), or after
/// `cap` seconds whatever is in flight. `quit` runs once.
final class WriteGate {
    private let lock = NSLock()
    private var inFlight = 0
    private var stopping = false
    private var quitting = false
    private let cap: TimeInterval
    private let grace: TimeInterval
    private let quit: () -> Void

    init(cap: TimeInterval = 5, grace: TimeInterval = 0.2, quit: @escaping () -> Void = { exit(0) }) {
        self.cap = cap
        self.grace = grace
        self.quit = quit
    }

    /// False once termination has begun: the write must not start.
    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopping else { return false }
        inFlight += 1
        return true
    }

    func end() {
        lock.lock()
        inFlight -= 1
        let now = stopping && inFlight == 0
        lock.unlock()
        if now { quitOnce(after: grace) }
    }

    func terminate() {
        lock.lock()
        let first = !stopping
        stopping = true
        let now = inFlight == 0
        lock.unlock()
        if now { return quitOnce(after: 0) }
        if first { DispatchQueue.global().asyncAfter(deadline: .now() + cap) { self.quitOnce(after: 0) } }
    }

    private func quitOnce(after delay: TimeInterval) {
        lock.lock()
        let first = !quitting
        quitting = true
        lock.unlock()
        guard first else { return }
        if delay == 0 { quit() } else { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: quit) }
    }

    /// Routes SIGTERM to `terminate`. Keep the returned source alive.
    func handleSIGTERM() -> DispatchSourceSignal {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
        source.setEventHandler { [weak self] in self?.terminate() }
        source.resume()
        return source
    }
}

/// Writes `data` only while the file still holds `base`.
///
/// The compare and the write go through one descriptor: the content is read from it, its size and modification time are
/// re-checked just before writing, and the new bytes are written and truncated through the same descriptor. That leaves
/// microseconds, not a reopen, between the check and the write. If the path was replaced meanwhile (a save by rename, which
/// is how most editors save), this write landed in the replaced file and "conflict" is returned; the other save stays.
///
/// The file is rewritten in place rather than through a temp file and rename: a rename would give the document a new inode
/// on every keystroke, which breaks hard links and changes the identity Finder and Quick Look track the previewed item by,
/// and in-place writes are the path already proven not to disturb a Finder Quick Look preview while it is being edited.
/// The cost: the file is briefly partly written while a write runs, so a reader in that moment, or a crash or kill before it
/// finishes, sees a mix. A write that fails (disk full, I/O error) puts `base` back through the same descriptor; if that also
/// fails the error says the file may be partly written, and the intended text is saved atomically, under a name unique to
/// this failure, beside it (`<name>.spacebar-unsaved-<time>`) or failing that (the disk is likely full) in the temporary
/// directory; the error names where, or says nothing was kept. Copies are left for the user to delete.
func compareAndWrite(_ data: Data, path: String, expecting base: Data) -> String? {
    writeLock.lock()
    defer { writeLock.unlock() }
    let fd = open(path, O_RDWR | O_CLOEXEC)
    guard fd >= 0 else { return String(cString: strerror(errno)) }
    defer { close(fd) }
    var before = stat()
    guard fstat(fd, &before) == 0 else { return String(cString: strerror(errno)) }
    guard let current = readAll(fd, size: Int(before.st_size)) else { return "read failed: \(String(cString: strerror(errno)))" }
    guard current == base else { return "conflict" }
    var checked = stat()
    guard fstat(fd, &checked) == 0, checked.st_size == before.st_size,
          checked.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, checked.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec
    else { return "conflict" }
    guard writeAll(fd, data), ftruncate(fd, off_t(data.count)) == 0, fsync(fd) == 0 else {
        let why = String(cString: strerror(errno))
        let restored = writeAll(fd, base) && ftruncate(fd, off_t(base.count)) == 0 && fsync(fd) == 0
        if restored { return "write failed (\(why)); file left as it was" }
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withYear, .withMonth, .withDay, .withTime])
        let name = (path as NSString).lastPathComponent + ".spacebar-unsaved-" + stamp + "-" + UUID().uuidString.prefix(4)
        let spots = [((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(name),
                     (NSTemporaryDirectory() as NSString).appendingPathComponent(name)]
        let kept = spots.first { (try? data.write(to: URL(fileURLWithPath: $0), options: [.atomic, .withoutOverwriting])) != nil }
        return "write failed (\(why)); file may be partly written" + (kept.map { "; text kept in \($0)" } ?? "")
    }
    var now = stat()
    guard stat(path, &now) == 0, now.st_dev == before.st_dev, now.st_ino == before.st_ino else { return "conflict" }
    return nil
}

private func readAll(_ fd: Int32, size: Int) -> Data? {
    var out = Data()
    var buf = [UInt8](repeating: 0, count: max(size, 4096) + 1)
    var off: off_t = 0
    while true {
        let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, $0.count, off) }
        if n < 0 { if errno == EINTR { continue }; return nil }
        if n == 0 { return out }
        out.append(contentsOf: buf[0..<n])
        off += off_t(n)
    }
}

private func writeAll(_ fd: Int32, _ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var off = 0
        while off < buf.count {
            let n = pwrite(fd, buf.baseAddress! + off, buf.count - off, off_t(off))
            if n > 0 { off += n } else if n < 0 && errno == EINTR { continue } else { if n == 0 { errno = EIO }; return false }
        }
        return true
    }
}
