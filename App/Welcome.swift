import AppKit
import SwiftUI

/// The first launch's sheet over the settings window: what spacebar does and a sample folder to try it on, then the offer of
/// the Space helper. The introduction shows until it is dismissed once (welcomeShown); the offer once (helperOffered), so an
/// upgrade that already dismissed the introduction sees only the offer. SPACEBAR_NO_WELCOME=1 skips both for screenshots of a
/// development build.
enum Welcome {
    static func presentIfNeeded(over window: NSWindow?, store: SettingsStore, system: SystemStatus) {
        let steps = store.settings.welcomeSteps(helperAvailable: HelperAgent.available)
        guard let window, let first = steps.first, window.attachedSheet == nil,
              ProcessInfo.processInfo.environment["SPACEBAR_NO_WELCOME"] != "1" else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let done = { [weak window, weak sheet] in
            store.set("welcomeShown", true)
            if let sheet { window?.endSheet(sheet) }
        }
        let view = WelcomeView(steps: steps, step: first, done: done).environmentObject(store).environmentObject(system)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var store: SettingsStore
    @EnvironmentObject var system: SystemStatus
    let steps: [WelcomeStep]
    @State var step: WelcomeStep
    let done: () -> Void
    @State private var problem: String?
    /// Try It was clicked on the introduction: the sample folder is shown once the helper's offer is answered.
    @State private var tryItAfter = false
    @State private var turnedOn = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch step {
            case .intro: intro
            case .helper: helper
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private var intro: some View {
        Group {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Press Space on a folder").font(.title2.weight(.semibold))
                    Text("spacebar previews it in Quick Look, with its files in a sidebar.").foregroundColor(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("spacebar opens").font(.headline)
                Text(QuickLookClaims.summary + ".").fixedSize(horizontal: false, vertical: true)
                Text("Select one in Finder and press Space. Inside a folder preview, every file opens from the sidebar.")
                    .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let problem { Text(problem).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("Not Now") { next(tryIt: false) }
                    .help("Skip the sample folder")
                Spacer()
                Button("Try It") { next(tryIt: true) }
                    .keyboardShortcut(.defaultAction)
                    .help("Make a sample folder and show it in Finder, ready for Space")
            }
        }
    }

    private var helper: some View {
        Group {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 48, height: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use spacebar for every file").font(.title2.weight(.semibold))
                    Text("Optional").foregroundColor(.secondary)
                }
            }
            Text("Space in Finder can open spacebar for any file you select, images, PDFs and video included, not only the types Quick Look hands it.")
                .fixedSize(horizontal: false, vertical: true)
            Text("The Space helper needs Accessibility, listed there as \(HelperCopy.accessibilityName), which lets spacebar notice when you press Space in Finder and read which file is selected. It never reads what you type anywhere else. You can turn it off in Settings.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("macOS will ask you to allow it in two places: Login Items, then Accessibility.")
                .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            Link("How spacebar uses this", destination: HelperCopy.securityURL)
            if turnedOn { progress }
            if let problem { Text(problem).foregroundColor(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if turnedOn {
                    Spacer()
                    Button("Done") { finish() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("Skip") { finish() }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("Turn On") { turnOn() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .onAppear { store.set("helperOffered", true) }
    }

    @ViewBuilder private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                StatusDot(color: HelperCopy.color(system.helper))
                Group {
                    switch system.helper {
                    case .on: Text("On: press Space on any file in Finder")
                    case .secureInput: Text("On. \(HelperCopy.title(.secureInput, owner: system.secureInputOwner)).")
                    case .needsAccessibility: Text("Waiting for Accessibility: turn on \(HelperCopy.accessibilityName)…")
                    case .needsLoginItems: Text("Waiting for Login Items…")
                    case .notRunning: Text(system.reregistering ? "Restarting…" : "macOS did not start it.")
                    case .off, .starting: Text("Starting…")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            switch system.helper {
            case .needsAccessibility: Button("Open Accessibility Settings") { HelperAgent.openAccessibility() }.buttonStyle(.link)
            case .needsLoginItems: Button("Open Login Items Settings") { HelperAgent.openLoginItems() }.buttonStyle(.link)
            case .notRunning: Button("Try Again") { system.reregister() }.disabled(system.reregistering)
            default: EmptyView()
            }
        }
    }

    private func next(tryIt: Bool) {
        tryItAfter = tryIt
        if let i = steps.firstIndex(of: step), i + 1 < steps.count {
            step = steps[i + 1]
        } else {
            finish()
        }
    }

    private func turnOn() {
        turnedOn = true
        system.watchHelper()
        system.setHelper(true, store: store)
    }

    private func finish() {
        if tryItAfter {
            switch SampleFolder.create() {
            case .success(let dir): NSWorkspace.shared.activateFileViewerSelecting([dir])
            case .failure(let e):
                problem = "Couldn’t make the sample folder: \(e.localizedDescription)"
                tryItAfter = false
                return
            }
        }
        if turnedOn { system.unwatchHelper() }
        done()
    }
}
