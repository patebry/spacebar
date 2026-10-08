import Cocoa

WebHost.pageHost = "panel"

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Viewer.shared.start() }
    /// May come before launching finishes.
    func application(_ application: NSApplication, open urls: [URL]) { Viewer.shared.openDocuments(urls) }
}

/// The menu bar while a window makes the viewer an ordinary app: Quit, and the Window menu's Minimize, Zoom and Close.
func viewerMenu() -> NSMenu {
    let main = NSMenu()
    let appMenu = NSMenu(title: "spacebar")
    appMenu.addItem(withTitle: "Hide spacebar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit spacebar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    main.addItem(withTitle: "spacebar", action: nil, keyEquivalent: "").submenu = appMenu
    let window = NSMenu(title: "Window")
    window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    window.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    window.addItem(.separator())
    window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
    NSApp.windowsMenu = window
    return main
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.mainMenu = viewerMenu()
app.setActivationPolicy(.accessory)
app.run()
