import Cocoa
import WebKit
import os

let vlog = Logger(subsystem: logSubsystem, category: "viewer")

/// An ordinary window: it opens over Finder without taking the keyboard, so Finder's arrows move the selection it follows,
/// and once clicked into it is the active app's key window and takes its own keys (`keyDown` → `Viewer.route`).
/// Its traffic lights sit centred in the page's top row beside the sidebar button, as Finder's sit in its toolbar; AppKit lays
/// them out for a 28 pt title bar, so they are moved after each of its layouts. The web view takes every click in the title
/// bar and never moves the window, so the page says when the pointer is over empty chrome (`dragZone`), and a press there
/// drags the panel.
final class ViewerPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    /// The page's top row: `--bar-h` in base.css.
    static let rowHeight: CGFloat = 40
    static let lightsLeft: CGFloat = 12
    /// A press this far below the top never drags, whatever the page last said.
    static let dragDepth: CGFloat = 96
    var dragZone = false

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backing, defer: flag)
        // A resize lays the buttons out again just before this notification, so moving them here never shows.
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: self, queue: nil) { [weak self] _ in self?.placeLights() }
        // Any other layout. A move from inside AppKit's own setFrame does not stick, so it waits for the next turn.
        for kind in [NSWindow.ButtonType.closeButton, .zoomButton] {
            guard let b = standardWindowButton(kind) else { continue }
            b.postsFrameChangedNotifications = true
            NotificationCenter.default.addObserver(forName: NSView.frameDidChangeNotification, object: b, queue: nil) { [weak self] _ in
                DispatchQueue.main.async { self?.placeLights() }
            }
        }
        placeLights()
    }

    func placeLights() {
        guard let close = standardWindowButton(.closeButton), let mini = standardWindowButton(.miniaturizeButton) else { return }
        let at = close.convert(close.bounds, to: nil)
        let dx = Self.lightsLeft - at.minX, dy = frame.height - (Self.rowHeight + at.height) / 2 - at.minY
        if abs(dx) > 0.5 || abs(dy) > 0.5 {
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let b = standardWindowButton(kind) else { continue }
                b.setFrameOrigin(NSPoint(x: b.frame.minX + dx, y: b.frame.minY + (b.superview?.isFlipped == true ? -dy : dy)))
            }
        }
        _ = mini
    }

    /// A plain press on the page's empty chrome: not on a traffic light, a native pane over the page, or the window's edges,
    /// where AppKit resizes it.
    func drags(_ event: NSEvent) -> Bool {
        let p = event.locationInWindow, edge: CGFloat = 4
        return event.type == .leftMouseDown && dragZone && !event.modifierFlags.contains(.control)
            && p.y > frame.height - Self.dragDepth && p.y < frame.height - edge && p.x > edge && p.x < frame.width - edge
            && contentView?.superview?.hitTest(p)?.isDescendant(of: WebHost.shared.web) == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isKeyWindow, let name = Self.keyName(event), Viewer.shared.windowKey(name, isRepeat: event.isARepeat) { return }
        guard drags(event) else { return super.sendEvent(event) }
        if event.clickCount == 2 {
            // As a title bar: the double-click action in Desktop & Dock settings.
            let action = UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") ?? "Maximize"
            if action == "Maximize" || action == "Fill" { zoom(nil) } else if action == "Minimize" { miniaturize(nil) }
        } else if event.clickCount < 2 {
            performDrag(with: event)
        }
    }

    /// The name the helper would have sent for this key (`KeyRoute`), so a key typed in the window does what it did when the
    /// helper routed it from Finder. Esc and ⌘W are the window's: Esc closes a popover, ⌘W the window.
    static func keyName(_ e: NSEvent) -> String? {
        var mods: HelperMods = []
        if e.modifierFlags.contains(.command) { mods.insert(.command) }
        if e.modifierFlags.contains(.option) { mods.insert(.option) }
        if e.modifierFlags.contains(.control) { mods.insert(.control) }
        if e.modifierFlags.contains(.shift) { mods.insert(.shift) }
        let k = KeyEvent(code: Int64(e.keyCode), chars: (e.charactersIgnoringModifiers ?? "").lowercased(), isRepeat: e.isARepeat, mods: mods)
        if mods.isEmpty, k.code == KeyCode.escape { return HelperKeys.escape }
        if mods == .command, k.chars == "w" { return "closeWindow" }
        return KeyRoute.forwarded(k, sidebarKeys: true)
    }

    override func orderOut(_ sender: Any?) {
        dragZone = false
        WebHost.shared.web.evaluateJavaScript("window.sb && sb.dragReset && sb.dragReset(); 0")
        super.orderOut(sender)
    }
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

    override var preferredSize: NSSize? { nil }

    /// Named for VoiceOver and window lists; the title itself is never drawn.
    override func pageRendered() {
        super.pageRendered()
        view.window?.title = shownName
    }

    override func htmlScripts(for url: URL) -> String {
        spaced.contains(url.resolvingSymlinksInPath().path) ? "off" : super.htmlScripts(for: url)
    }

    override func copyFileAndText(_ url: URL, _ text: String) -> Bool { FinderCopy.write(file: url, text: text) }

    override func writerKeysChanged(_ held: Bool) { Viewer.shared.tellTextSession(held) }

    override func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "popover":
            Viewer.shared.tellPopover(PageMessage(body: body).bool("open") == true)
        case "dragZone":
            (view.window as? ViewerPanel)?.dragZone = PageMessage(body: body).bool("on") == true
        case "dragOut":
            // A file dragged out of the panel: only one the page may open (dragOutFile), from a press the user is still making.
            guard let url = dragOutFile(body), let web = webView as? PreviewWebView else {
                return vlog.error("refused dragOut: not a listed file")
            }
            if let why = web.beginFileDrag(url, source: self) { vlog.error("refused dragOut: \(why, privacy: .public)") }
        default:
            super.handle(type, body)
        }
    }
}

extension PanelController: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? .copy : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        (webView as? PreviewWebView)?.fileDragEnded()
        js("sb.dragOutEnded", [:])
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
    /// The writer's key panel holds the keyboard; the helper is told, so it passes the typing's keys.
    private(set) var textSession = false
    /// One of the page's popovers is open, as the page last said; the helper is told, so Esc closes it rather than the panel.
    private var popover = false

    override init() {
        panel = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .normal
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.minSize = NSSize(width: 480, height: 320)
        panel.delegate = self
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged = Date()
        }
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
        if open || suspended { hide(tell: false) }
        suspended = false
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

    func tellTextSession(_ held: Bool) {
        textSession = held
        helper()?.textSession(held) { ok in
            if !ok { vlog.error("helper refused text session \(held)") }
        }
    }

    /// The helper forgets the popover whenever the panel closes; `announce` tells it again for a panel that shows one.
    func tellPopover(_ open: Bool) {
        guard open != popover else { return }
        popover = open
        helper()?.popover(open)
    }

    // MARK: SpacebarViewerProtocol

    func show(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void) {
        // Answered from the main thread: a reply proves the panel can be drawn now, not just that the process is alive.
        DispatchQueue.main.async {
            reply(true)
            self.present(paths.filter { $0.hasPrefix("/") }.prefix(1000).map { URL(fileURLWithPath: $0) }, id: requestID)
        }
    }

    func key(_ name: String, isRepeat: Bool) {
        guard HelperKeys.all.contains(name) else { return }
        DispatchQueue.main.async { if self.open { self.route(name, isRepeat: isRepeat) } }
    }

    func focus() {
        DispatchQueue.main.async {
            guard self.open else { return }
            if self.panel.isMiniaturized { self.panel.deminiaturize(nil) }
            NSApp.activate(ignoringOtherApps: true)
            self.panel.makeKeyAndOrderFront(nil)
        }
    }

    /// A key typed in the window, which is key: what the helper would have routed from Finder. False leaves it to the page.
    func windowKey(_ name: String, isRepeat: Bool) -> Bool {
        guard open, !textSession else { return false }
        if name == "closeWindow" { panel.performClose(nil); return true }
        if name == HelperKeys.escape {
            guard popover else { return false }
            route(name, isRepeat: isRepeat)
            return true
        }
        route(name, isRepeat: isRepeat)
        return true
    }

    func close() {
        DispatchQueue.main.async {
            self.hide(tell: true)
            self.suspended = false
        }
    }

    func suspend() {
        DispatchQueue.main.async {
            guard self.open else { return }
            self.controller.hostSuspending()
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
            self.panel.alphaValue = 1
            self.panel.ignoresMouseEvents = false
            self.panel.orderFrontRegardless()
            self.open = true
            self.controller.hostAppeared()
            self.announce(requestID)
        }
    }

    func gesture(_ data: Data) {
        DispatchQueue.main.async { if self.open { self.sendGesture(data) } }
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    /// Gestures the helper handed over that reached an open panel.
    private(set) var gesturesSent = 0
    private static let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocation.self) }

    /// Rebuilds the gesture for the panel's window, at the pointer's place in it, and hands it to the window, which gives it to
    /// the view under the pointer: NSApp.sendEvent would drop it, the viewer not being active.
    private func sendGesture(_ data: Data) {
        gesturesSent += 1
        guard let cg = CGEvent(withDataAllocator: nil, data: data as CFData), [29, 30, 32].contains(cg.type.rawValue),
              let place = Self.setWindowLocation, let top = NSScreen.screens.first?.frame.maxY else { return }
        let at = cg.location, f = panel.frame
        cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(panel.windowNumber))
        place(cg, CGPoint(x: at.x - f.minX, y: at.y - (top - f.maxY)))
        guard let e = NSEvent(cgEvent: cg) else { return }
        panel.sendEvent(e)
    }

    // MARK: The panel

    private func present(_ urls: [URL], id: Int) {
        guard !urls.isEmpty else { return decline(id, "no paths") }
        if suspended { hide(tell: false) }
        suspended = false
        idle?.cancel()
        request = id
        controller.spaced = Set(urls.map { $0.resolvingSymlinksInPath().path })
        controller.onReady = { [weak self] _ in self?.ready(id) }
        controller.onDecline = { [weak self] why in self?.decline(id, why) }
        if open, !panel.isVisible || panel.isMiniaturized {
            if panel.isMiniaturized { panel.deminiaturize(nil) }
            panel.orderFrontRegardless()
        }
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
        guard id == request, panel.isVisible else { return }
        // A show that replaced an open panel's file is answered too, or the helper holds it pending until its 5 s check.
        if open { return announce(id) }
        reveal(id)
    }

    /// Makes the panel, already ordered in, visible and tells the helper once the window server has it.
    private func reveal(_ id: Int) {
        // In the Dock and ⌘Tab while a window is open, as an app is.
        NSApp.setActivationPolicy(.regular)
        controller.hostWillAppear()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        open = true
        controller.hostAppeared()
        announce(id)
    }

    private func announce(_ id: Int) {
        // After this turn of the run loop, once the window server has the panel's first visible frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.open, self.request == id else { return }
            self.helper()?.panelState(true, requestID: id, windowNumber: self.panel.windowNumber)
            if self.popover { self.helper()?.popover(true) }
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
        // A suspend has let go of the keys already (hostSuspending) and keeps the native views for restore.
        if blank, open || suspended { controller.hostDisappearing() }
        let was = open || panel.isVisible
        open = false
        panel.ignoresMouseEvents = true
        // A suspended panel is out of the window list: it comes back in, unseen, so that WebKit draws the empty page.
        if blank, was || suspended {
            panel.alphaValue = 0
            if !panel.isVisible { panel.orderFrontRegardless() }
            let out = { [weak self] in
                guard let self, self.request == 0, !self.open else { return }
                self.panel.orderOut(nil)
            }
            controller.webView.callAsyncJavaScript("if (window.sb && sb.blank) sb.blank(); await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)))",
                                                   arguments: [:], in: nil, in: .page) { _ in out() }
            // Should WebKit not draw a frame (the page still loading), the panel still goes.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: out)
        } else {
            panel.orderOut(nil)
        }
        if tell && was { helper()?.panelState(false, requestID: id, windowNumber: 0) }
        if was { NSApp.setActivationPolicy(.accessory) }
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
        if name == "copy" {
            if controller.copyNativeSelection() { return }
            controller.armCopy()
        }
        if controller.zoomKey(name) || controller.scrollKey(name) { return }
        let web = controller.webView
        let arg = String(data: try! JSONSerialization.data(withJSONObject: ["key": name]), encoding: .utf8)!
        web.evaluateJavaScript("sb.hostKey && sb.hostKey(\(arg))") { r, _ in
            guard (r as? Bool) != true else { return }
            switch name {
            // No popover was open after all (the page's word was stale): Esc closes the panel, as it does otherwise.
            case HelperKeys.escape: self.hide(tell: true)
            case "zoomIn": web.pageZoom = min(web.pageZoom * 1.1, 3)
            case "zoomOut": web.pageZoom = max(web.pageZoom / 1.1, 0.5)
            case "zoomReset": web.pageZoom = 1
            // Nothing to copy as text (an image, a PDF): the file itself, as Finder's ⌘C would have.
            case "copy": self.controller.copyFileOnScreen()
            default: break
            }
        }
    }

    /// On the screen Finder's front window is on: where the panel last was on that screen, else `PanelFrame`'s default.
    private func place() {
        if let f = Self.parkedFrame { return panel.setFrame(f, display: false) }
        guard let screen = Self.finderScreen() ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        else { return }
        let saved = PanelFrame.key(for: screen).flatMap { PanelFrame.load($0) }.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
        panel.setFrame(PanelFrame.placement(saved: saved, visible: screen.visibleFrame, minSize: panel.minSize), display: false)
    }

    /// A move or resize the user made while the panel is open, kept for the screen it ended on, relative to that screen so a
    /// rearrangement of the displays does not strand it. AppKit moving the panel off a display that went away is not kept.
    private func remember() {
        guard open, Self.parkedFrame == nil, !panel.inLiveResize, -screensChanged.timeIntervalSinceNow > 2,
              let screen = panel.screen, let key = PanelFrame.key(for: screen) else { return }
        PanelFrame.save(panel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), key)
    }
    private var screensChanged = Date.distantPast

    func windowDidMove(_ notification: Notification) { remember(); reportFrame() }
    func windowDidResize(_ notification: Notification) { remember(); reportFrame() }

    /// So the helper places a pinch by where the panel is now, not where its last check found it.
    private func reportFrame() {
        guard open, let top = NSScreen.screens.first?.frame.maxY else { return }
        let f = panel.frame
        helper()?.panelMoved(x: f.minX, y: top - f.maxY, width: f.width, height: f.height, windowNumber: panel.windowNumber)
    }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

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
