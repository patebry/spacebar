import Cocoa
import WebKit
import os

let vlog = Logger(subsystem: logSubsystem, category: "viewer")

/// Floats over Finder without taking the keyboard: Finder stays key, and the helper routes its keys here.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The list session without the writer: the helper sends the keys, so nothing needs a key window. Filter and edit sessions
/// still use the writer's key panel.
final class TapKeySource: KeySource {
    weak var controller: PreviewController?
    private(set) var session: Int?
    var local: Bool { true }

    func listSessionWanted(root: String) { controller?.js("sb.listKeysWanted", ["root": root]) }

    func beginList(_ id: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, failed: @escaping () -> Void) {
        session = id
    }

    func end(_ id: Int) { if session == id { session = nil } }

    /// Hands a routed key to the list session; false when none holds the keys or it has no use for this one.
    func key(_ name: String, isRepeat: Bool) -> Bool {
        guard let id = session, let c = controller, FilterKeys.listNames.contains(name) else { return false }
        c.filterKey(id, key: name, isRepeat: isRepeat)
        return true
    }
}

final class PanelController: PreviewController {
    /// What Space opened: an HTML file among them never runs scripts, whatever the setting says for one reached in the sidebar.
    var spaced: Set<String> = []

    override func htmlScripts(for url: URL) -> String {
        spaced.contains(url.resolvingSymlinksInPath().path) ? "off" : super.htmlScripts(for: url)
    }
}

final class Viewer: NSObject, SpacebarViewerProtocol, NSWindowDelegate {
    static let shared = Viewer()
    static let idleExit: TimeInterval = 30 * 60

    private var conn: NSXPCConnection?
    private var retries = 0
    let panel: ViewerPanel
    let controller = PanelController()
    let keys = TapKeySource()
    /// Where the panel opens instead of over Finder's window (a harness parks it off screen).
    static var parkedFrame: NSRect?
    /// The request on screen, or on its way there; 0 when closed.
    private var request = 0
    private var open = false
    /// Ordered out while another app is in front, keeping what it shows until Finder comes back (`restore`).
    private var suspended = false
    private var idle: DispatchWorkItem?

    override init() {
        panel = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.minSize = NSSize(width: 480, height: 320)
        panel.delegate = self
        keys.controller = controller
        controller.keySource = keys
        panel.contentViewController = controller
    }

    func start() {
        connect()
        armIdle()
        WebHost.shared.whenReady { WebHost.shared.web.evaluateJavaScript("sb.warm && sb.warm(); 0") }
    }

    // MARK: The helper

    private func connect() {
        guard let req = HelperSigning.helperRequirement() else {
            vlog.error("unsigned build: the helper cannot be verified")
            exit(1)
        }
        let c = NSXPCConnection(machServiceName: HelperIDs.machService, options: [])
        c.remoteObjectInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
        c.exportedInterface = NSXPCInterface(with: SpacebarViewerProtocol.self)
        c.exportedObject = self
        c.setCodeSigningRequirement(req)
        c.invalidationHandler = { DispatchQueue.main.async { self.lost() } }
        c.interruptionHandler = { DispatchQueue.main.async { self.lost() } }
        c.resume()
        conn = c
        helper()?.hello { ok in
            DispatchQueue.main.async {
                vlog.info("hello: \(ok)")
                if ok { self.retries = 0 }
            }
        }
    }

    /// Without the helper nothing can ask for a panel: a few tries (launchd may be restarting it), then exit.
    private func lost() {
        guard conn != nil else { return }
        conn?.invalidate()
        conn = nil
        suspended = false
        if open { hide(tell: false) }
        retries += 1
        guard retries <= 5 else {
            vlog.info("helper unreachable: exiting")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(retries)) { self.connect() }
    }

    private func helper() -> SpacebarHelperProtocol? {
        conn?.remoteObjectProxyWithErrorHandler { err in vlog.error("helper call failed: \(err.localizedDescription, privacy: .public)") } as? SpacebarHelperProtocol
    }

    // MARK: SpacebarViewerProtocol

    func show(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void) {
        // Answered from the main thread: a reply proves the panel can be drawn now, not just that the process is alive.
        DispatchQueue.main.async {
            reply(true)
            self.present(paths.filter { $0.hasPrefix("/") }.prefix(1000).map { URL(fileURLWithPath: $0) }, id: requestID)
        }
    }

    func key(_ name: String, isRepeat: Bool, mods: Int) {
        guard HelperKeys.all.contains(name) else { return }
        DispatchQueue.main.async { if self.open { self.route(name, isRepeat: isRepeat) } }
    }

    func close() {
        DispatchQueue.main.async {
            self.suspended = false
            self.hide(tell: true)
        }
    }

    func suspend() {
        DispatchQueue.main.async {
            guard self.open else { return }
            self.hide(tell: false, blank: false)
            self.suspended = true
        }
    }

    func restore(_ requestID: Int, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            guard self.suspended, !self.open, self.request == 0 else { return reply(false) }
            reply(true)
            self.suspended = false
            self.idle?.cancel()
            self.request = requestID
            self.panel.orderFrontRegardless()
            self.reveal(requestID)
        }
    }

    // MARK: The panel

    private func present(_ urls: [URL], id: Int) {
        guard !urls.isEmpty else { return decline(id, "no paths") }
        suspended = false
        idle?.cancel()
        request = id
        controller.spaced = Set(urls.map { $0.resolvingSymlinksInPath().path })
        controller.onReady = { [weak self] _ in self?.ready(id) }
        controller.onDecline = { [weak self] why in self?.decline(id, why) }
        if !open {
            place()
            // In the window but invisible until the page has painted, so WebKit draws and nothing flashes.
            panel.alphaValue = 0
            panel.ignoresMouseEvents = true
            panel.orderFrontRegardless()
        }
        controller.start(selection: urls, reason: "space")
        // The controller reports ready within 3 s even for a slow file; past that something is stuck, and Apple takes over.
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
            guard let self, self.request == id, !self.open else { return }
            self.decline(id, "not ready in 4 s")
        }
    }

    private func ready(_ id: Int) {
        guard id == request, panel.isVisible, !open else { return }
        reveal(id)
    }

    /// Makes the panel, already ordered in, visible and tells the helper once the window server has it.
    private func reveal(_ id: Int) {
        controller.hostWillAppear()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        open = true
        controller.hostAppeared()
        // After this turn of the run loop, once the window server has the panel's first visible frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.open, self.request == id else { return }
            self.helper()?.panelState(true, requestID: id, windowNumber: self.panel.windowNumber)
        }
    }

    private func decline(_ id: Int, _ why: String) {
        guard id == request else { return }
        vlog.info("declined \(id): \(why, privacy: .public)")
        helper()?.declined(id)
        hide(tell: open)
    }

    /// `blank`: the page is emptied, and drawn so, before the panel is ordered out. The next show reveals the panel as soon as
    /// the page has laid out, which can be a frame before WebKit's drawing of it reaches the screen: that frame is then empty,
    /// never the last file's content. A panel suspended for `restore` keeps its content.
    private func hide(tell: Bool, blank: Bool = true) {
        let id = request
        request = 0
        if open { controller.hostDisappearing() }
        let was = open || panel.isVisible
        open = false
        panel.ignoresMouseEvents = true
        if blank, was {
            panel.alphaValue = 0
            controller.webView.callAsyncJavaScript("if (window.sb && sb.blank) sb.blank(); await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)))",
                                                   arguments: [:], in: nil, in: .page) { [weak self] _ in
                guard let self, self.request == 0, !self.open else { return }
                self.panel.orderOut(nil)
            }
        } else {
            panel.orderOut(nil)
        }
        if tell && was { helper()?.panelState(false, requestID: id, windowNumber: 0) }
        armIdle()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(tell: true)
        return false
    }

    /// A viewer left closed for a while exits; the helper starts a fresh one.
    private func armIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.open, self.request == 0 else { return }
            vlog.info("idle: exiting")
            exit(0)
        }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleExit, execute: w)
    }

    private func route(_ name: String, isRepeat: Bool) {
        if keys.key(name, isRepeat: isRepeat) { return }
        if name == "open" { return controller.openOnScreen() }
        if controller.zoomKey(name) { return }
        let web = controller.webView
        let arg = String(data: try! JSONSerialization.data(withJSONObject: ["key": name]), encoding: .utf8)!
        web.evaluateJavaScript("sb.hostKey && sb.hostKey(\(arg))") { r, _ in
            guard (r as? Bool) != true else { return }
            switch name {
            case "zoomIn": web.pageZoom = min(web.pageZoom * 1.1, 3)
            case "zoomOut": web.pageZoom = max(web.pageZoom / 1.1, 0.5)
            case "zoomReset": web.pageZoom = 1
            default: break
            }
        }
    }

    /// About 60% of the visible frame of the screen Finder's front window is on, between 640×480 and 1200×900, centred.
    private func place() {
        if let f = Self.parkedFrame { return panel.setFrame(f, display: false) }
        let screen = Self.finderScreen() ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = min(max(vf.width * 0.6, 640), 1200, vf.width), h = min(max(vf.height * 0.6, 480), 900, vf.height)
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral, display: false)
    }

    /// The screen of Finder's frontmost window; nil on the Desktop, which has none.
    static func finderScreen() -> NSScreen? {
        guard let finder = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return nil }
        for w in info where w[kCGWindowOwnerPID as String] as? pid_t == finder.processIdentifier && w[kCGWindowLayer as String] as? Int == 0 {
            guard let d = w[kCGWindowBounds as String] as? NSDictionary, let b = CGRect(dictionaryRepresentation: d), b.width > 80 else { continue }
            let centre = NSPoint(x: b.midX, y: primary.frame.maxY - b.midY)
            return NSScreen.screens.first { $0.frame.contains(centre) }
        }
        return nil
    }
}
