import Cocoa
import ApplicationServices
import os

let log = Logger(subsystem: "md.spacebar", category: "helper")

/// One per connection: checks the caller's role before handing the call to the helper.
final class Endpoint: NSObject, SpacebarHelperProtocol {
    let role: Link.Role
    weak var conn: NSXPCConnection?
    init(role: Link.Role, conn: NSXPCConnection) { self.role = role; self.conn = conn }

    func hello(reply: @escaping (Bool) -> Void) {
        guard role == .viewer, let conn else { return reply(false) }
        DispatchQueue.main.async { Helper.shared.viewerHello(conn); reply(true) }
    }
    func panelState(_ open: Bool, requestID: Int, windowNumber: Int) {
        guard role == .viewer, let conn else { return }
        DispatchQueue.main.async { Helper.shared.panelState(open, requestID: requestID, windowNumber: windowNumber, from: conn) }
    }
    func declined(_ requestID: Int) {
        guard role == .viewer else { return }
        DispatchQueue.main.async { Helper.shared.declined(requestID) }
    }
    func status(reply: @escaping (Data) -> Void) {
        guard role == .app else { return reply(Data()) }
        DispatchQueue.main.async { reply((try? JSONEncoder().encode(Helper.shared.status())) ?? Data()) }
    }
    func promptAccessibility(reply: @escaping (Bool) -> Void) {
        guard role == .app else { return reply(false) }
        DispatchQueue.main.async {
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            reply(AXIsProcessTrustedWithOptions(opts))
        }
    }
}

final class Helper: NSObject, NSXPCListenerDelegate {
    static let shared = Helper()

    private let listener = NSXPCListener(machServiceName: HelperIDs.machService)
    private var settings = SettingsFile.load()
    private(set) var tap: CFMachPort?
    private var route = KeyRoute()
    private var viewer: NSXPCConnection?
    private var viewerPid: pid_t = 0
    private var panelOpen = false
    /// The show on its way to the viewer: `space` when a swallowed Space asked for it, and so must go back to Finder if it fails.
    private var pending: (id: Int, finderPid: pid_t, space: Bool, acked: Bool, at: Date)?
    private var requestSeq = 0
    private var lastShown: [String] = []
    private var finderPid: pid_t = 0
    private var launching = false
    private var relaunchDelay = 1.0
    private var nextLaunch = Date.distantPast
    private var observer: AXObserver?
    private var observedFocus: AXUIElement?
    private var followPending = false
    private var finderTextFocus = false
    /// The viewer's panel, as it reported it; checked on screen before its keys are taken, and again every 2 s.
    private var panelWindow = 0
    private var watchTimer: Timer?
    private let bg = DispatchQueue(label: "md.spacebar.helper.ax", qos: .userInteractive)

    func start() {
        guard settings.spaceHelper else {
            log.info("spaceHelper is off: exiting")
            exit(0)
        }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), Decision.axTimeout)
        log.info("launch pid=\(getpid()) trusted=\(AXIsProcessTrusted())")
        if !Link.gate(listener) { log.error("unsigned build: every connection is refused") }
        listener.delegate = self
        listener.resume()
        refreshFinder()
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(self, selector: #selector(appLaunched(_:)), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        ws.addObserver(self, selector: #selector(appActivated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        watchTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.watch() }
        watch()
    }

    /// Every 2 s: the setting (off exits), Accessibility (the tap starts once it is granted), and the viewer's process.
    private func watch() {
        let s = SettingsFile.load()
        guard s.spaceHelper else {
            log.info("spaceHelper turned off: exiting")
            if panelOpen || pending != nil { viewerProxy()?.close() }
            // Time for the close to reach the viewer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            watchTimer?.invalidate()
            return
        }
        settings = s
        if tap == nil, AXIsProcessTrusted() { createTap() }
        if tap != nil { ensureViewer() }
        if tap != nil, observer == nil { observeFinder() }
        // The viewer gives up on a show after 4 s; one it never answered for is closed here.
        if let p = pending, Date().timeIntervalSince(p.at) > 5 { fail(p.id, "no panel in 5 s") }
        if panelOpen, !panelOnScreen(panelWindow) {
            log.error("panel window \(self.panelWindow) not on screen: its keys go back to Finder")
            close("panel not on screen")
        }
    }

    /// Whether window `n` is on screen, visible, and the viewer's.
    private func panelOnScreen(_ n: Int) -> Bool {
        guard n > 0, viewerPid > 0,
              let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(n)) as? [[String: Any]])?.first else { return false }
        return w[kCGWindowOwnerPID as String] as? pid_t == viewerPid && w[kCGWindowIsOnscreen as String] as? Bool == true
            && (w[kCGWindowAlpha as String] as? Double ?? 0) > 0
    }

    func status() -> HelperStatus {
        HelperStatus(pid: getpid(), version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                     enabled: settings.spaceHelper, trusted: AXIsProcessTrusted(), tap: tap != nil, viewer: viewer != nil)
    }

    // MARK: Connections

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        guard let role = Link.accept(c, exported: { Endpoint(role: $0, conn: $1) }) else {
            log.error("refused a connection from pid \(c.processIdentifier)")
            return false
        }
        let pid = c.processIdentifier
        c.invalidationHandler = { [weak self, weak c] in DispatchQueue.main.async { self?.lost(c, pid: pid) } }
        c.resume()
        log.info("accepted \(role == .viewer ? "viewer" : "app", privacy: .public) pid \(pid)")
        return true
    }

    func viewerHello(_ c: NSXPCConnection) {
        if let old = viewer, old !== c { old.invalidate() }
        viewer = c
        viewerPid = c.processIdentifier
        relaunchDelay = 1
        panelOpen = false
    }

    private func lost(_ c: NSXPCConnection?, pid: pid_t) {
        guard pid == viewerPid, viewer == nil || viewer === c else { return }
        log.info("viewer gone (pid \(pid))")
        viewer = nil
        viewerPid = 0
        panelOpen = false
        if let p = pending { fail(p.id, "viewer gone") }
        // A viewer that keeps dying is relaunched less and less often.
        nextLaunch = Date(timeIntervalSinceNow: relaunchDelay)
        DispatchQueue.main.asyncAfter(deadline: .now() + relaunchDelay) { [weak self] in self?.ensureViewer() }
        relaunchDelay = min(relaunchDelay * 2, 60)
    }

    private func viewerProxy(onError: (() -> Void)? = nil) -> SpacebarViewerProtocol? {
        viewer?.remoteObjectProxyWithErrorHandler { err in
            log.error("viewer call failed: \(err.localizedDescription, privacy: .public)")
            DispatchQueue.main.async { onError?() }
        } as? SpacebarViewerProtocol
    }

    /// Starts the viewer when it is not connected. It is its own app (so its own responsible process for privacy prompts),
    /// launched without activating.
    private func ensureViewer() {
        guard viewer == nil, !launching, tap != nil, Date() >= nextLaunch else { return }
        let url = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(HelperIDs.viewerApp)
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false
        cfg.addsToRecentItems = false
        cfg.createsNewApplicationInstance = false
        launching = true
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
            DispatchQueue.main.async {
                self.launching = false
                if let err { log.error("viewer launch failed: \(err.localizedDescription, privacy: .public)") }
                else { log.info("viewer launched pid \(app?.processIdentifier ?? -1)") }
            }
        }
    }

    func panelState(_ open: Bool, requestID: Int, windowNumber: Int, from c: NSXPCConnection, retried: Bool = false) {
        guard c === viewer else { return }
        guard open else { panelOpen = false; panelWindow = 0; return }
        // Only a show this helper asked for may open the panel, and only with a window of the viewer's really on screen, so a
        // viewer cannot claim Finder's keys on its own.
        guard pending?.id == requestID else { return log.error("panel open for request \(requestID) not pending: ignored") }
        guard panelOnScreen(windowNumber) else {
            // The window server may not have shown the panel's first frame yet.
            if !retried {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                    self?.panelState(open, requestID: requestID, windowNumber: windowNumber, from: c, retried: true)
                }
            } else {
                log.error("panel open for request \(requestID): window \(windowNumber) not on screen")
            }
            return
        }
        pending = nil
        panelOpen = true
        panelWindow = windowNumber
    }

    func declined(_ id: Int) {
        guard let p = pending, p.id == id else { return }
        fail(id, "declined")
    }

    // MARK: Tap

    private func createTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil) else {
            return log.error("tap create failed")
        }
        tap = port
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0), .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log.info("tap on")
    }

    private static func keyEvent(_ event: CGEvent, down: Bool) -> KeyEvent {
        let f = event.flags
        var mods: HelperMods = []
        if f.contains(.maskCommand) { mods.insert(.command) }
        if f.contains(.maskShift) { mods.insert(.shift) }
        if f.contains(.maskAlternate) { mods.insert(.option) }
        if f.contains(.maskControl) { mods.insert(.control) }
        var e = KeyEvent(code: event.getIntegerValueField(.keyboardEventKeycode), down: down,
                         isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0, mods: mods,
                         tagged: event.getIntegerValueField(.eventSourceUserData) == Decision.repostTag,
                         targetPid: Int32(truncatingIfNeeded: event.getIntegerValueField(.eventTargetUnixProcessID)))
        // Only a Command shortcut needs its character, and only while the panel could be open.
        if down, mods.contains(.command) { e.chars = NSEvent(cgEvent: event)?.charactersIgnoringModifiers?.lowercased() ?? "" }
        return e
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            route.release()
            log.error("tap re-enabled (\(type == .tapDisabledByTimeout ? "timeout" : "user input", privacy: .public))")
            return pass
        }
        guard type == .keyDown || type == .keyUp else { return pass }
        let e = Self.keyEvent(event, down: type == .keyDown)
        // A rename or the search field can open without a focus notification arriving first: read the focus now, before a key
        // that the panel would take from it. Any AX error counts as a text field, so the key stays Finder's.
        if panelOpen, e.down, !e.isRepeat, !e.tagged, e.targetPid == finderPid, finderPid > 0,
           KeyRoute.closes(e) || KeyRoute.forwarded(e, sidebarKeys: settings.sidebarKeys) != nil {
            finderTextFocus = Self.textFocus(finderPid)
        }
        let ctx = PanelContext(open: panelOpen || pending != nil, finderPid: finderPid, viewerPid: viewerPid, sidebarKeys: settings.sidebarKeys,
                               textFocus: finderTextFocus)
        switch route.route(e, panel: ctx) {
        case .pass: return pass
        case .swallow: return nil
        case .close:
            close("key")
            return nil
        case .forward(let name):
            viewerProxy()?.key(name, isRepeat: e.isRepeat, mods: e.mods.rawValue)
            return nil
        case .space:
            return space() ? nil : pass
        }
    }

    /// Space with the panel closed: true when it was taken and the viewer asked to show Finder's selection.
    private func space() -> Bool {
        let front = NSWorkspace.shared.frontmostApplication
        let t0 = nowNs()
        let c = front?.bundleIdentifier == finderID ? FinderAX.spaceContext(finderPid: front!.processIdentifier) : SpaceContext(frontIsFinder: false)
        let d = Decision.space(c)
        guard case .show(let paths) = d, let fpid = front?.processIdentifier else {
            if c.frontIsFinder { log.info("space pass \(String(describing: d), privacy: .public) in \(ms(since: t0), format: .fixed(precision: 1))ms errors=\(c.axErrors.joined(separator: ","), privacy: .public)") }
            return false
        }
        guard viewer != nil else {
            log.error("space pass: viewer not connected")
            ensureViewer()
            return false
        }
        route.hold(KeyCode.space)
        finderPid = fpid
        show(paths, finderPid: fpid, space: true)
        log.info("space show n=\(paths.count) decided in \(ms(since: t0), format: .fixed(precision: 1))ms")
        return true
    }

    /// Asks the viewer to show `paths`. A viewer that does not answer within 150 ms, or declines, hands a Space back to Finder.
    private func show(_ paths: [String], finderPid: pid_t, space: Bool) {
        requestSeq += 1
        let id = requestSeq
        pending = (id, finderPid, space, false, Date())
        lastShown = paths
        viewerProxy(onError: { [weak self] in self?.fail(id, "xpc error") })?.show(paths, requestID: id) { ok in
            DispatchQueue.main.async { [weak self] in
                guard let self, let p = self.pending, p.id == id else { return }
                if ok { self.pending?.acked = true } else { self.fail(id, "refused") }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let p = self.pending, p.id == id, !p.acked else { return }
            self.fail(id, "no answer in 150 ms")
        }
    }

    private func fail(_ id: Int, _ why: String) {
        guard let p = pending, p.id == id else { return }
        pending = nil
        log.info("show \(id) failed: \(why, privacy: .public)")
        // A Space goes back to Finder, and the viewer, which may still answer late, must not open over Apple's panel. A
        // follow of Finder's selection that failed leaves the panel as it is.
        guard p.space else { return }
        viewerProxy()?.close()
        // Seconds later the Space is stale: Apple's panel opening then would surprise more than nothing happening.
        if Date().timeIntervalSince(p.at) < 1 { repost(to: p.finderPid) }
    }

    private func close(_ why: String) {
        pending = nil
        guard panelOpen || viewer != nil else { return }
        viewerProxy()?.close()
        panelOpen = false
        log.info("close (\(why, privacy: .public))")
    }

    /// Hands a Space back to Finder, tagged so this tap lets it through. Whether Finder honours it is logged (P0 left it open).
    private func repost(to pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.userData = Decision.repostTag
        for down in [true, false] {
            guard let ev = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(KeyCode.space), keyDown: down) else {
                return log.error("repost: event not created")
            }
            ev.setIntegerValueField(.eventSourceUserData, value: Decision.repostTag)
            ev.postToPid(pid)
        }
        bg.asyncAfter(deadline: .now() + 0.6) {
            log.info("repost to Finder pid \(pid): Quick Look open after 600 ms: \(FinderAX.quickLookOpen(finderPid: pid))")
        }
    }

    // MARK: Finder

    private func refreshFinder() {
        finderPid = NSRunningApplication.runningApplications(withBundleIdentifier: finderID).first?.processIdentifier ?? 0
    }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.bundleIdentifier == finderID else { return }
        refreshFinder()
        if let obs = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes) }
        observer = nil
        observedFocus = nil
        if tap != nil { observeFinder() }
    }

    /// Another app coming forward closes the panel, as Finder going to the background hides Quick Look's.
    @objc private func appActivated(_ note: Notification) {
        guard panelOpen || pending != nil, let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.bundleIdentifier != finderID, app.processIdentifier != viewerPid else { return }
        close("\(app.bundleIdentifier ?? "another app") active")
    }

    /// Finder's selection changes: with sidebarKeys off the arrows move Finder's selection, and the panel follows it. The same
    /// observer notices Apple's Quick Look opening (Finder's focus moves into it), which closes the panel.
    private func observeFinder() {
        guard finderPid > 0 else { return }
        var obs: AXObserver?
        guard AXObserverCreate(finderPid, axCallback, &obs) == .success, let obs else { return log.error("AX observer not created") }
        observer = obs
        let app = AXUIElementCreateApplication(finderPid)
        for n in [kAXSelectedRowsChangedNotification, kAXSelectedChildrenChangedNotification, kAXFocusedUIElementChangedNotification, kAXWindowCreatedNotification] {
            AXObserverAddNotification(obs, app, n as CFString, nil)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
        observeFocused()
    }

    /// Some views post their selection changes on the focused element only.
    private func observeFocused() {
        guard let obs = observer, let f = AXTrace().element(AXUIElementCreateApplication(finderPid), kAXFocusedUIElementAttribute) else { return }
        if let old = observedFocus, CFEqual(old, f) { return }
        if let old = observedFocus {
            AXObserverRemoveNotification(obs, old, kAXSelectedRowsChangedNotification as CFString)
            AXObserverRemoveNotification(obs, old, kAXSelectedChildrenChangedNotification as CFString)
        }
        observedFocus = f
        AXObserverAddNotification(obs, f, kAXSelectedRowsChangedNotification as CFString, nil)
        AXObserverAddNotification(obs, f, kAXSelectedChildrenChangedNotification as CFString, nil)
    }

    func axNotification(_ name: String) {
        if name == kAXFocusedUIElementChangedNotification as String || name == kAXWindowCreatedNotification as String {
            if name == kAXFocusedUIElementChangedNotification as String { observeFocused(); readTextFocus() }
            if panelOpen { checkQuickLook() }
            return
        }
        guard panelOpen, !settings.sidebarKeys, !followPending else { return }
        followPending = true
        let pid = finderPid
        bg.asyncAfter(deadline: .now() + 0.03) {
            let paths = FinderAX.selection(app: AXUIElementCreateApplication(pid), focused: nil, trace: AXTrace(budgetMs: 100)).filter { $0.hasPrefix("/") }
            DispatchQueue.main.async {
                self.followPending = false
                guard self.panelOpen, !paths.isEmpty, paths != self.lastShown else { return }
                self.show(paths, finderPid: pid, space: false)
            }
        }
    }

    private func readTextFocus() {
        let pid = finderPid
        bg.async {
            let text = Self.textFocus(pid)
            DispatchQueue.main.async { self.finderTextFocus = text }
        }
    }

    /// Whether Finder's focus is a text field, read within the AX budget; true when AX could not say.
    static func textFocus(_ pid: pid_t) -> Bool {
        let t = AXTrace()
        let f = t.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute)
        guard t.errors.isEmpty, !t.expired, let f else { return !t.errors.isEmpty || t.expired }
        let role = t.role(f), sub = t.subrole(f)
        // A role left unread because the budget ran out is not an answer.
        guard t.errors.isEmpty, role != nil || !t.expired else { return true }
        return Decision.textRoles.contains(role ?? "") || sub == "AXSearchField"
    }

    private func checkQuickLook() {
        let pid = finderPid
        bg.async {
            guard FinderAX.quickLookOpen(finderPid: pid) else { return }
            DispatchQueue.main.async { self.close("Quick Look opened") }
        }
    }
}

let tapCallback: CGEventTapCallBack = { _, type, event, _ in Helper.shared.handle(type: type, event: event) }
let axCallback: AXObserverCallback = { _, _, name, _ in Helper.shared.axNotification(name as String) }

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ n: Notification) { Helper.shared.start() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
