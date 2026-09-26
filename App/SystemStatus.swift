import AppKit
import UniformTypeIdentifiers

enum ExtensionState: Equatable {
    case checking, enabled, disabled, missing
}

/// Another app's Quick Look preview extension that also claims Markdown.
struct RivalExtension: Identifiable, Equatable {
    let id: String
    let name: String
    let parentName: String?
    let parentPath: String?
    let enabled: Bool
}

struct EditorApp: Identifiable, Hashable {
    let id: String
    let name: String
    let icon: NSImage
}

/// What the system says about spacebar's extensions, the extensions competing with them, and the apps that edit Markdown.
final class SystemStatus: ObservableObject {
    static let previewID = "md.spacebar.preview"
    static let foldersID = "md.spacebar.preview.folders"
    static let markdownType = UTType("net.daringfireball.markdown") ?? UTType(filenameExtension: "md") ?? .plainText

    @Published private(set) var preview = ExtensionState.checking
    @Published private(set) var folders = ExtensionState.checking
    @Published private(set) var rivals: [RivalExtension] = []
    @Published private(set) var refreshing = false
    @Published private(set) var editors: [EditorApp] = []
    @Published private(set) var defaultEditorName: String?

    private let queue = DispatchQueue(label: "md.spacebar.status")

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async {
            let preview = Self.state(of: Self.previewID)
            let folders = Self.state(of: Self.foldersID)
            let rivals = Self.markdownRivals()
            DispatchQueue.main.async {
                self.preview = preview
                self.folders = folders
                self.rivals = rivals
                self.refreshing = false
            }
        }
        loadEditors()
    }

    /// Asks pluginkit to ignore another app's extension. Only ever called from the user's confirmed click.
    func turnOff(_ rival: RivalExtension) {
        queue.async {
            _ = Self.run("/usr/bin/pluginkit", ["-e", "ignore", "-i", rival.id])
            _ = Self.run("/usr/bin/qlmanage", ["-r"])
            DispatchQueue.main.async { self.refresh() }
        }
    }

    /// Turns spacebar's own folder extension on or off. Only ever called from the user's click on the folder toggle or on
    /// the Folders tab's Turn On / Turn Off button, never at launch.
    func setFolders(_ on: Bool) {
        queue.async {
            _ = Self.run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", Self.foldersID])
            _ = Self.run("/usr/bin/qlmanage", ["-r"])
            let state = Self.state(of: Self.foldersID)
            DispatchQueue.main.async { self.folders = state }
        }
    }

    func openExtensionSettings() {
        let ws = NSWorkspace.shared
        let quickLook = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview"
        if let u = URL(string: quickLook), ws.open(u) { return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { ws.open(u) }
    }

    private func loadEditors() {
        let ws = NSWorkspace.shared
        var seen = Set<String>()
        let apps: [EditorApp] = ws.urlsForApplications(toOpen: Self.markdownType).compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, !id.hasPrefix("md.spacebar"), seen.insert(id).inserted else { return nil }
            return EditorApp(id: id, name: Self.appName(url), icon: Self.icon(url))
        }
        editors = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaultEditorName = ws.urlForApplication(toOpen: Self.markdownType).map(Self.appName)
    }

    /// An entry for a bundle ID that is not among the apps offered, e.g. one written to settings.json by hand.
    func editor(for id: String) -> EditorApp {
        if let e = editors.first(where: { $0.id == id }) { return e }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
            return EditorApp(id: id, name: Self.appName(url), icon: Self.icon(url))
        }
        return EditorApp(id: id, name: id, icon: Self.icon(nil))
    }

    static func appName(_ url: URL) -> String {
        (FileManager.default.displayName(atPath: url.path) as NSString).deletingPathExtension
    }

    static func icon(_ url: URL?, size: CGFloat = 16) -> NSImage {
        let img = (url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSWorkspace.shared.icon(for: .application)).copy() as! NSImage
        img.size = NSSize(width: size, height: size)
        return img
    }

    // MARK: pluginkit

    /// `pluginkit -m -i` prints one line per registered version, led by `+` (elected), `-` (ignored) or a space (default).
    static func state(of id: String) -> ExtensionState {
        let out = run("/usr/bin/pluginkit", ["-m", "-i", id]).output
        guard let line = out.split(separator: "\n").first(where: { $0.contains(id) }) else { return .missing }
        return line.first == "-" ? .disabled : .enabled
    }

    /// Every other preview extension whose Info.plist lists a Markdown type in QLSupportedContentTypes.
    static func markdownRivals() -> [RivalExtension] {
        let out = run("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.quicklook.preview"]).output
        var seen = Set<String>()
        return parseRecords(out).compactMap { r in
            guard !r.id.hasPrefix("md.spacebar"), let path = r.fields["Path"], claimsMarkdown(appex: path), seen.insert(r.id).inserted else { return nil }
            let name = r.fields["Display Name"] ?? r.fields["Short Name"] ?? r.id
            return RivalExtension(id: r.id, name: name, parentName: r.fields["Parent Name"], parentPath: r.fields["Parent Bundle"], enabled: r.marker != "-")
        }
    }

    struct Record { var marker: Character?; var id: String; var fields: [String: String] }

    static func parseRecords(_ text: String) -> [Record] {
        var records: [Record] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            if let eq = s.range(of: " = "), s.hasPrefix("\t") || s.hasPrefix("      ") {
                guard !records.isEmpty else { continue }
                let key = s[..<eq.lowerBound].trimmingCharacters(in: .whitespaces)
                records[records.count - 1].fields[key] = String(s[eq.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let m = s.range(of: #"^([+\-=!]?)\s*([^\s(]+)\("#, options: .regularExpression) {
                let head = s[m].dropLast()
                let marker = head.first.flatMap { "+-=!".contains($0) ? $0 : nil }
                let id = head.drop(while: { "+-=! \t".contains($0) })
                records.append(Record(marker: marker, id: String(id), fields: [:]))
            }
        }
        return records
    }

    static func claimsMarkdown(appex path: String) -> Bool {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let ext = info["NSExtension"] as? [String: Any],
              let attrs = ext["NSExtensionAttributes"] as? [String: Any],
              let types = attrs["QLSupportedContentTypes"] as? [String] else { return false }
        // net.daringfireball.markdown, public.markdown, and the many vendor-declared *.markdown types.
        return types.contains { $0.lowercased().contains("markdown") }
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return (-1, "") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
