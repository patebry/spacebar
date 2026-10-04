import Foundation

/// Settings' About row: what the update cache last saw, and Check Now, which asks GitHub as the writer's daily check does and
/// updates the same cache.
final class UpdateCheck: ObservableObject {
    enum Status: Equatable {
        case unknown, checking, upToDate, available(String), failed, off, devBuild

        var text: String? {
            switch self {
            case .unknown: return nil
            case .checking: return "Checking…"
            case .upToDate: return "Up to date"
            case .available(let v): return "Version \(v) is available"
            case .failed: return "Couldn’t check"
            case .off: return "Update checks are off"
            case .devBuild: return "Development build: not checked"
            }
        }
    }

    @Published private(set) var status = Status.unknown

    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    static var allowed: Bool {
        Updates.checks(build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                       testFlag: FileManager.default.fileExists(atPath: Updates.testFlagURL.path))
    }

    static func status(enabled: Bool, allowed: Bool, current: String, latest: String?) -> Status {
        guard allowed else { return .devBuild }
        guard enabled else { return .off }
        guard let latest else { return .unknown }
        return Updates.isNewer(latest, than: current) ? .available(latest) : .upToDate
    }

    func load(enabled: Bool) {
        guard status != .checking else { return }
        status = Self.status(enabled: enabled, allowed: Self.allowed, current: Self.version, latest: Updates.readCache()?.latest)
    }

    func checkNow(enabled: Bool) {
        guard enabled, Self.allowed, status != .checking else { return load(enabled: enabled) }
        status = .checking
        let current = Self.version
        var req = URLRequest(url: Updates.latestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("spacebar", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let found = (resp as? HTTPURLResponse)?.statusCode == 200 ? data.flatMap(Updates.parseLatest) : nil
            var c = Updates.readCache() ?? Updates.Cache(checked: 0, latest: nil)
            c.checked = Date().timeIntervalSince1970
            c.latest = found ?? c.latest
            Updates.writeCache(c)
            DispatchQueue.main.async {
                self.status = found.map { Updates.isNewer($0, than: current) ? .available($0) : .upToDate } ?? .failed
            }
        }.resume()
    }
}
