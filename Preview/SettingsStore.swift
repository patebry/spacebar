import Foundation
import os

/// The settings as the extension sees them, kept current by watching the support folder (settings.json, custom.css and themes/)
/// and re-checked at every prepare, since a watch can miss changes made while the extension was suspended.
final class SettingsStore {
    static let shared = SettingsStore()
    private(set) var settings: Settings
    private var signature: [String]
    private var sources: [String: DispatchSourceFileSystemObject] = [:]
    private var pending = false
    private var observers: [(Settings) -> Void] = []
    private let slog = Logger(subsystem: logSubsystem, category: "settings")

    private init() {
        settings = SettingsFile.load()
        signature = []
        signature = currentSignature()
        rearm()
    }

    func observe(_ f: @escaping (Settings) -> Void) { observers.append(f) }

    var payload: [String: Any] { PageSettings.payload(settings) }

    /// Every file whose change can alter what the page shows: identity and modification time, or "-" when missing.
    private func watchedFiles(_ s: Settings) -> [URL] {
        var files = [SettingsFile.supportDir, SettingsFile.url, SettingsFile.customCSS, SettingsFile.themesDir]
        if let t = s.userTheme { files.append(SettingsFile.themesDir.appendingPathComponent(t)) }
        return files
    }

    private func currentSignature() -> [String] {
        watchedFiles(settings).map { f in
            var st = stat()
            guard stat(f.path, &st) == 0 else { return "-" }
            return "\(st.st_ino):\(st.st_size):\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
        }
    }

    /// Reloads when anything watched changed since the last look. Returns whether it did.
    @discardableResult
    func checkNow(reason: String) -> Bool {
        let sig = currentSignature()
        guard sig != signature else { return false }
        let next = SettingsFile.load()
        signature = []
        let old = settings
        settings = next
        signature = currentSignature()
        rearm()
        slog.info("settings reloaded (\(reason, privacy: .public)) theme=\(next.theme, privacy: .public)\(old == next ? " (css changed)" : "", privacy: .public)")
        observers.forEach { $0(next) }
        return true
    }

    private func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            guard let self else { return }
            self.pending = false
            self.checkNow(reason: "watch")
        }
    }

    /// One vnode source per watched path that exists: the folders catch files added, removed or replaced by an atomic save; the
    /// files catch in-place writes. Re-armed after every reload, so a replaced file is watched by its new identity. A folder that
    /// does not exist yet is picked up when the parent reports it, or at the next prepare.
    private func rearm() {
        let paths = Set(watchedFiles(settings).map(\.path))
        for (p, src) in sources { src.cancel(); sources[p] = nil }
        for p in paths {
            let fd = open(p, O_EVTONLY | O_NONBLOCK)
            guard fd >= 0 else { continue }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: .main)
            src.setEventHandler { [weak self] in self?.changed() }
            src.setCancelHandler { close(fd) }
            src.resume()
            sources[p] = src
        }
        if sources[SettingsFile.supportDir.path] == nil { slog.info("support folder not watchable yet; checked at each prepare") }
    }
}
