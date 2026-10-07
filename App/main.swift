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
        // First: a copy on spacebar.dmg or translocated writes no settings and registers nothing before it is moved.
        if MoveToApplications.offerIfNeeded() { return }
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

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { !MoveToApplications.active }

    func applicationShouldHandleReopen(_ app: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows, !MoveToApplications.active { showSettings() }
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // The user may have changed extensions in System Settings meanwhile.
        if window?.window?.isVisible == true { system.refresh() }
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
