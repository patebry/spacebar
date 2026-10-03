import AppKit
import SwiftUI

@main
enum SpacebarApp {
    static func main() {
        // Before the settings store first touches the support folder.
        SettingsFile.migrateLegacySupportDir()
        if let code = HelperAgent.commandLine(CommandLine.arguments) { exit(code) }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = SettingsStore()
    let system = SystemStatus()
    private var window: SettingsWindowController?
    /// A tab asked for by a URL that arrived before the window existed (a cold launch through spacebar-md://).
    private var pendingTab: SettingsTab?

    func applicationWillFinishLaunching(_ note: Notification) {
        // Registered before launch finishes, so the URL that launched the app is not missed.
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(handleGetURL(_:reply:)),
                                                     forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
        NSApp.setActivationPolicy(.regular)
        NSApp.mainMenu = MainMenu.make()
        switch ProcessInfo.processInfo.environment["SPACEBAR_APPEARANCE"] {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        store.start()
        // Queued before the settings window's first refresh, which then shows the extensions registered.
        system.registerIfNew()
        system.checkHelperAtLaunch()
        var tab = pendingTab ?? ProcessInfo.processInfo.environment["SPACEBAR_INITIAL_TAB"].flatMap { SettingsTab(rawValue: $0.lowercased()) }
        for arg in CommandLine.arguments.dropFirst() {
            if let u = URL(string: arg), let t = SettingsTab(url: u) { tab = t }
        }
        showSettings(tab ?? .general)
        Welcome.presentIfNeeded(over: window?.window, store: store, system: system)
        // For screenshots of a development build started from a shell, which macOS otherwise leaves in the background.
        if ProcessInfo.processInfo.environment["SPACEBAR_ACTIVATE"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                NSApp.activate(ignoringOtherApps: true)
                self?.window?.window?.makeKeyAndOrderFront(nil)
            }
        }
    }

    @objc private func handleGetURL(_ event: NSAppleEventDescriptor, reply: NSAppleEventDescriptor) {
        guard let s = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue, let url = URL(string: s),
              let tab = SettingsTab(url: url) else { return }
        if window == nil { pendingTab = tab } else { showSettings(tab) }
    }

    func showSettings(_ tab: SettingsTab? = nil) {
        if window == nil { window = SettingsWindowController(store: store, system: system) }
        if let tab { window?.select(tab) }
        window?.showWindow(nil)
        window?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        system.refresh()
    }

    @objc func showSettingsWindow(_ sender: Any?) { showSettings() }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showSettings() }
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // The user may have changed extensions in System Settings meanwhile.
        if window?.window?.isVisible == true { system.refresh() }
    }
}

/// The settings window: one page at a fixed width, with a height that follows it (Advanced opening and closing, a notice
/// appearing) up to what the screen allows; past that the page scrolls.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let store: SettingsStore
    private let host: NSHostingController<AnyView>
    private var sizeObservation: NSKeyValueObservation?

    init(store: SettingsStore, system: SystemStatus) {
        self.store = store
        host = NSHostingController(rootView: AnyView(SettingsPane().environmentObject(store).environmentObject(system)))
        host.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: paneWidth, height: 400),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.contentViewController = host
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.title = "spacebar Settings"
        super.init(window: window)
        window.delegate = self
        fitWindow(animated: false)
        window.center()
        window.setFrameAutosaveName("Settings")
        sizeObservation = host.observe(\.preferredContentSize) { [weak self] _, _ in
            DispatchQueue.main.async { self?.fitWindow(animated: self?.window?.isVisible == true) }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func select(_ tab: SettingsTab) {
        store.revealAdvanced(tab.opensAdvanced)
    }

    /// Resizes the window to the page's natural height, keeping its top edge where it is.
    func fitWindow(animated: Bool) {
        guard let window else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame.height ?? 800
        let natural = host.preferredContentSize.height > 0 ? host.preferredContentSize.height : host.view.fittingSize.height
        let height = min(max(natural, 200), screen - 140, 900)
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: paneWidth, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        guard frame != window.frame else { return }
        window.setFrame(frame, display: true, animate: animated)
    }
}

enum MainMenu {
    static func make() -> NSMenu {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? "spacebar"
        let main = NSMenu()

        let app = NSMenu(title: name)
        app.addItem(withTitle: "About \(name)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(AppDelegate.showSettingsWindow(_:)), keyEquivalent: ",")
        app.addItem(.separator())
        let services = NSMenu(title: "Services")
        app.addItem(withTitle: "Services", action: nil, keyEquivalent: "").submenu = services
        NSApp.servicesMenu = services
        app.addItem(.separator())
        app.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
            .keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(withTitle: name, action: nil, keyEquivalent: "").submenu = app

        let file = NSMenu(title: "File")
        file.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(withTitle: "File", action: nil, keyEquivalent: "").submenu = file

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "").submenu = edit

        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        window.addItem(.separator())
        window.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        NSApp.windowsMenu = window

        return main
    }
}
