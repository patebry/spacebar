import Foundation

/// Report a Problem: a new GitHub issue with this Mac's details filled in, opened in the browser. Nothing is sent by spacebar;
/// the user sees the whole text on GitHub and submits it or not.
enum ProblemReport {
    static let newIssue = "https://github.com/patebry/spacebar/issues/new"
    static let logLines = 40
    /// Per line of the log, so one runaway line cannot crowd out the rest or push the URL past what browsers and GitHub take.
    static let lineLimit = 200
    /// A new-issue URL that grows too long is refused (by GitHub or on the way); the log's oldest lines go first to stay under it.
    static let maxURL = 8000

    struct System: Equatable {
        var version: String
        var macOS: String
        var model: String
        var arch: String
    }

    static var updateLog: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Library/Logs/spacebar-update.log")
    }

    static func current() -> System {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let b = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = sysctl("sysctl.proc_translated") == "1" ? "x86_64 (Rosetta)" : "x86_64"
        #endif
        return System(version: b.map { "\(v) (\($0))" } ?? v, macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                      model: sysctl("hw.model") ?? "unknown", arch: arch)
    }

    /// The last `lines` lines of `text`, each cut to `lineLimit` characters, with the home folder shown as ~.
    static func tail(_ text: String, lines: Int = logLines, home: String = NSHomeDirectory()) -> String {
        var all = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.last == "" { all.removeLast() }
        let redact = redactor(home: home)
        return all.suffix(lines).map { line in
            let l = redact(line)
            return l.count > lineLimit ? String(l.prefix(lineLimit)) + "…" : l
        }.joined(separator: "\n")
    }

    /// Replaces the home folder with ~ where it is a whole path, not the start of a longer name (/Users/ann in /Users/anne
    /// stays), both as written and as the installer's pkill patterns escape it (/Users/a\.b).
    static func redactor(home: String) -> (String) -> String {
        guard home.count > 1 else { return { $0 } }
        let escaped = home.replacingOccurrences(of: #"[\]\[\\.*$+?(){}|]"#, with: #"\\$0"#, options: .regularExpression)
        let forms = Set([home, escaped]).sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        guard let re = try? NSRegularExpression(pattern: #"(?<![A-Za-z0-9._/-])(?:"# + forms.joined(separator: "|") + #")(?![A-Za-z0-9._-])"#) else { return { $0 } }
        return { line in re.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "~") }
    }

    /// The end of the update log, read from at most its last 64 KB, or nil when there is none.
    static func readLog(at url: URL = updateLog) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > 65536 ? size - 65536 : 0)
        guard let data = try? h.readToEnd(), !data.isEmpty else { return nil }
        let t = tail(String(decoding: data, as: UTF8.self))
        return t.isEmpty ? nil : t
    }

    static func body(_ s: System, log: String?) -> String {
        var b = """
        **What happened**


        **What you expected**


        **Steps to reproduce**
        1.

        ---
        Filled in by spacebar. Remove anything you would rather not share.

        - spacebar: \(s.version)
        - macOS: \(s.macOS)
        - Mac: \(s.model), \(s.arch)
        """
        if let log {
            b += "\n\nLast lines of ~/Library/Logs/spacebar-update.log:\n\n```\n\(log.replacingOccurrences(of: "```", with: "'''"))\n```"
        }
        return b + "\n"
    }

    /// The prefilled new-issue URL, dropping the log's oldest lines until it fits in `maxURL` characters.
    static func url(_ s: System, log: String?) -> URL {
        var lines = log.map { $0.split(separator: "\n", omittingEmptySubsequences: false) } ?? []
        while true {
            let u = newIssue + "?title=" + encode("Problem: ") + "&body=" + encode(body(s, log: lines.isEmpty ? nil : lines.joined(separator: "\n")))
            if u.count <= maxURL || lines.isEmpty { return URL(string: u)! }
            lines.removeFirst()
        }
    }

    /// Percent-encodes everything but the unreserved characters of RFC 3986, so &, =, + and # in the text stay text.
    static func encode(_ s: String) -> String {
        var allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if name == "sysctl.proc_translated" {
            var v: Int32 = 0
            size = MemoryLayout<Int32>.size
            return sysctlbyname(name, &v, &size, nil, 0) == 0 ? String(v) : nil
        }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }
}
