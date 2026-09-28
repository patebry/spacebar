import Foundation

/// The update check: the newest release on GitHub, asked at most once a day by the writer and cached in the support folder.
/// Only the release's version number is read; nothing about the user or their files is sent.
enum Updates {
    static let latestURL = URL(string: "https://api.github.com/repos/patebry/spacebar/releases/latest")!
    static let installCommand = "curl -fsSL https://spacebar.patebryant.com/install.sh | sh"
    static let interval: TimeInterval = 24 * 60 * 60

    static var cacheURL: URL { SettingsFile.supportDir.appendingPathComponent("update.json") }
    /// How the last installer run ended, written by the writer when it reaps it and by install.sh itself as it exits.
    static var statusURL: URL { SettingsFile.supportDir.appendingPathComponent("update-status.json") }
    /// While this file exists a development build (CFBundleVersion 1) checks for updates like a release.
    static var testFlagURL: URL { SettingsFile.supportDir.appendingPathComponent("update-test") }
    static let logHint = "See ~/Library/Logs/spacebar-update.log."
    static let logLimit = 1 << 20
    static let logKeep = 256 << 10

    /// Whether this build checks for updates: a development build only while the test flag file exists.
    static func checks(build: String, testFlag: Bool) -> Bool { build != "1" || testFlag }

    /// "1.2.3" from a tag like "v1.2.3", or nil when it is not up to four dot-separated numbers.
    static func version(fromTag tag: String) -> String? {
        let v = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return v.utf8.count <= 32 && v.range(of: #"^[0-9]+(\.[0-9]+){0,3}$"#, options: .regularExpression) != nil ? v : nil
    }

    /// Whether `a` is a later version than `b`, comparing numerically part by part (a missing part counts as 0).
    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parts(a), let y = parts(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int]? {
        guard version(fromTag: v) != nil else { return nil }
        return v.split(separator: ".").map { Int($0) ?? 0 }
    }

    struct Started: Codable, Equatable {
        var version: String
        var at: Double
    }

    struct Cache: Codable, Equatable {
        var checked: Double
        var latest: String?
        /// The update this Mac last started, so a preview opened while it runs does not offer it again.
        var started: Started? = nil
    }

    struct Finished: Codable, Equatable {
        var version: String
        var exitStatus: Int
        var finishedAt: Double
    }

    static func readCache(at url: URL = cacheURL) -> Cache? {
        guard var c: Cache = load(url) else { return nil }
        if let l = c.latest, version(fromTag: l) != l { c.latest = nil }
        if let st = c.started, version(fromTag: st.version) != st.version { c.started = nil }
        return c
    }

    static func writeCache(_ c: Cache, at url: URL = cacheURL) { save(c, to: url) }

    static func readStatus(at url: URL = statusURL) -> Finished? {
        guard let f: Finished = load(url), version(fromTag: f.version) == f.version else { return nil }
        return f
    }

    static func writeStatus(_ f: Finished, at url: URL = statusURL) { save(f, to: url) }

    private static func load<T: Decodable>(_ url: URL) -> T? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private static func save<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// What the preview offers for the latest release.
    enum Offer: Equatable {
        case none
        /// Installable here with one click.
        case available(String)
        /// Newer, but this copy is not the one the installer replaces (`place`), so it is not offered to install.
        case elsewhere(String, place: String)
        /// Started from this Mac and not finished yet.
        case inProgress(String)
        case failed(String, reason: String)

        var json: Data {
            let d: [String: String]
            switch self {
            case .none: d = ["state": "none"]
            case .available(let v): d = ["state": "available", "version": v]
            case .elsewhere(let v, let place): d = ["state": "elsewhere", "version": v, "place": place]
            case .inProgress(let v): d = ["state": "inProgress", "version": v]
            case .failed(let v, let reason): d = ["state": "failed", "version": v, "reason": reason]
            }
            return try! JSONSerialization.data(withJSONObject: d)
        }

        /// Read back from the writer; nil for anything malformed or naming no plain version.
        init?(json: Data) {
            guard json.count <= 4096, let d = (try? JSONSerialization.jsonObject(with: json)) as? [String: String], let state = d["state"] else { return nil }
            if state == "none" { self = .none; return }
            guard let v = d["version"], Updates.version(fromTag: v) == v else { return nil }
            switch state {
            case "available": self = .available(v)
            case "elsewhere": self = .elsewhere(v, place: String((d["place"] ?? "").prefix(512)))
            case "inProgress": self = .inProgress(v)
            case "failed": self = .failed(v, reason: String((d["reason"] ?? "").prefix(512)))
            default: return nil
            }
        }
    }

    /// `running`: an installer holds the log's lock (isRunning).
    static func offer(current: String, latest: String?, started: Started?, finished: Finished?, place: String?, running: Bool) -> Offer {
        guard let latest, isNewer(latest, than: current) else { return .none }
        if let place { return .elsewhere(latest, place: place) }
        guard let s = started, s.version == latest else { return .available(latest) }
        if let f = finished, f.version == latest, f.finishedAt >= s.at {
            // Installed, but this is still the old copy running: it goes when Quick Look next restarts it.
            if f.exitStatus == 0 { return .none }
            return .failed(latest, reason: "The installer stopped with status \(f.exitStatus). \(logHint)")
        }
        return running ? .inProgress(latest) : .failed(latest, reason: "The installer did not finish. \(logHint)")
    }

    /// The popover's text for a reason an update failed or did not start, and whether it offers the install command: only when
    /// running it in Terminal does what the button meant to (not beside a running update, not for a copy it would not replace).
    static func advice(for reason: String) -> (text: String, copy: Bool) {
        let retryable = ["cannot create the log folder", "cannot open the log", "cannot copy the installer", "could not start the installer",
                         "the helper stopped", "the installer"]
        let copy = retryable.contains { reason.lowercased().hasPrefix($0) }
        var text = reason.prefix(1).uppercased() + reason.dropFirst()
        if !text.hasSuffix(".") { text += "." }
        return (text, copy)
    }

    /// Why the writer must not start an update to `requested` from `current`, or nil when it may: the check must be on, and the
    /// version a plain number (no "v") later than this one.
    static func installRefusal(_ requested: String, current: String, enabled: Bool) -> String? {
        guard enabled else { return "update checks are off" }
        guard version(fromTag: requested) == requested else { return "not a version" }
        guard isNewer(requested, than: current) else { return "not newer than \(current)" }
        return nil
    }

    static func installerArguments(_ version: String) -> [String] { ["--version", "v\(version)", "--no-prompt"] }

    struct SpawnError: Error, Equatable { let message: String }

    /// What runDetached runs, for its messages.
    enum Job {
        case update, uninstall
        var busy: String { self == .update ? "an update is already running" : "an uninstall is already running" }
        var script: String { self == .update ? "installer" : "uninstaller" }
    }

    /// Starts `/bin/sh` on a private copy of `script`, so replacing the app that holds the script does not cut it off mid-read.
    /// The shell runs in a session of its own and outlives the writer and Quick Look, which the installer quits. Its stdin is
    /// /dev/null, stdout and stderr are appended to `log`, and it inherits no other descriptor and only `environment`. The log
    /// is opened under an exclusive lock that the script's processes hold until they exit, so a second update cannot start
    /// while one runs, from this writer or the other extension's.
    /// `onExit` gets the exit status (128 + the signal for a killed shell) when it is reaped. A log past `logLimit` is cut to its
    /// last `logKeep` bytes first. The copy is made in `temporary`, and removed once the shell is reaped.
    static func runDetached(script: URL, arguments: [String], log: URL, environment: [String: String],
                            temporary: URL = FileManager.default.temporaryDirectory, job: Job = .update,
                            onExit: @escaping (Int) -> Void = { _ in }) -> Result<pid_t, SpawnError> {
        let fm = FileManager.default
        let fail = { (what: String) in Result<pid_t, SpawnError>.failure(SpawnError(message: what)) }
        guard (try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return fail("cannot create the log folder") }
        let fd = open(log.path, O_RDWR | O_CREAT | O_APPEND | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o644)
        guard fd >= 0 else { return fail(errno == EWOULDBLOCK ? job.busy : "cannot open the log") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        trimLog(fd)
        let dir = temporary.appendingPathComponent("spacebar-update-\(UUID().uuidString)", isDirectory: true)
        // Named as the script is: each script finds and removes its own copy by its folder.
        let copy = dir.appendingPathComponent(script.lastPathComponent)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil, (try? fm.copyItem(at: script, to: copy)) != nil else {
            try? fm.removeItem(at: dir)
            return fail("cannot copy the \(job.script)")
        }
        let head = "\n=== \(ISO8601DateFormatter().string(from: Date())) \(arguments.joined(separator: " ")) ===\n"
        _ = head.withCString { write(fd, $0, strlen($0)) }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fd, 1)
        posix_spawn_file_actions_adddup2(&actions, fd, 2)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var none = sigset_t(), all = sigset_t()
        sigemptyset(&none)
        sigfillset(&all)
        posix_spawnattr_setsigmask(&attr, &none)
        posix_spawnattr_setsigdefault(&attr, &all)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))

        let argv = (["/bin/sh", copy.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let err = posix_spawn(&pid, "/bin/sh", &actions, &attr, argv, envp)
        guard err == 0 else {
            try? fm.removeItem(at: dir)
            return fail("could not start the \(job.script): \(String(cString: strerror(err)))")
        }
        // Reaped here while the writer lives; the copy goes with it.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
            try? FileManager.default.removeItem(at: dir)
            onExit(Int(status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)))
        }
        return .success(pid)
    }

    /// Whether an installer started by runDetached is still running: its processes hold the log's lock until they exit.
    static func isRunning(log: URL) -> Bool {
        let fd = open(log.path, O_RDONLY | O_CLOEXEC | O_EXLOCK | O_NONBLOCK)
        if fd >= 0 { close(fd); return false }
        return errno == EWOULDBLOCK
    }

    /// Keeps the last `logKeep` bytes of a log past `logLimit`, from the first whole line.
    private static func trimLog(_ fd: Int32) {
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_size > logLimit else { return }
        var tail = [UInt8](repeating: 0, count: logKeep)
        let n = pread(fd, &tail, logKeep, st.st_size - off_t(logKeep))
        guard n > 0, ftruncate(fd, 0) == 0 else { return }
        let from = tail[..<n].firstIndex(of: 10).map { $0 + 1 } ?? 0
        _ = tail[from..<n].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
    }

    /// The version in a GitHub "latest release" response, or nil when it is not one. Release tags always start with "v".
    static func parseLatest(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = obj["tag_name"] as? String,
              tag.hasPrefix("v") else { return nil }
        return version(fromTag: tag)
    }
}
