import AppKit
import UniformTypeIdentifiers

/// The kinds of file spacebar's viewer can be the default app for (double-click in Finder, links from other apps), and the
/// Launch Services calls that make it so or hand a kind back. Turning a kind off gives it back to the app it had before,
/// remembered in the app's own defaults, or to the first other app that opens it.
enum DefaultApps {
    static let viewerID = "md.spacebar.viewer"

    enum Group: String, CaseIterable, Identifiable {
        case markdown, images, data

        var id: String { rawValue }

        var title: String {
            switch self {
            case .markdown: return "Markdown"
            case .images: return "Images"
            case .data: return "Data files"
            }
        }

        var detail: String {
            switch self {
            case .markdown: return ".md and .markdown"
            case .images: return "PNG, JPEG, HEIC, GIF, WebP, TIFF, SVG"
            case .data: return "JSON, YAML, CSV, logs and property lists"
            }
        }

        var types: [String] {
            switch self {
            case .markdown: return ["net.daringfireball.markdown"]
            case .images: return ["public.png", "public.jpeg", "public.heic", "public.heif", "com.compuserve.gif", "org.webmproject.webp",
                                  "public.tiff", "com.microsoft.bmp", "public.svg-image"]
            case .data: return ["public.json", "public.yaml", "public.comma-separated-values-text", "public.tab-separated-values-text",
                                "public.log", "com.apple.property-list"]
            }
        }
    }

    /// Only a copy in ~/Applications or /Applications registers its viewer: one run from a build folder, a disk image or a
    /// translocated path would leave Launch Services opening files with a copy that goes stale or vanishes.
    static let available: Bool = {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return Updates.installPlaces(home: NSHomeDirectory()).contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == app }
    }()

    /// The viewer inside this app, when this is the app (Contents/Helpers).
    static var viewerURL: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true).appendingPathComponent(HelperIDs.viewerApp, isDirectory: true)
    }

    static func isSpacebar(_ app: URL?) -> Bool {
        guard let app, let id = Bundle(url: app)?.bundleIdentifier?.lowercased() else { return false }
        return id.hasPrefix("md.spacebar")
    }

    private static func spacebarCount(_ g: Group) -> Int {
        g.types.compactMap(UTType.init).filter { isSpacebar(NSWorkspace.shared.urlForApplication(toOpen: $0)) }.count
    }

    /// Every type in `g` opens in spacebar.
    static func isDefault(_ g: Group) -> Bool { spacebarCount(g) == g.types.count }

    /// Some, not all, of `g` opens in spacebar.
    static func isPartlyDefault(_ g: Group) -> Bool { (1..<g.types.count).contains(spacebarCount(g)) }

    private static let previousKey = "previousDefaultApps"

    /// Where a type goes back to: the app it had, else Preview for images and TextEdit for the rest, else any other app.
    private static func giveBack(_ type: UTType, group g: Group, previous: String?) -> URL? {
        let ws = NSWorkspace.shared
        if let previous, FileManager.default.fileExists(atPath: previous) { return URL(fileURLWithPath: previous) }
        let others = ws.urlsForApplications(toOpen: type).filter { !isSpacebar($0) }
        let preferred = g == .images ? "com.apple.Preview" : "com.apple.TextEdit"
        return others.first { Bundle(url: $0)?.bundleIdentifier == preferred } ?? others.first
    }

    /// Makes the viewer the default for every type in `g`, or gives them back. `done` gets whether every type changed, on main.
    static func set(_ g: Group, on: Bool, done: @escaping (Bool) -> Void) {
        guard available else { return done(false) }
        let viewer = viewerURL
        DispatchQueue.global(qos: .userInitiated).async {
            if on { LSRegisterURL(viewer as CFURL, true) }
            DispatchQueue.main.async { change(g, on: on, viewer: viewer, done: done) }
        }
    }

    private static func change(_ g: Group, on: Bool, viewer: URL, done: @escaping (Bool) -> Void) {
        let ws = NSWorkspace.shared
        var previous = UserDefaults.standard.dictionary(forKey: previousKey) as? [String: String] ?? [:]
        let group = DispatchGroup()
        var ok = true
        for id in g.types {
            guard let type = UTType(id) else { continue }
            let current = ws.urlForApplication(toOpen: type)
            let target: URL?
            if on {
                if let current, !isSpacebar(current) { previous[id] = current.path }
                target = viewer
            } else {
                guard isSpacebar(current) else { continue }
                target = giveBack(type, group: g, previous: previous[id])
            }
            guard let target else {
                ok = false
                NSLog("spacebar: no other app opens %@ to give it back to", id)
                continue
            }
            group.enter()
            ws.setDefaultApplication(at: target, toOpen: type) { err in
                DispatchQueue.main.async {
                    if let err {
                        ok = false
                        NSLog("spacebar: default app for %@ not changed: %@", id, err.localizedDescription)
                    }
                    group.leave()
                }
            }
        }
        UserDefaults.standard.set(previous, forKey: previousKey)
        group.notify(queue: .main) { done(ok) }
    }
}
