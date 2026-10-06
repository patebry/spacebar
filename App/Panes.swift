import SwiftUI

let paneWidth: CGFloat = 640

struct ProblemRow: View {
    let message: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Show in Finder") { Finder.reveal(SettingsFile.url) }
        }
    }
}

enum Finder {
    static func reveal(_ url: URL) {
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    /// Creates the support folder (and a default settings.json when there is none) first, so there is something to show.
    static func revealSupport(_ url: URL) {
        _ = SettingsFile.ensure()
        reveal(url)
    }
}

struct StatusDot: View {
    let color: Color
    var body: some View {
        Circle().fill(color).frame(width: 8, height: 8)
            .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.5))
    }
}

struct NoticeRow: View {
    let message: String
    let button: String
    let action: () -> Void
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
            Text(message).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(button, action: action)
        }
    }
}

// MARK: - Settings

/// The settings window: one page of what people change, and the rest under Advanced, closed until asked for. Anything wrong
/// with the setup (the settings file, the extensions, another previewer) shows on top only while it is wrong.
struct SettingsPane: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus
    @Environment(\.colorScheme) private var scheme
    @State private var confirming: RivalExtension?
    @State private var confirmReset = false
    @State private var confirmUninstall = false
    @State private var uninstallCopies: (removed: [String], left: [String]) = ([], [])
    @State private var purge = false
    @State private var uninstallError: String?
    @StateObject private var updates = UpdateCheck()

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onChange(of: store.advancedRequests) { _ in scrollToAdvanced(proxy) }
                .onAppear { if store.advancedExpanded { scrollToAdvanced(proxy) } }
        }
    }

    /// After the page has laid out the opened section.
    private func scrollToAdvanced(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async { withAnimation { proxy.scrollTo(Self.advancedID, anchor: .top) } }
    }

    private static let advancedID = "advanced"

    private var form: some View {
        Form {
            problems
            quickLookStatus
            appearance
            spaceHelper
            Section {
                Picker("Open files in", selection: store.binding(\.editorBundleID, "editorBundleID")) {
                    Text(system.defaultEditorName.map { "Default App (\($0))" } ?? "Default App").tag(String?.none)
                    Divider()
                    ForEach(editorChoices) { app in
                        Label { Text(app.name) } icon: { Image(nsImage: app.icon) }
                            .tag(Optional(app.id))
                    }
                }
            } header: {
                Text("Editor")
            } footer: {
                Text("The preview's Open button uses it for Markdown, code, data and text files. Scripts open here as text, never run. With Default App, a file opens in its own app, or in your default text editor when that app could run it.")
                    .settingsFooter()
            }
            about
            Section {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { store.advancedExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .rotationEffect(.degrees(store.advancedExpanded ? 90 : 0))
                        Text("Advanced")
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardFocusRing(cornerRadius: 4)
                .accessibilityValue(store.advancedExpanded ? "Expanded" : "Collapsed")
            }
            .id(Self.advancedID)
            if store.advancedExpanded { advanced }
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
        .alert(item: $confirming) { rival in
            Alert(
                title: Text("Turn off \(rival.name)?"),
                message: Text("Quick Look will stop using this extension for every type it previews, so spacebar can show those files: \(QuickLookClaims.describe(rival.overlap)). You can turn it back on in System Settings."),
                primaryButton: .destructive(Text("Turn Off")) { system.turnOff(rival) },
                secondaryButton: .cancel())
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) {
                // Folder previews come back on, so the extension does too.
                if store.resetToDefaults(), system.folders == .disabled { system.setFolders(true) }
            }
        } message: {
            Text("Every setting goes back to how spacebar comes, including those only settings.json changes, and no custom theme or custom.css is chosen. The Space helper stays as it is, and your theme files and custom.css are kept.")
        }
        .sheet(isPresented: $confirmUninstall) { uninstallSheet }
    }

    // MARK: Problems

    @ViewBuilder private var problems: some View {
        if let problem = store.problem {
            Section { ProblemRow(message: problem) }
        }
        if let note = extensionNote {
            Section {
                NoticeRow(message: note, button: "Open Quick Look Extensions…") { system.openExtensionSettings() }
            }
        }
        if !rivals.isEmpty {
            Section {
                ForEach(rivals) { rival in
                    LabeledContent {
                        Button("Turn Off…") { confirming = rival }
                    } label: {
                        HStack(spacing: 8) {
                            Image(nsImage: SystemStatus.icon(rival.parentPath.map { URL(fileURLWithPath: $0) }, size: 24))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(rival.name)
                                Text(rival.parentName.map { "Part of \($0)" } ?? rival.id)
                                    .font(.caption).foregroundStyle(.secondary)
                                Text(rival.summary)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            } header: {
                Text("Other Quick Look Previewers")
            } footer: {
                Text("Quick Look uses one extension for each file type. When another app's extension also claims a type spacebar previews, macOS may choose it instead of spacebar for those files.")
                    .settingsFooter()
            }
        }
        if let mismatch {
            Section {
                NoticeRow(message: mismatch, button: store.settings.folderMode ? "Turn On" : "Turn Off") { system.setFolders(store.settings.folderMode) }
            }
        }
    }

    /// Only once the extension is known to be on; anything wrong shows as a notice above instead.
    @ViewBuilder private var quickLookStatus: some View {
        if system.preview == .enabled {
            Section {
                LabeledContent("Quick Look") {
                    HStack(spacing: 14) {
                        HStack(spacing: 6) { StatusDot(color: .green); Text("Files: On") }
                        HStack(spacing: 6) {
                            StatusDot(color: system.folders == .enabled ? .green : .gray)
                            Text(system.folders == .enabled ? "Folders: On" : "Folders: Off")
                        }
                    }
                    .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// Only enabled ones: a rival that is off takes nothing from spacebar.
    private var rivals: [RivalExtension] { system.rivals.filter(\.enabled) }

    private var extensionNote: String? {
        switch system.preview {
        case .disabled: return "spacebar is turned off in Quick Look, so Space shows Apple's preview. Turn it on in the Quick Look section of Extensions."
        case .missing: return "spacebar's Quick Look extension isn't registered. Open spacebar from your Applications folder, or install it again."
        case .enabled, .checking: return nil
        }
    }

    /// The setting and the folder extension disagree, e.g. settings.json was edited, or the extension was switched in System Settings.
    private var mismatch: String? {
        switch (store.settings.folderMode, system.folders) {
        case (true, .disabled): return "Folder previews are turned off in System Settings."
        case (false, .enabled): return "Folder previews are off in settings.json but still on in System Settings."
        default: return nil
        }
    }

    // MARK: Appearance

    private var appearance: some View {
        Section {
            HStack(alignment: .top, spacing: 10) {
                ForEach(ThemeInfo.all) { t in
                    ThemeCard(theme: t, selected: store.settings.theme == t.id, dark: dark) { store.set("theme", t.id) }
                }
            }
            .padding(.vertical, 4)
            Picker("Appearance", selection: store.binding(\.appearance, "appearance")) {
                Text("Automatic").tag("auto")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            LabeledContent("Text size") {
                HStack(spacing: 6) {
                    Text("\(store.settings.fontSize) pt").monospacedDigit().foregroundStyle(.primary)
                    Stepper("Text size", value: store.binding(\.fontSize, "fontSize"), in: 12...24).labelsHidden()
                }
            }
        } header: {
            Text("Appearance")
        } footer: {
            Text("The Aa button in the preview changes these too, with the font and page width.").settingsFooter()
        }
    }

    private var dark: Bool {
        switch store.settings.appearance {
        case "light": return false
        case "dark": return true
        default: return scheme == .dark
        }
    }

    // MARK: Space helper

    private var spaceHelper: some View {
        Section {
            Toggle(isOn: helperToggle) {
                Text("Use spacebar for every file")
                Text(HelperCopy.what)
            }
            .disabled(!HelperAgent.available)
            if HelperAgent.available {
                LabeledContent {
                    HelperStatusView(state: system.helper)
                } label: {
                    Text("Status")
                    if let why = HelperCopy.detail(system.helper) { Text(why) }
                }
            }
        } header: {
            Text("Space Helper")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if HelperAgent.available {
                    Text(HelperCopy.privacy).settingsFooter()
                        .background(Color.clear.onAppear { system.watchHelper() }.onDisappear { system.unwatchHelper() })
                } else {
                    Text(HelperCopy.unavailable).settingsFooter()
                }
                Link(HelperCopy.howItWorks, destination: HelperCopy.securityURL).font(.footnote)
            }
        }
    }

    // MARK: About

    private var about: some View {
        Section {
            LabeledContent {
                HStack(spacing: 8) {
                    if updates.status == .checking { ProgressView().controlSize(.small) }
                    if let text = updates.status.text { Text(text).foregroundStyle(.secondary) }
                    Button("Check Now") { updates.checkNow(enabled: store.settings.checkUpdates) }
                        .disabled(!store.settings.checkUpdates || !UpdateCheck.allowed || updates.status == .checking)
                }
            } label: {
                Text("spacebar \(UpdateCheck.version)")
                if case .available = updates.status {
                    Text("Open any preview to install it, or run the install command in Terminal.")
                }
            }
            if case .available = updates.status {
                HStack {
                    Spacer()
                    Button("Copy Install Command") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(Updates.installCommand, forType: .string)
                    }
                }
            }
            Toggle("Check for updates", isOn: store.binding(\.checkUpdates, "checkUpdates"))
            HStack {
                Button("Report a Problem…") { NSWorkspace.shared.open(ProblemReport.url(ProblemReport.current(), log: ProblemReport.readLog())) }
                Spacer()
                Button("Uninstall spacebar…") { purge = false; uninstallError = nil; uninstallCopies = Uninstall.copies(); confirmUninstall = true }
            }
        } header: {
            Text("About")
        } footer: {
            Text("Once a day spacebar asks GitHub for the latest version number, and nothing else; Check Now asks at once. A newer version shows here and in the preview. Report a Problem opens a public GitHub issue in your browser; nothing is sent until you submit it.")
                .settingsFooter()
        }
        .onAppear { updates.load(enabled: store.settings.checkUpdates) }
        .onChange(of: store.settings.checkUpdates) { updates.load(enabled: $0) }
    }

    private var helperToggle: Binding<Bool> {
        Binding(get: { store.settings.spaceHelper }, set: { system.setHelper($0, store: store) })
    }

    private var editorChoices: [EditorApp] {
        var apps = system.editors
        if let id = store.settings.editorBundleID, !apps.contains(where: { $0.id == id }) { apps.append(system.editor(for: id)) }
        return apps
    }

    // MARK: Advanced

    @ViewBuilder private var advanced: some View {
        Section {
            Picker("Scripts in HTML files", selection: store.binding(\.htmlScripts, "htmlScripts")) {
                Text("Ask").tag("ask")
                Text("Files made on this Mac").tag("local")
                Text("Never").tag("off")
            }
            Picker("HTML in Markdown", selection: store.binding(\.rawHTML, "rawHTML")) {
                Text("Off").tag("off")
                Text("Sanitized").tag("sanitized")
            }
            .pickerStyle(.segmented)
            Toggle("Load remote images", isOn: store.binding(\.remoteImages, "remoteImages"))
        } header: {
            Text("Web Content")
        } footer: {
            Text("An HTML file your browser, Mail or AirDrop marked as downloaded always opens with scripts off and nothing loaded from the web. Files from git clone, curl, unzip or a USB drive are not marked: with Ask, such a page opens without its scripts and asks whether to run them; with Files made on this Mac they run and may load from the web; with Never, no HTML file does either. Scripts can reach the network, so a page that runs them can tell a server it was opened and send what it shows. Sanitized HTML in Markdown keeps formatting tags but never runs scripts. Remote images are off by default: fetching one lets its server see when the document was opened. A blocked image offers to load that document's images once.")
                .settingsFooter()
        }

        Section {
            Toggle(isOn: store.binding(\.inlineEditing, "inlineEditing")) {
                Text("Edit text in the preview")
                Text("Click the text of Markdown, code or a text file to edit it in place. For JSON and CSV, click Raw (</>) in the toolbar first. Changes save as you type, and ⌘Z undoes them while the file stays open; if the file changes on disk, you choose which version to keep.")
            }
            Toggle(isOn: store.binding(\.taskToggles, "taskToggles")) {
                Text("Check off tasks")
                Text("Click a task list checkbox to check or uncheck it in the file.")
            }
            Toggle(isOn: store.binding(\.showHiddenFiles, "showHiddenFiles")) {
                Text("Show hidden files in the sidebar")
                Text("Always. They also show while Finder shows them (⇧⌘.).")
            }
        } header: {
            Text("Preview")
        }

        Section {
            Picker("Custom theme", selection: userThemeChoice) {
                Text("None").tag(String?.none)
                if !userThemes.isEmpty { Divider() }
                ForEach(userThemes, id: \.file) { Text($0.name).tag(Optional($0.file)) }
                Divider()
                Text("Open Themes Folder…").tag(Optional(Self.openThemesFolder))
            }
            LabeledContent {
                HStack(spacing: 12) {
                    Button("Show in Finder") { Finder.revealSupport(SettingsFile.customCSS) }
                    Toggle("Apply custom.css", isOn: store.binding(\.customCSS, "customCSS"))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            } label: {
                Text("Apply custom.css")
            }
        } header: {
            Text("Custom CSS")
        } footer: {
            Text("Custom themes are CSS files in the themes folder, applied on top of the theme. custom.css is applied last.")
                .settingsFooter()
        }

        Section {
            LabeledContent("Location") {
                Text((SettingsFile.url.path as NSString).abbreviatingWithTildeInPath)
                    .truncationMode(.middle)
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack {
                Button("Reset to Defaults…") { confirmReset = true }
                Spacer()
                Button("Show settings.json in Finder") { Finder.revealSupport(SettingsFile.url) }
            }
        } header: {
            Text("Settings File")
        } footer: {
            Text("Everything else, such as fonts, line height, the table of contents and folder previews, is set in this file; the README lists the keys. Changes appear here and in open previews right away.")
                .settingsFooter()
        }
    }

    /// Not a file name (those cannot contain NUL): the picker's last item, which opens the folder instead of choosing a theme.
    private static let openThemesFolder = "\u{0}open-themes-folder"

    private var userThemeChoice: Binding<String?> {
        Binding(get: { store.settings.userTheme }, set: { v in
            if v == Self.openThemesFolder {
                Finder.revealSupport(SettingsFile.themesDir)
                store.objectWillChange.send()
            } else {
                store.set("userTheme", v ?? NSNull())
            }
        })
    }

    private var userThemes: [UserTheme] {
        var list = store.userThemes
        if let f = store.settings.userTheme, !list.contains(where: { $0.file == f }) {
            list.append(UserTheme(file: f, name: "\(f) (missing)", appearance: "auto"))
        }
        return list
    }

    // MARK: Uninstall

    private var uninstallSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Uninstall spacebar?").font(.headline)
            Text("spacebar quits, and these are removed:")
            VStack(alignment: .leading, spacing: 4) {
                ForEach(uninstallCopies.removed, id: \.self) { Text("• \(Uninstall.shown($0))") }
                Text("• its Quick Look extensions, unregistered from macOS")
                Text("• its Space helper, and the Accessibility permission you gave it")
            }
            .padding(.leading, 4)
            Toggle(isOn: $purge) {
                Text("Also delete my settings and themes")
                Text("~/Library/Application Support/spacebar (and spacebar.md there from older versions), and the Space helper's log").font(.caption).foregroundStyle(.secondary)
            }
            .toggleStyle(.checkbox)
            Text("Nothing else is touched: your files, and the spacebar Sample Folder in your home folder, stay where they are. What the uninstaller did is written to ~/Library/Logs/spacebar-uninstall.log.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(uninstallCopies.left, id: \.self) {
                Text("\(Uninstall.shown($0)) stays: this account can't delete it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !Uninstall.isInstalledCopy {
                Text("This copy of spacebar isn't in ~/Applications or /Applications, so it can't uninstall it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let uninstallError {
                Label(uninstallError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { confirmUninstall = false }.keyboardShortcut(.cancelAction)
                Button("Uninstall", role: .destructive) { uninstallError = Uninstall.run(purge: purge) }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .disabled(!Uninstall.isInstalledCopy)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

// MARK: - The Space helper

enum HelperCopy {
    static let what = "Space opens spacebar for any file you select in Finder, images, PDFs and video included, not only the types Quick Look hands it. Space or Esc closes it."
    /// The name System Settings lists the helper under in Accessibility: the bundle's file name, not its display name.
    static let accessibilityName = "spacebar Helper"
    /// What the helper sees and does with it; every claim is in SECURITY.md's "The Space helper".
    static let keys = "To catch Space in Finder, the Space helper uses Accessibility, listed there as \(accessibilityName), so it sees every key you press while it runs. It acts only on Space while Finder is in front, when it reads which file is selected, and on the arrows and a few other keys while spacebar's panel is open. It never keeps what you type or sends it off this Mac, and secure input, as in a password field, hides your keys from it."
    static let privacy = keys + " Turning it off removes spacebar from Login Items; Quick Look then previews as before."
    static let howItWorks = "How the Space helper works"
    static let unavailable = "This copy of spacebar has no Space helper it can run: it needs a signed copy installed with spacebar.dmg or the install command."
    static let securityURL = URL(string: "https://github.com/patebry/spacebar/blob/main/SECURITY.md#the-space-helper")!

    /// `owner`: the app holding secure input, when it could be found.
    static func title(_ s: HelperState, owner: String? = nil) -> String {
        switch s {
        case .off: return "Off"
        case .notRunning: return "Not running"
        case .starting: return "Starting…"
        case .needsLoginItems: return "Blocked in Login Items"
        case .needsAccessibility: return "Waiting for Accessibility"
        case .secureInput: return owner.map { "Paused while \($0) has secure input on" } ?? "Paused: another app has secure input on"
        case .on: return "On"
        }
    }

    static func detail(_ s: HelperState) -> String? {
        switch s {
        case .needsLoginItems: return "Turn on spacebar in System Settings, General, Login Items & Extensions."
        case .needsAccessibility: return "Turn on \(accessibilityName) in System Settings, Privacy & Security, Accessibility."
        case .secureInput: return "Space goes to Quick Look until that app turns secure input off (a password field, or Terminal's Secure Keyboard Entry)."
        case .notRunning: return "macOS did not start the Space helper, as happens for a while after an update. spacebar starts it again by itself."
        default: return nil
        }
    }

    static func color(_ s: HelperState) -> Color {
        switch s {
        case .on: return .green
        case .off, .starting: return .gray
        default: return .orange
        }
    }
}

/// The helper's state as a dot and a word, with the one button that moves it on.
struct HelperStatusView: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus
    let state: HelperState

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(color: HelperCopy.color(state))
            Text(system.reregistering && state != .on ? "Restarting…" : HelperCopy.title(state, owner: system.secureInputOwner))
                .fixedSize(horizontal: false, vertical: true)
            switch state {
            case .needsLoginItems: Button("Open Login Items…") { HelperAgent.openLoginItems() }
            case .needsAccessibility: Button("Open Accessibility Settings…") { HelperAgent.openAccessibility() }
            case .notRunning: Button("Try Again") { system.reregister() }.disabled(system.reregistering)
            default: EmptyView()
            }
        }
    }
}

// MARK: - Appearance

struct ThemeInfo: Identifiable {
    let id: String
    let title: String
    let serif: Bool
    let light: (bg: Color, fg: Color, accent: Color?)
    let dark: (bg: Color, fg: Color, accent: Color?)

    /// A nil accent means the system accent colour, as the Apple theme uses.
    static let all: [ThemeInfo] = [
        ThemeInfo(id: "apple", title: "Apple", serif: false,
                  light: (Color(hex: 0xFFFFFF), Color(hex: 0x1D1D1F), nil), dark: (Color(hex: 0x1E1E1E), Color(hex: 0xDFDFDF), nil)),
        ThemeInfo(id: "github", title: "GitHub", serif: false,
                  light: (Color(hex: 0xFFFFFF), Color(hex: 0x1F2328), Color(hex: 0x0969DA)), dark: (Color(hex: 0x0D1117), Color(hex: 0xE6EDF3), Color(hex: 0x4493F8))),
        ThemeInfo(id: "paper", title: "Paper", serif: true,
                  light: (Color(hex: 0xF8F1E3), Color(hex: 0x4F321C), Color(hex: 0xB5651D)), dark: (Color(hex: 0x262320), Color(hex: 0xDDD0B9), Color(hex: 0xE5AB6D))),
        ThemeInfo(id: "solarized", title: "Solarized", serif: false,
                  light: (Color(hex: 0xFDF6E3), Color(hex: 0x586E75), Color(hex: 0x268BD2)), dark: (Color(hex: 0x002B36), Color(hex: 0x93A1A1), Color(hex: 0x3A9CE0))),
        ThemeInfo(id: "nord", title: "Nord", serif: false,
                  light: (Color(hex: 0xECEFF4), Color(hex: 0x2E3440), Color(hex: 0x5E81AC)), dark: (Color(hex: 0x2E3440), Color(hex: 0xD8DEE9), Color(hex: 0x88C0D0))),
        ThemeInfo(id: "contrast", title: "High Contrast", serif: false,
                  light: (Color(hex: 0xFFFFFF), Color(hex: 0x000000), Color(hex: 0x0000C8)), dark: (Color(hex: 0x000000), Color(hex: 0xFFFFFF), Color(hex: 0x9ED0FF))),
    ]

    static func title(_ id: String) -> String { all.first { $0.id == id }?.title ?? id.capitalized }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double(hex >> 16 & 0xFF) / 255, green: Double(hex >> 8 & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

struct ThemeCard: View {
    let theme: ThemeInfo
    let selected: Bool
    let dark: Bool
    let action: () -> Void

    var body: some View {
        let c = dark ? theme.dark : theme.light
        let accent = c.accent ?? .accentColor
        Button(action: action) {
            VStack(spacing: 7) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Aa")
                        .font(.system(size: 17, weight: .semibold, design: theme.serif ? .serif : .default))
                        .foregroundColor(c.fg)
                    Capsule().fill(accent).frame(width: 30, height: 3.5)
                    Capsule().fill(c.fg.opacity(0.3)).frame(width: 50, height: 3)
                    Capsule().fill(c.fg.opacity(0.3)).frame(width: 38, height: 3)
                }
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .frame(height: 64)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(c.bg))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .padding(3)
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3).opacity(selected ? 1 : 0))
                Text(theme.title)
                    .font(.callout)
                    .foregroundStyle(selected ? .primary : .secondary)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardFocusRing(cornerRadius: 10)
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A plain-style button draws no focus ring of its own, so with Full Keyboard Access this draws one when it has focus.
struct KeyboardFocusRing: ViewModifier {
    let cornerRadius: CGFloat
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focused($focused)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .keyboardFocusIndicatorColor), lineWidth: 3)
                .opacity(focused ? 1 : 0)
                .allowsHitTesting(false))
    }
}

extension View {
    func keyboardFocusRing(cornerRadius: CGFloat) -> some View { modifier(KeyboardFocusRing(cornerRadius: cornerRadius)) }

    func settingsFooter() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
