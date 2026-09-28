import AppKit
import SwiftUI

/// The first launch's sheet over the settings window: what spacebar does and a sample folder to try it on. Shown until it is
/// dismissed once (welcomeShown); SPACEBAR_NO_WELCOME=1 skips it for screenshots of a development build.
enum Welcome {
    static func presentIfNeeded(over window: NSWindow?, store: SettingsStore) {
        guard let window, !store.settings.welcomeShown, window.attachedSheet == nil,
              ProcessInfo.processInfo.environment["SPACEBAR_NO_WELCOME"] != "1" else { return }
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let done = { [weak window, weak sheet] in
            store.set("welcomeShown", true)
            if let sheet { window?.endSheet(sheet) }
        }
        let host = NSHostingController(rootView: WelcomeView(done: done))
        host.sizingOptions = [.preferredContentSize]
        sheet.contentViewController = host
        window.beginSheet(sheet)
    }
}

struct WelcomeView: View {
    let done: () -> Void
    @State private var problem: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
                Button("Settings") { done() }
                    .help("Close this and show spacebar’s settings")
                Spacer()
                Button("Try It") { tryIt() }
                    .keyboardShortcut(.defaultAction)
                    .help("Make a sample folder and show it in Finder, ready for Space")
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func tryIt() {
        switch SampleFolder.create() {
        case .success(let dir):
            NSWorkspace.shared.activateFileViewerSelecting([dir])
            done()
        case .failure(let e):
            problem = "Couldn’t make the sample folder: \(e.localizedDescription)"
        }
    }
}
