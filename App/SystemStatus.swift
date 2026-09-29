import AppKit
import Carbon
import UniformTypeIdentifiers

enum ExtensionState: Equatable {
    case checking, enabled, disabled, missing
}

/// Another app's Quick Look preview extension that also claims some of the types spacebar previews.
struct RivalExtension: Identifiable, Equatable {
    let id: String
    let name: String
    let parentName: String?
    let parentPath: String?
    let enabled: Bool
    /// Its types that are also spacebar's, by group.
    var overlap: [QuickLookClaims.Group: [String]] = [:]

    /// "Also previews Markdown (2 types), code (42 types)".
    var summary: String { "Also previews \(QuickLookClaims.describe(overlap))" }
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
    @Published private(set) var helper = HelperState.off

    private let queue = DispatchQueue(label: "md.spacebar.status")
    private let helperQueue = DispatchQueue(label: "md.spacebar.status.helper")
    private var helperTimer: Timer?
    private var helperWatchers = 0
    private var helperPolling = false
    /// Turned on while Login Items still blocked the helper: its Accessibility prompt is asked for once it runs.
    private var promptWhenRunning = false

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        queue.async {
            let preview = Self.state(of: Self.previewID)
            let folders = Self.state(of: Self.foldersID)
            let rivals = Self.rivals()
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

    // MARK: The Space helper

    /// Polls the helper every second while someone shows its state (the General tab, the welcome sheet).
    func watchHelper() {
        helperWatchers += 1
        guard helperTimer == nil else { return }
        helperTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.pollHelper() }
        pollHelper()
    }

    func unwatchHelper() {
        helperWatchers = max(0, helperWatchers - 1)
        guard helperWatchers == 0 else { return }
        helperTimer?.invalidate()
        helperTimer = nil
    }

    func pollHelper() {
        guard !helperPolling else { return }
        helperPolling = true
        let enabled = SettingsFile.load().spaceHelper
        helperQueue.async {
            let agent = HelperAgent.agent
            // Asked only when it should be running: a connection would start a helper that exits at once when it is off.
            let status = enabled && agent == .enabled ? HelperAgent.ask(timeout: 0.8) : nil
            let state = HelperState.of(enabled: enabled, agent: agent, helper: status, secureInput: IsSecureEventInputEnabled())
            if state == .needsAccessibility, self.takePrompt() { _ = HelperAgent.promptAccessibility(timeout: 3) }
            DispatchQueue.main.async {
                self.helper = state
                self.helperPolling = false
            }
        }
    }

    private func takePrompt() -> Bool {
        DispatchQueue.main.sync {
            defer { promptWhenRunning = false }
            return promptWhenRunning
        }
    }

    /// The settings toggle and the welcome sheet's Turn On. On: the setting, the agent registered (Login Items opened when
    /// macOS wants approval first), and the helper asked to show the Accessibility prompt. Off: the setting, which the helper
    /// reads and exits on, and the agent unregistered.
    func setHelper(_ on: Bool, store: SettingsStore) {
        store.set("spaceHelper", on)
        promptWhenRunning = false
        helperQueue.async {
            if on {
                switch HelperAgent.register() {
                case .requiresApproval:
                    DispatchQueue.main.async {
                        self.promptWhenRunning = true
                        HelperAgent.openLoginItems()
                    }
                case .enabled:
                    if HelperAgent.promptAccessibility(timeout: 10) == nil { DispatchQueue.main.async { self.promptWhenRunning = true } }
                case .notRegistered, .notFound: break
                }
            } else {
                HelperAgent.unregister()
            }
            DispatchQueue.main.async { self.pollHelper() }
        }
    }

    func openExtensionSettings() {
        let ws = NSWorkspace.shared
        let quickLook = "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview"
        if let u = URL(string: quickLook), ws.open(u) { return }
        if let u = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences") { ws.open(u) }
    }

    /// The editors offered: apps that open Markdown, plain text or source code and are text editors (LinkPolicy.isTextEditor),
    /// so no browser, terminal or script runner is among them.
    private func loadEditors() {
        let ws = NSWorkspace.shared
        var seen = Set<String>()
        let candidates = [Self.markdownType, .plainText, .sourceCode].flatMap { ws.urlsForApplications(toOpen: $0) }
        let apps: [EditorApp] = candidates.compactMap { url in
            guard let id = Bundle(url: url)?.bundleIdentifier, !id.hasPrefix("md.spacebar"), LinkPolicy.isTextEditor(url), seen.insert(id).inserted else { return nil }
            return EditorApp(id: id, name: Self.appName(url), icon: Self.icon(url))
        }
        editors = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        defaultEditorName = ws.urlForApplication(toOpen: Self.markdownType).map(Self.appName)
    }

    /// An entry for a bundle ID that is not among the apps offered, e.g. one written to settings.json by hand.
    func editor(for id: String) -> EditorApp {
        if let e = editors.first(where: { $0.id == id }) { return e }
        if let url = LinkPolicy.application(id) {
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

    /// The types spacebar's preview extension claims, grouped: the copy of scripts/quicklook-types.txt in the app, else the
    /// extension's own Info.plist (ungrouped).
    static func ownClaims(bundle: Bundle = .main) -> [QuickLookClaims.Claim] {
        if let u = bundle.url(forResource: "quicklook-types", withExtension: "txt"), let text = try? String(contentsOf: u, encoding: .utf8) {
            let c = QuickLookClaims.parse(text)
            if !c.isEmpty { return c }
        }
        let appex = bundle.bundleURL.appendingPathComponent("Contents/PlugIns/SpacebarPreview.appex")
        return supportedTypes(appex: appex.path).filter { $0 != "md.spacebar.qlmanage" }.map { t in
            QuickLookClaims.Claim(type: t, extensions: [], group: t.lowercased().contains("markdown") ? .markdown : .other)
        }
    }

    /// Every other preview extension that claims a type spacebar previews (QuickLookClaims.overlap), with what it overlaps.
    static func rivals(ours: [QuickLookClaims.Claim] = ownClaims()) -> [RivalExtension] {
        let out = run("/usr/bin/pluginkit", ["-mAvvv", "-p", "com.apple.quicklook.preview"]).output
        var seen = Set<String>()
        return parseRecords(out).compactMap { r in
            // Apple's own previewers are not offered for turning off: Quick Look prefers an app's extension to them.
            guard !r.id.hasPrefix("md.spacebar"), !r.id.hasPrefix("com.apple."), let path = r.fields["Path"], seen.insert(r.id).inserted else { return nil }
            let overlap = QuickLookClaims.overlap(ours: ours, theirs: supportedTypes(appex: path), extensions: QuickLookClaims.systemExtensions)
            guard !overlap.isEmpty else { return nil }
            let name = r.fields["Display Name"] ?? r.fields["Short Name"] ?? r.id
            return RivalExtension(id: r.id, name: name, parentName: r.fields["Parent Name"], parentPath: r.fields["Parent Bundle"], enabled: r.marker != "-",
                                  overlap: overlap)
        }
        .sorted { ($0.enabled ? 0 : 1, $0.name.lowercased()) < ($1.enabled ? 0 : 1, $1.name.lowercased()) }
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

    /// The QLSupportedContentTypes of the extension at `path`.
    static func supportedTypes(appex path: String) -> [String] {
        let plist = URL(fileURLWithPath: path).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) as? [String: Any],
              let ext = info["NSExtension"] as? [String: Any],
              let attrs = ext["NSExtensionAttributes"] as? [String: Any],
              let types = attrs["QLSupportedContentTypes"] as? [String] else { return [] }
        return types
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
