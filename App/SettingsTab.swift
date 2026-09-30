import Foundation

/// What spacebar-md://settings/<name> and the preview's openSettings ask for. The settings window is one page; the names are its
/// old tabs, kept for the links, and the ones whose settings now live under Advanced open that section.
enum SettingsTab: String, CaseIterable {
    case general, appearance, folders, editing, advanced

    var opensAdvanced: Bool { self == .folders || self == .editing || self == .advanced }

    /// spacebar-md://settings/<tab>; a missing tab means General.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "spacebar-md", url.host?.lowercased() == "settings" else { return nil }
        let name = url.pathComponents.first { $0 != "/" }?.lowercased() ?? "general"
        self.init(rawValue: name)
    }
}
