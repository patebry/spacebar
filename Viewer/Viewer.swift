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
    /// An NSPanel closes on Esc; a window the user has clicked into stays until ⌘W or its close button. (Esc in Finder closes
    /// one nobody has clicked into: the helper decides that.)
    override func cancelOperation(_ sender: Any?) {}
    /// The page's top row: `--bar-h` in base.css.
    static let rowHeight: CGFloat = 40
    static let lightsLeft: CGFloat = 12
    /// A press this far below the top never drags, whatever the page last said.
    static let dragDepth: CGFloat = 96
    var dragZone = false
    weak var owner: ViewerWindow?

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
            && owner.map { contentView?.superview?.hitTest(p)?.isDescendant(of: $0.controller.webView) == true } == true
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, isKeyWindow, let name = Self.keyName(event), owner?.windowKey(name, isRepeat: event.isARepeat) == true { return }
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
        owner?.controller.webView.evaluateJavaScript("window.sb && sb.dragReset && sb.dragReset(); 0")
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
    weak var owner: ViewerWindow?

    override var preferredSize: NSSize? { nil }

    /// Named for VoiceOver, the Window menu and Mission Control; the title itself is never drawn.
    override func pageRendered() {
        super.pageRendered()
        view.window?.title = shownName
    }

    override func htmlScripts(for url: URL) -> String {
        spaced.contains(url.resolvingSymlinksInPath().path) ? "off" : super.htmlScripts(for: url)
    }

    override func copyFileAndText(_ url: URL, _ text: String) -> Bool { FinderCopy.write(file: url, text: text) }

    override func writerKeysChanged(_ held: Bool) {
        owner?.textSession = held
        if owner === Viewer.shared.current { Viewer.shared.tellTextSession(held) }
    }

    override func handle(_ type: String, _ body: [String: Any]) {
        switch type {
        case "popover":
            owner?.setPopover(PageMessage(body: body).bool("open") == true)
        case "dragZone":
            (view.window as? ViewerPanel)?.dragZone = PageMessage(body: body).bool("on") == true
        case "dragOut":
            // A file dragged out of the window: only one the page may open (dragOutFile), from a press the user is still making.
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

/// One window: its own page (WebHost), controller and list keys. The helper's requests reach the one it last opened
/// (`Viewer.current`); the others keep their files.
final class ViewerWindow: NSObject, NSWindowDelegate {
    let panel: ViewerPanel
    let controller = PanelController()
    let keys = TapKeySource()
    let host = WebHost()
    /// The request on screen, or on its way there; 0 when closed.
    private(set) var request = 0
    private(set) var open = false
    /// The writer's key panel holds the keyboard for this window.
    var textSession = false
    /// One of the page's popovers is open, as the page last said: Esc closes it.
    private(set) var popover = false
    /// Gestures the helper handed over that reached this window while open.
    private(set) var gesturesSent = 0
    /// Opened as a document (Finder, another app), not by the helper, which never follows or closes it.
    var document = false

    override init() {
        panel = ViewerPanel(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        super.init()
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.level = .normal
        panel.hidesOnDeactivate = false
        // The green button takes it full screen, in its own space, as Preview's windows do.
        panel.collectionBehavior = [.fullScreenPrimary]
        panel.isReleasedWhenClosed = false
        panel.minSize = NSSize(width: 480, height: 320)
        panel.delegate = self
        panel.owner = self
        controller.webHost = host
        controller.owner = self
        keys.controller = controller
        controller.keySource = keys
        panel.contentViewController = controller
        host.whenReady { [weak self] in
            self?.host.web.evaluateJavaScript("sb.warm && sb.warm(); 0") { _, _ in self?.prepaint() }
        }
    }

    /// Has drawn a frame: WebKit's first paint in a new content process costs a Space 20 to 75 ms, so a spare pays it here.
    private var painted = false
    /// A full-screen window leaves full screen before it closes; this is the close to finish then.
    private var hideAfterFullScreen: Bool?

    /// Draws the warmed page once, out of sight, while the window is still a spare.
    private func prepaint() {
        guard !painted, !open, request == 0 else { return }
        painted = true
        // On screen and unseen, where the next Space will put it: off every screen, WebKit counts the page occluded and
        // draws nothing.
        place()
        panel.alphaValue = 0
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        let out = { [weak self] in
            guard let self, !self.open, self.request == 0 else { return }
            self.panel.orderOut(nil)
        }
        controller.webView.callAsyncJavaScript("await new Promise((r) => requestAnimationFrame(() => requestAnimationFrame(r)))",
                                               arguments: [:], in: nil, in: .page) { _ in out() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: out)
    }

    /// Closed and ready to take the next Space.
    var isSpare: Bool { !open && request == 0 && !closing }

    func setPopover(_ on: Bool) {
        guard on != popover else { return }
        popover = on
        if self === Viewer.shared.current { Viewer.shared.tellPopover(on) }
    }

    /// The selection this window was opened for, resolved as `spaced` holds it.
    func shows(_ urls: [URL]) -> Bool {
        (open || request != 0) && !closing && !controller.spaced.isEmpty && controller.spaced == Set(urls.map { $0.resolvingSymlinksInPath().path })
    }

    func focus() {
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        guard Viewer.activates else { return }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func present(_ urls: [URL], id: Int) {
        guard !urls.isEmpty else { return decline(id, "no paths") }
        // Hidden when its last window closed: shown again without taking the keyboard from Finder.
        if NSApp.isHidden { NSApp.unhideWithoutActivation() }
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
        armTimeout(id)
    }

    /// The controller reports ready within 3 s even for a slow file; past that something is stuck, and Apple takes over.
    /// A document (negative id) has no Apple to fall back on and may come with a cold launch: it waits longer, then shows
    /// whatever its page has.
    private func armTimeout(_ id: Int) {
        let doc = id < 0
        DispatchQueue.main.asyncAfter(deadline: .now() + (doc ? 15 : 4)) { [weak self] in
            guard let self, self.request == id, !self.open else { return }
            guard doc, self.host.ready, self.panel.isVisible else { return self.decline(id, "not ready in \(doc ? 15 : 4) s") }
            vlog.info("document \(id) not ready in 15 s: shown as it is")
            self.reveal(id)
        }
    }

    private func ready(_ id: Int) {
        guard id == request, panel.isVisible else { return }
        // A show that replaced an open window's file is answered too, or the helper holds it pending until its 5 s check.
        if open { return announce(id) }
        reveal(id)
    }

    private func reveal(_ id: Int) {
        painted = true
        controller.hostWillAppear()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        open = true
        controller.hostAppeared()
        Viewer.shared.windowsChanged()
        announce(id)
        if document { focus() }
    }

    /// Tells the helper this window is up for request `id`, once the window server has its first visible frame.
    func announce(_ id: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.open, self.request == id, self === Viewer.shared.current else { return }
            Viewer.shared.helper()?.panelState(true, requestID: id, windowNumber: self.panel.windowNumber)
            if self.popover { Viewer.shared.helper()?.popover(true) }
        }
    }

    /// Takes request `id` for a window already showing its file: the helper's following moves to it.
    func adopt(_ id: Int) {
        // The helper drives it from now on, with the helper's timeout.
        document = false
        request = id
        controller.onReady = { [weak self] _ in self?.ready(id) }
        controller.onDecline = { [weak self] why in self?.decline(id, why) }
        if open { announce(id) } else { armTimeout(id) }
    }

    private func decline(_ id: Int, _ why: String) {
        guard id == request else { return }
        vlog.info("declined \(id): \(why, privacy: .public)")
        if self === Viewer.shared.current { Viewer.shared.helper()?.declined(id) }
        // A document's only fallback is the app it would have opened in without spacebar.
        let file = id < 0 ? controller.spaced.first.map { URL(fileURLWithPath: $0) } : nil
        hide(tell: open)
        if let file { Viewer.handOff(file) }
    }

    /// The page is emptied, and drawn so, before the window is ordered out, so a reused window never shows the last file's
    /// content for a frame.
    func hide(tell: Bool) {
        // A window kept for reuse must not come back as an empty full-screen space, and one ordered out mid-transition can
        // strand one: it leaves full screen first (windowDidExitFullScreen).
        if panel.styleMask.contains(.fullScreen) {
            if hideAfterFullScreen == nil { panel.toggleFullScreen(nil) }
            hideAfterFullScreen = tell || hideAfterFullScreen == true
            return
        }
        let id = request
        request = 0
        document = false
        if open { controller.hostDisappearing() }
        let was = open || panel.isVisible
        open = false
        popover = false
        textSession = false
        panel.ignoresMouseEvents = true
        if was {
            panel.alphaValue = 0
            if !panel.isVisible { panel.orderFrontRegardless() }
            let out = { [weak self] in
                guard let self, self.request == 0, !self.open else { return }
                self.panel.orderOut(nil)
            }
            controller.webView.callAsyncJavaScript("if (window.sb && sb.blank) sb.blank(); await new Promise((r) => requestAnimationFrame(() => setTimeout(r, 0)))",
                                                   arguments: [:], in: nil, in: .page) { _ in out() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: out)
        } else {
            panel.orderOut(nil)
        }
        Viewer.shared.closed(self, request: id, tell: tell && was)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        hide(tell: true)
        return false
    }

    /// Closed while still going full screen, when AppKit ignores a toggle: it leaves again now.
    func windowDidEnterFullScreen(_ notification: Notification) {
        if hideAfterFullScreen != nil { panel.toggleFullScreen(nil) }
    }

    func windowDidFailToExitFullScreen(_ window: NSWindow) {
        hideAfterFullScreen = nil
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let tell = hideAfterFullScreen else { return }
        hideAfterFullScreen = nil
        hide(tell: tell)
    }

    /// Closing, but still leaving full screen: not a window to reuse yet.
    var closing: Bool { hideAfterFullScreen != nil }

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

    func route(_ name: String, isRepeat: Bool) {
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
            case "zoomIn": web.pageZoom = min(web.pageZoom * 1.1, 3)
            case "zoomOut": web.pageZoom = max(web.pageZoom / 1.1, 0.5)
            case "zoomReset": web.pageZoom = 1
            // Nothing to copy as text (an image, a PDF): the file itself, as Finder's ⌘C would have.
            case "copy": self.controller.copyFileOnScreen()
            default: break
            }
        }
    }

    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation")
        .map { unsafeBitCast($0, to: SetWindowLocation.self) }

    /// Rebuilds a gesture the helper handed over for this window, at the pointer's place in it, and hands it to the window,
    /// which gives it to the view under the pointer: NSApp.sendEvent would drop it while the viewer is not active.
    func sendGesture(_ data: Data) {
        gesturesSent += 1
        guard let cg = CGEvent(withDataAllocator: nil, data: data as CFData), [29, 30, 32].contains(cg.type.rawValue),
              let place = Self.setWindowLocation, let top = NSScreen.screens.first?.frame.maxY else { return }
        let at = cg.location, f = panel.frame
        cg.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(panel.windowNumber))
        place(cg, CGPoint(x: at.x - f.minX, y: at.y - (top - f.maxY)))
        guard let e = NSEvent(cgEvent: cg) else { return }
        panel.sendEvent(e)
    }

    /// On the screen Finder's front window is on: where a window last was on that screen, else `PanelFrame`'s default, moved
    /// down and right of any open window already there so each new one shows.
    private func place() {
        var frame: NSRect, bounds: NSRect?
        if let f = Viewer.parkedFrame {
            frame = f
        } else {
            guard let screen = Viewer.finderScreen() ?? NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
            else { return }
            let saved = PanelFrame.key(for: screen).flatMap { PanelFrame.load($0) }.map { $0.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY) }
            frame = PanelFrame.placement(saved: saved, visible: screen.visibleFrame, minSize: panel.minSize)
            bounds = screen.visibleFrame
        }
        // A window still on its way to the screen holds its frame too, so files opened together do not stack.
        let taken = Viewer.shared.windows.filter { $0 !== self && ($0.open || $0.request != 0) }.map { $0.panel.frame.origin }
        while taken.contains(where: { abs($0.x - frame.minX) < 2 && abs($0.y - frame.minY) < 2 }) {
            let next = frame.offsetBy(dx: 24, dy: -24)
            if let b = bounds, !b.contains(next) { break }
            frame = next
        }
        panel.setFrame(frame, display: false)
    }

    /// A move or resize the user made, kept for the screen it ended on, relative to that screen so a rearrangement of the
    /// displays does not strand it. AppKit moving the window off a display that went away is not kept.
    private func remember() {
        guard open, Viewer.parkedFrame == nil, !panel.inLiveResize, -Viewer.shared.screensChanged.timeIntervalSinceNow > 2,
              let screen = panel.screen, let key = PanelFrame.key(for: screen) else { return }
        PanelFrame.save(panel.frame.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY), key)
    }

    func windowDidMove(_ notification: Notification) { remember(); reportFrame() }
    func windowDidResize(_ notification: Notification) { remember(); reportFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { remember() }

    /// So the helper places a pinch by where the window it follows is now, not where its last check found it.
    private func reportFrame() {
        guard open, self === Viewer.shared.current, let top = NSScreen.screens.first?.frame.maxY else { return }
        let f = panel.frame
        Viewer.shared.helper()?.panelMoved(x: f.minX, y: top - f.maxY, width: f.width, height: f.height, windowNumber: panel.windowNumber)
    }
}

final class Viewer: NSObject, SpacebarViewerProtocol {
    static let shared = Viewer()
    static let idleExit: TimeInterval = 30 * 60
    /// Where a window opens instead of over Finder's window (a harness parks it off screen).
    static var parkedFrame: NSRect?
    /// Off in a harness, so a window never takes the focus.
    static var activates = true

    private var conn: NSXPCConnection?
    private var retries = 0
    /// Every window made, open or kept closed for reuse (`spareLimit`).
    private(set) var windows: [ViewerWindow] = []
    /// The window the helper's requests go to: the one it last opened, which follows Finder's selection until clicked into.
    private(set) var current: ViewerWindow?
    /// Closed windows kept with their page loaded, so the next Space opens as fast as the first.
    /// Two, so that opening and closing one window at a time never builds a page: the closed window and the spare made
    /// while it was open both stay.
    private static let spareLimit = 2
    private var idle: DispatchWorkItem?
    private var popoverTold = false
    fileprivate var screensChanged = Date.distantPast

    override init() {
        super.init()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.screensChanged = Date()
        }
    }

    /// Set once started; a harness sets it to keep the viewer off the helper.
    var started = false
    /// Last id given to a document window: negative, so never one of the helper's requests.
    private var documentID = 0
    /// Has opened a document: without the helper it stays until idle, a warm window for the next one.
    private var servedDocuments = false
    /// A document's fallback: the first app other than spacebar that opens it. A harness replaces it.
    static var handOff: (URL) -> Void = { url in
        // The same choice as Open: never spacebar, a browser or an office suite; text goes to a text editor.
        let app = LinkPolicy.opener(for: url)?.app ?? LinkPolicy.textOpener(for: url, editor: nil)?.app
        guard let app else { return vlog.error("no other app opens \(url.lastPathComponent, privacy: .private)") }
        vlog.info("handing \(url.lastPathComponent, privacy: .private) to \(app.lastPathComponent, privacy: .public)")
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration()) { _, err in
            if let err { vlog.error("hand-off failed: \(err.localizedDescription, privacy: .public)") }
        }
    }

    func start() {
        guard !started else { return }
        started = true
        if windows.isEmpty { windows = [ViewerWindow()] }
        connect()
        armIdle()
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

    /// Without the helper nothing can ask for a window: a few tries (launchd may be restarting it), then exit. Open windows
    /// stay; the helper just no longer follows Finder for them. A viewer that has opened documents leaves exiting to `armIdle`.
    private func lost() {
        guard conn != nil else { return }
        conn?.invalidate()
        conn = nil
        current = nil
        retries += 1
        // Open windows keep the viewer going, and it keeps trying, so Space reaches it again once the helper is back.
        let windowsOpen = windows.contains { $0.open || $0.request != 0 }
        guard retries <= 5 || windowsOpen || servedDocuments else {
            vlog.info("helper unreachable: exiting")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(min(retries, servedDocuments ? 30 : 5))) { self.connect() }
    }

    func helper() -> SpacebarHelperProtocol? {
        conn?.remoteObjectProxyWithErrorHandler { err in vlog.error("helper call failed: \(err.localizedDescription, privacy: .public)") } as? SpacebarHelperProtocol
    }

    func tellTextSession(_ held: Bool) {
        helper()?.textSession(held) { ok in
            if !ok { vlog.error("helper refused text session \(held)") }
        }
    }

    /// The helper forgets the popover whenever its window closes; `announce` tells it again for a window that shows one.
    func tellPopover(_ open: Bool) {
        guard open != popoverTold else { return }
        popoverTold = open
        helper()?.popover(open)
    }

    // MARK: Windows

    /// A closed window to reuse, else a new one.
    func freshWindow() -> ViewerWindow {
        if let w = windows.first(where: { $0.isSpare }) { return w }
        let w = ViewerWindow()
        windows.append(w)
        return w
    }

    /// Dock and ⌘Tab while any window is open, as an app is; the idle exit only once none is. One closed window is kept
    /// loaded for the next Space.
    func windowsChanged() {
        let any = windows.contains { $0.open || $0.request != 0 }
        // The last window closed while the viewer was active: the app behind it, Finder usually, gets the keyboard back.
        if !any, NSApp.isActive { NSApp.hide(nil) }
        NSApp.setActivationPolicy(any ? .regular : .accessory)
        if any { idle?.cancel() } else { armIdle() }
        // Soon after the window it was for has drawn, so a second Space comes to a loaded page; only when none is left.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, !self.windows.contains(where: { $0.isSpare }) else { return }
            self.windows.append(ViewerWindow())
        }
    }

    /// A window closed: the helper is told only for the one it follows; spares past `spareLimit` are let go.
    func closed(_ w: ViewerWindow, request: Int, tell: Bool) {
        if w === current {
            popoverTold = false
            current = nil
            if tell { helper()?.panelState(false, requestID: request, windowNumber: w.panel.windowNumber) }
        }
        // After its blanking has been drawn and it has been ordered out; counted again then, so two closes drop two.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            let spares = self.windows.filter { $0.isSpare }
            for drop in spares.dropFirst(Self.spareLimit) {
                drop.panel.orderOut(nil)
                drop.host.tearDown()
                self.windows.removeAll { $0 === drop }
            }
        }
        windowsChanged()
    }

    // MARK: SpacebarViewerProtocol

    /// Finder's selection changed under the window that follows it: that window shows it (a new one when none follows).
    func show(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void) {
        // Answered from the main thread: a reply proves a window can be drawn now, not just that the process is alive.
        DispatchQueue.main.async {
            reply(true)
            // The window it followed closed meanwhile: the selection change opens nothing.
            guard let w = self.current, w.open || w.request != 0, !w.closing else { return self.helper()?.declined(requestID) ?? () }
            w.present(Self.urls(paths), id: requestID)
            self.windowsChanged()
        }
    }

    /// A Space in Finder: a window already showing the selection comes forward; otherwise a new window opens for it, and the
    /// window that followed Finder before keeps its file.
    func open(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            reply(true)
            let urls = Self.urls(paths)
            if let w = self.windows.first(where: { $0.shows(urls) }) {
                self.setCurrent(w)
                w.adopt(requestID)
                if w.open { w.focus() }
                return
            }
            let w = self.freshWindow()
            self.setCurrent(w)
            w.present(urls, id: requestID)
            self.windowsChanged()
        }
    }

    /// Files opened from Finder or another app, each in its own window, or the one already showing it. The helper never
    /// follows these (`current` is untouched), so it never shows another file in one or closes it.
    func openDocuments(_ urls: [URL]) {
        start()
        servedDocuments = true
        for url in urls.filter(\.isFileURL).prefix(20) {
            if let w = windows.first(where: { $0.shows([url]) }) {
                if w.open { w.focus() }
                continue
            }
            let w = freshWindow()
            w.document = true
            documentID -= 1
            w.present([url], id: documentID)
        }
        windowsChanged()
    }

    /// The helper follows `w` from now on: an edit in the window it followed before no longer holds its keys.
    private func setCurrent(_ w: ViewerWindow) {
        guard current !== w else { return }
        if current?.textSession == true, !w.textSession { tellTextSession(false) }
        if w.textSession, current?.textSession != true { tellTextSession(true) }
        current = w
    }

    private static func urls(_ paths: [String]) -> [URL] {
        paths.filter { $0.hasPrefix("/") }.prefix(1000).map { URL(fileURLWithPath: $0) }
    }

    func key(_ name: String, isRepeat: Bool) {
        guard HelperKeys.all.contains(name) else { return }
        DispatchQueue.main.async { if let w = self.current, w.open { w.route(name, isRepeat: isRepeat) } }
    }

    func focus() {
        DispatchQueue.main.async { if let w = self.current, w.open { w.focus() } }
    }

    func close() {
        DispatchQueue.main.async {
            guard let w = self.current else { return }
            w.hide(tell: true)
        }
    }

    func gesture(_ data: Data) {
        DispatchQueue.main.async { if let w = self.current, w.open { w.sendGesture(data) } }
    }

    /// A viewer left with no window for a while exits; the helper starts a fresh one.
    private func armIdle() {
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.windows.contains(where: { $0.open || $0.request != 0 }) else { return }
            vlog.info("idle: exiting")
            exit(0)
        }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleExit, execute: w)
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
