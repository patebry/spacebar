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
    /// The app holding secure input while the helper is paused by it, when it can be found.
    @Published private(set) var secureInputOwner: String?
    /// A `--reregister` this app started is running.
    @Published private(set) var reregistering = false

    private let queue = DispatchQueue(label: "md.spacebar.status")
    private let helperQueue = DispatchQueue(label: "md.spacebar.status.helper")
    private var helperTimer: Timer?
    private var helperWatchers = 0
    private var helperPolling = false
    private var helperMisses = 0
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

    /// A copy dragged into Applications from spacebar.dmg has not had install.sh register it. Launching it registers its
    /// extensions (FINDINGS.md, Install) but turns them neither on nor off. So at launch an extension pluginkit does not list
    /// at this copy's path is added, and one no listed version of which was ever turned on or off is turned on as install.sh
    /// does, the folder one only while folder previews are on. A choice made for any copy is left alone. Only the copy
    /// install.sh would update does this, so a second copy never takes them over.
    func registerIfNew() {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        // Not through a link, which install.sh refuses to update.
        guard let managed = Updates.managedCopy(home: NSHomeDirectory()), !Updates.isLink(managed),
              URL(fileURLWithPath: managed).resolvingSymlinksInPath().path == app else { return }
        queue.async {
            var changed = false
            let folders = SettingsFile.load().folderMode
            for (id, name, on) in [(Self.previewID, "SpacebarPreview", true), (Self.foldersID, "SpacebarFolders", folders)] {
                let appex = app + "/Contents/PlugIns/\(name).appex"
                let listed = Updates.elections(pluginkit: Self.run("/usr/bin/pluginkit", ["-mADv", "-i", id]).output)
                if !listed.contains(where: { $0.path == appex }) { _ = Self.run("/usr/bin/pluginkit", ["-a", appex]) }
                guard !listed.contains(where: { $0.mark == "+" || $0.mark == "-" }) else { continue }
                NSLog("spacebar: turning %@ %@ for %@", id, on ? "on" : "off", app)
                _ = Self.run("/usr/bin/pluginkit", ["-e", on ? "use" : "ignore", "-i", id])
                changed = true
            }
            if changed { _ = Self.run("/usr/bin/qlmanage", ["-r"]); _ = Self.run("/usr/bin/qlmanage", ["-r", "cache"]) }
        }
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

    /// Polls the helper every second while someone shows its state (the settings window, the welcome sheet).
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
        let settings = SettingsFile.load()
        helperQueue.async {
            let agent = HelperAgent.agent
            // Asked only when it should be running: a connection would start a helper that exits at once when it is off.
            let status = settings.spaceHelper && agent == .enabled ? HelperAgent.ask(timeout: 0.8) : nil
            var state = HelperState.of(enabled: settings.spaceHelper, agent: agent, helper: status, secureInput: IsSecureEventInputEnabled())
            if state == .needsAccessibility, self.takePrompt() { _ = HelperAgent.promptAccessibility(timeout: 3) }
            let owner = state == .secureInput ? SecureInput.ownerName() : nil
            DispatchQueue.main.async {
                self.helperMisses = settings.spaceHelper && agent == .enabled && status == nil ? self.helperMisses + 1 : 0
                if HelperState.shouldReregister(enabled: settings.spaceHelper, agent: agent, answering: status != nil, misses: self.helperMisses) {
                    state = .notRunning
                    self.reregister()
                }
                if self.helper != state { self.helper = state }
                if self.secureInputOwner != owner { self.secureInputOwner = owner }
                self.helperPolling = false
            }
        }
    }

    /// At launch: a helper that should be running but does not answer (the app was just replaced) is restarted at once.
    func checkHelperAtLaunch() {
        let settings = SettingsFile.load()
        guard settings.spaceHelper, HelperAgent.available else { return }
        helperQueue.async {
            let agent = HelperAgent.agent
            if HelperState.registersAtLaunch(enabled: settings.spaceHelper, agent: agent) {
                _ = HelperAgent.register()
                DispatchQueue.main.async { self.pollHelper() }
                return
            }
            let answering = agent == .enabled && HelperAgent.ask(timeout: 3) != nil
            guard HelperState.shouldReregister(enabled: settings.spaceHelper, agent: agent, answering: answering, misses: answering ? 0 : HelperState.missesBeforeReregister) else { return }
            DispatchQueue.main.async { self.reregister() }
        }
    }

    /// Runs this app's own `--reregister` as a separate process (it takes 10 s to minutes, and outlives the window), logged
    /// to ~/Library/Logs/spacebar-helper.log. One at a time from here; the command itself also refuses a second concurrent run.
    func reregister() {
        guard !reregistering, let exe = Bundle.main.executablePath else { return }
        let logURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/spacebar-helper.log")
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        guard let log = try? FileHandle(forWritingTo: logURL) else { return }
        log.seekToEndOfFile()
        log.write(Data("=== \(Date()) reregister from the settings app ===\n".utf8))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["--reregister"]
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in
            try? log.close()
            DispatchQueue.main.async {
                self.reregistering = false
                self.helperMisses = 0
                self.pollHelper()
            }
        }
        do { try p.run(); reregistering = true } catch { try? log.close() }
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
