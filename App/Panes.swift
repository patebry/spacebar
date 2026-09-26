import SwiftUI

enum SettingsTab: String, CaseIterable {
    case general, appearance, folders, editing, advanced

    var title: String { rawValue.capitalized }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintpalette"
        case .folders: return "folder"
        case .editing: return "pencil.line"
        case .advanced: return "gearshape.2"
        }
    }

    /// spacebar-md://settings/<tab>; a missing tab means General.
    init?(url: URL) {
        guard url.scheme?.lowercased() == "spacebar-md", url.host?.lowercased() == "settings" else { return nil }
        let name = url.pathComponents.first { $0 != "/" }?.lowercased() ?? "general"
        self.init(rawValue: name)
    }
}

let paneWidth: CGFloat = 640

/// A tab's grouped form, with the settings-file problem (if any) on top.
struct Pane<Content: View>: View {
    @EnvironmentObject var store: SettingsStore
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            if let problem = store.problem {
                Section { ProblemRow(message: problem) }
            }
            content
        }
        .formStyle(.grouped)
        .frame(width: paneWidth)
    }
}

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

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus
    @State private var confirming: RivalExtension?

    var body: some View {
        Pane {
            Section {
                LabeledContent {
                    HStack(spacing: 6) {
                        StatusDot(color: statusColor)
                        Text(statusText)
                    }
                } label: {
                    Text("spacebar")
                    Text("Shows Markdown files when you press Space in Finder.")
                }
                HStack {
                    Spacer()
                    Button("Open Quick Look Extensions…") { system.openExtensionSettings() }
                }
            } header: {
                Text("Quick Look")
            } footer: {
                Text("If Markdown files don't preview, make sure spacebar is turned on in the Quick Look section of Extensions in System Settings.")
                    .settingsFooter()
            }

            Section {
                if system.rivals.isEmpty {
                    Label(system.refreshing ? "Checking…" : "No other Quick Look extension claims Markdown.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(system.rivals) { rival in
                        LabeledContent {
                            if rival.enabled {
                                Button("Turn Off…") { confirming = rival }
                            } else {
                                Text("Off").foregroundStyle(.secondary)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(nsImage: SystemStatus.icon(rival.parentPath.map { URL(fileURLWithPath: $0) }, size: 24))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(rival.name)
                                    Text(rival.parentName.map { "Part of \($0)" } ?? rival.id)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } header: {
                Text("Other Markdown Previewers")
            } footer: {
                Text("Quick Look uses one extension for each file type. When another app's extension also claims Markdown, macOS may choose it instead of spacebar.")
                    .settingsFooter()
            }

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
                Text("Used by Open in Editor, and for Markdown links when they are set to open in your editor.")
                    .settingsFooter()
            }
        }
        .alert(item: $confirming) { rival in
            Alert(
                title: Text("Turn off \(rival.name)?"),
                message: Text("Quick Look will stop using this extension for Markdown and every other type it previews, so spacebar can show Markdown files. You can turn it back on in System Settings."),
                primaryButton: .destructive(Text("Turn Off")) { system.turnOff(rival) },
                secondaryButton: .cancel())
        }
    }

    private var editorChoices: [EditorApp] {
        var apps = system.editors
        if let id = store.settings.editorBundleID, !apps.contains(where: { $0.id == id }) { apps.append(system.editor(for: id)) }
        return apps
    }

    private var statusColor: Color {
        switch system.preview {
        case .enabled: return .green
        case .checking: return .gray
        case .disabled, .missing: return .orange
        }
    }

    private var statusText: String {
        switch system.preview {
        case .checking: return "Checking…"
        case .enabled: return "On"
        case .disabled: return "Off in System Settings"
        case .missing: return "Not registered"
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
        .accessibilityLabel(theme.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct AppearancePane: View {
    @EnvironmentObject var store: SettingsStore
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let s = store.settings
        VStack(spacing: 0) {
            LivePreview(store: store)
                .frame(height: 150)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
                .padding(.horizontal, 20)
                .padding(.top, 20)
                .padding(.bottom, 2)
            Pane {
                Section {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(ThemeInfo.all) { t in
                            ThemeCard(theme: t, selected: s.theme == t.id, dark: dark) { store.set("theme", t.id) }
                        }
                    }
                    .padding(.vertical, 4)
                    Picker("Appearance", selection: store.binding(\.appearance, "appearance")) {
                        Text("Automatic").tag("auto")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    Picker("Code highlighting", selection: store.binding(\.codeTheme, "codeTheme")) {
                        Text("Match Theme").tag("auto")
                        Divider()
                        ForEach(Settings.themes, id: \.self) { Text(ThemeInfo.title($0)).tag($0) }
                    }
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
                    Text("Theme")
                } footer: {
                    Text("Custom themes are CSS files in the themes folder, applied on top of the theme above. custom.css is applied last.")
                        .settingsFooter()
                }

                Section("Text") {
                    Picker("Font", selection: store.binding(\.bodyFont, "bodyFont")) {
                        Text("System").tag("system")
                        Text("Serif").tag("serif")
                        Text("Rounded").tag("rounded")
                        Text("Monospaced").tag("mono")
                    }
                    Picker("Code font", selection: store.binding(\.monoFont, "monoFont")) {
                        Text("SF Mono").tag("system")
                        Text("Menlo").tag("menlo")
                        Text("Monaco").tag("monaco")
                        Text("Courier").tag("courier")
                    }
                    LabeledContent("Font size") {
                        HStack(spacing: 6) {
                            Text("\(s.fontSize) pt").monospacedDigit().foregroundStyle(.primary)
                            Stepper("Font size", value: store.binding(\.fontSize, "fontSize"), in: 12...24).labelsHidden()
                        }
                    }
                    LabeledContent("Line height") {
                        HStack(spacing: 10) {
                            Slider(value: lineHeight, in: 1.2...2.0) { Text("Line height") }
                                .labelsHidden()
                                .frame(width: 180)
                            Text(s.lineHeight.formatted(.number.precision(.fractionLength(0...2))))
                                .monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        }
                    }
                    Picker("Page width", selection: store.binding(\.width, "width")) {
                        Text("Narrow").tag("narrow")
                        Text("Medium").tag("medium")
                        Text("Wide").tag("wide")
                        Text("Full").tag("full")
                    }
                    .pickerStyle(.segmented)
                }
            }
            .frame(idealHeight: 640)
        }
        .frame(width: paneWidth)
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

    /// Snapped to 0.05 without the tick marks a stepped slider draws.
    private var lineHeight: Binding<Double> {
        Binding(get: { store.settings.lineHeight }, set: { v in
            let snapped = (v * 20).rounded() / 20
            if snapped != store.settings.lineHeight { store.set("lineHeight", snapped) }
        })
    }

    private var dark: Bool {
        switch store.settings.appearance {
        case "light": return false
        case "dark": return true
        default: return scheme == .dark
        }
    }

    private var userThemes: [UserTheme] {
        var list = store.userThemes
        if let f = store.settings.userTheme, !list.contains(where: { $0.file == f }) {
            list.append(UserTheme(file: f, name: "\(f) (missing)", appearance: "auto"))
        }
        return list
    }
}

// MARK: - Folders

struct FoldersPane: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus

    var body: some View {
        let on = store.settings.folderMode
        Pane {
            Section {
                Toggle(isOn: folderMode) {
                    Text("Preview folders")
                    Text("Press Space on a folder to browse the Markdown files in it.")
                }
                if let mismatch {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                        Text(mismatch).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 8)
                        Button(on ? "Turn On" : "Turn Off") { system.setFolders(on) }
                    }
                }
            } header: {
                Text("Folder Previews")
            } footer: {
                Text(folderNote).settingsFooter()
            }
            Section {
                Toggle("Show README first", isOn: store.binding(\.folderReadmeFirst, "folderReadmeFirst"))
                Picker("Sort files by", selection: store.binding(\.folderSort, "folderSort")) {
                    Text("Name").tag("name")
                    Text("Date Modified").tag("modified")
                }
            } header: {
                Text("Sidebar")
            } footer: {
                Text("When a folder has a README, it opens first; the other files are listed in the sidebar in this order.")
                    .settingsFooter()
            }
            .disabled(!on)
        }
    }

    /// The toggle is the one place (with the Turn On / Turn Off button) that changes the extension's state in System Settings.
    private var folderMode: Binding<Bool> {
        Binding(get: { store.settings.folderMode }, set: { on in
            store.set("folderMode", on)
            if system.folders == .enabled || system.folders == .disabled { system.setFolders(on) }
        })
    }

    /// The setting and the extension disagree, e.g. settings.json was edited, or the extension was switched in System Settings.
    private var mismatch: String? {
        switch (store.settings.folderMode, system.folders) {
        case (true, .disabled): return "Folder previews are turned off in System Settings."
        case (false, .enabled): return "Folder previews are still turned on in System Settings."
        default: return nil
        }
    }

    private var folderNote: String {
        let base = "Folders without Markdown files keep their usual preview. Quick Look restarts when you change this."
        if system.folders == .missing { return "The spacebar Folders extension isn't registered, so this setting has no effect yet. " + base }
        return base
    }
}

// MARK: - Editing

struct EditingPane: View {
    @EnvironmentObject var store: SettingsStore

    var body: some View {
        Pane {
            Section {
                Toggle(isOn: store.binding(\.inlineEditing, "inlineEditing")) {
                    Text("Edit text in the preview")
                    Text("Click a paragraph, heading or list item to edit it in place. Changes are saved to the file as you type.")
                }
                Toggle(isOn: store.binding(\.taskToggles, "taskToggles")) {
                    Text("Check off tasks")
                    Text("Click a task list checkbox to check or uncheck it in the file.")
                }
            } header: {
                Text("Text and Tasks")
            } footer: {
                Text("If the file changes on disk while you edit, the change on disk wins and your edit ends.")
                    .settingsFooter()
            }

            Section {
                Picker("Open Markdown links in", selection: store.binding(\.mdLinks, "mdLinks")) {
                    Text("Preview").tag("preview")
                    Text("Editor").tag("editor")
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Links")
            } footer: {
                Text("Preview follows links to other Markdown files inside Quick Look. Editor opens them in the app chosen in General. Web links always open in your browser.")
                    .settingsFooter()
            }
        }
    }
}

// MARK: - Advanced

struct AdvancedPane: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus
    @State private var confirmReset = false

    var body: some View {
        Pane {
            Section {
                Picker("Front matter", selection: store.binding(\.frontMatter, "frontMatter")) {
                    Text("Table").tag("table")
                    Text("Hidden").tag("hide")
                    Text("Raw").tag("raw")
                }
                Picker("Table of contents", selection: store.binding(\.toc, "toc")) {
                    Text("Automatic").tag("auto")
                    Text("Always").tag("on")
                    Text("Never").tag("off")
                }
                Toggle("Show word count and reading time", isOn: store.binding(\.stats, "stats"))
                Toggle("Render math", isOn: store.binding(\.math, "math"))
                Toggle("Render Mermaid diagrams", isOn: store.binding(\.mermaid, "mermaid"))
            } header: {
                Text("Rendering")
            } footer: {
                Text("Automatic shows a table of contents for documents with three or more headings. Math uses $…$ and $$…$$ delimiters.")
                    .settingsFooter()
            }

            Section {
                Picker("Raw HTML", selection: store.binding(\.rawHTML, "rawHTML")) {
                    Text("Off").tag("off")
                    Text("Sanitized").tag("sanitized")
                }
                .pickerStyle(.segmented)
                Toggle("Load remote images", isOn: store.binding(\.remoteImages, "remoteImages"))
            } header: {
                Text("Content")
            } footer: {
                Text("Sanitized HTML keeps formatting tags but never runs scripts. Remote images are off by default: fetching one lets its server see when the document was opened. A blocked image offers to load that document's images once, without changing this setting.")
                    .settingsFooter()
            }

            Section {
                LabeledContent("Location") {
                    Text(abbreviated(SettingsFile.url.path))
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
                Text("The file can be edited by hand; changes appear here and in open previews right away.")
                    .settingsFooter()
            }
        }
        .confirmationDialog("Reset all settings to their defaults?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive) { store.resetToDefaults() }
        } message: {
            Text("Theme, fonts, folder, editing and rendering settings go back to how spacebar comes. custom.css and your themes are not changed.")
        }
    }

    private func abbreviated(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

extension View {
    func settingsFooter() -> some View {
        font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
