import Foundation

/// The update check: the newest release on GitHub, asked at most once a day by the writer and cached in the support folder.
/// Only the release's version number is read; nothing about the user or their files is sent.
enum Updates {
    static let latestURL = URL(string: "https://api.github.com/repos/patebry/spacebar/releases/latest")!
    static let installCommand = "curl -fsSL https://spacebar.patebryant.com/install.sh | sh"
    static let interval: TimeInterval = 24 * 60 * 60

    static var cacheURL: URL { SettingsFile.supportDir.appendingPathComponent("update.json") }

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

    struct Cache: Codable, Equatable {
        var checked: Double
        var latest: String?
    }

    static func readCache(at url: URL = cacheURL) -> Cache? {
        guard let data = try? Data(contentsOf: url), data.count <= 4096, var c = try? JSONDecoder().decode(Cache.self, from: data) else { return nil }
        if let l = c.latest, version(fromTag: l) == nil { c.latest = nil }
        return c
    }

    static func writeCache(_ c: Cache, at url: URL = cacheURL) {
        guard let data = try? JSONEncoder().encode(c) else { return }
        try? data.write(to: url, options: .atomic)
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

    /// Starts `/bin/sh` on a private copy of `script`, so replacing the app that holds the script does not cut it off mid-read.
    /// The shell runs in a session of its own and outlives the writer and Quick Look, which the installer quits. Its stdin is
    /// /dev/null, stdout and stderr are appended to `log`, and it inherits no other descriptor and only `environment`. The log
    /// is opened under an exclusive lock that the script's processes hold until they exit, so a second update cannot start
    /// while one runs, from this writer or the other extension's.
    static func runDetached(script: URL, arguments: [String], log: URL, environment: [String: String]) -> Result<pid_t, SpawnError> {
        let fm = FileManager.default
        let fail = { (what: String) in Result<pid_t, SpawnError>.failure(SpawnError(message: what)) }
        guard (try? fm.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil else { return fail("cannot create the log folder") }
        let fd = open(log.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_EXLOCK | O_NONBLOCK, 0o644)
        guard fd >= 0 else { return fail(errno == EWOULDBLOCK ? "an update is already running" : "cannot open the log") }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        let dir = fm.temporaryDirectory.appendingPathComponent("spacebar-update-\(UUID().uuidString)", isDirectory: true)
        let copy = dir.appendingPathComponent("install.sh")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil, (try? fm.copyItem(at: script, to: copy)) != nil else {
            return fail("cannot copy the installer")
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
            return fail("could not start the installer: \(String(cString: strerror(err)))")
        }
        // Reaped here while the writer lives; the copy goes with it.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            try? FileManager.default.removeItem(at: dir)
        }
        return .success(pid)
    }

    /// The version in a GitHub "latest release" response, or nil when it is not one.
    static func parseLatest(_ data: Data) -> String? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any], let tag = obj["tag_name"] as? String else { return nil }
        return version(fromTag: tag)
    }
}
