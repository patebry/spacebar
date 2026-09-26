import Foundation
import SwiftUI

/// The settings window's view of settings.json. Every change is written through `SettingsFile.update` at once; the file is the
/// source of truth, and edits made to it (or to custom.css or a theme) elsewhere are picked up by watching the support folder.
final class SettingsStore: ObservableObject {
    @Published private(set) var settings = Settings()
    /// Why the last read or write failed, shown above the controls. A file that cannot be parsed is never overwritten.
    @Published private(set) var problem: String?
    @Published private(set) var userThemes: [UserTheme] = []
    /// Bumped whenever something the page reads may have changed, so the preview re-applies the payload.
    @Published private(set) var revision = 0

    private var watcher: FolderWatcher?

    func start() {
        if let f = SettingsFile.ensure() { problem = Self.message(f) }
        reload()
        watcher = FolderWatcher(paths: { [weak self] in self?.watchedPaths() ?? [] }) { [weak self] in self?.reload() }
    }

    func reload() {
        switch SettingsFile.raw() {
        case .success(let raw):
            settings = Settings(dictionary: raw)
            problem = nil
        case .failure(let f):
            settings = SettingsFile.load()
            problem = Self.message(f)
        }
        userThemes = UserTheme.list()
        revision += 1
    }

    func set(_ key: String, _ value: Any) {
        apply(SettingsFile.update([key: value]))
    }

    func resetToDefaults() {
        apply(SettingsFile.update(Settings().dictionary))
    }

    private func apply(_ result: Result<Settings, SettingsFile.Failure>) {
        switch result {
        case .success(let s):
            settings = s
            problem = nil
            revision += 1
        case .failure(let f):
            problem = Self.message(f)
            // Put every control back to what is really in effect.
            objectWillChange.send()
        }
    }

    func binding<T>(_ path: KeyPath<Settings, T>, _ key: String) -> Binding<T> {
        Binding(get: { self.settings[keyPath: path] }, set: { self.set(key, $0) })
    }

    func binding(_ path: KeyPath<Settings, String?>, _ key: String) -> Binding<String?> {
        Binding(get: { self.settings[keyPath: path] }, set: { self.set(key, $0 ?? NSNull()) })
    }

    private func watchedPaths() -> [URL] {
        var paths = [SettingsFile.supportDir, SettingsFile.themesDir, SettingsFile.url, SettingsFile.customCSS]
        if let t = settings.userTheme { paths.append(SettingsFile.themesDir.appendingPathComponent(t)) }
        return paths
    }

    static func message(_ f: SettingsFile.Failure) -> String {
        switch f {
        case .notAnObject: return "settings.json isn't valid JSON — fix or delete it. Changes can't be saved until then."
        case .tooLarge: return "settings.json is larger than 64 KB — fix or delete it. Changes can't be saved until then."
        case .unreadable(let why): return "settings.json can't be read (\(why)). Changes can't be saved until then."
        case .writeFailed(let why): return "Couldn't save settings: \(why)"
        }
    }
}

/// Watches a set of paths with DispatchSource and calls back once per burst of changes. Every source is re-opened after a
/// change, so a file replaced by an atomic save (a rename over it) or a folder created later is followed.
final class FolderWatcher {
    private let paths: () -> [URL]
    private let onChange: () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?

    init(paths: @escaping () -> [URL], onChange: @escaping () -> Void) {
        self.paths = paths
        self.onChange = onChange
        arm()
    }

    deinit { sources.forEach { $0.cancel() } }

    private func arm() {
        sources.forEach { $0.cancel() }
        sources = paths().compactMap { url in
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { return nil }
            let src = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib, .link], queue: .main)
            src.setEventHandler { [weak self] in self?.changed() }
            src.setCancelHandler { close(fd) }
            src.resume()
            return src
        }
    }

    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.onChange()
            self.arm()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50), execute: work)
    }
}
