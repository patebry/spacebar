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
        guard Link.permits(role, .hello), let conn else { return reply(false) }
        DispatchQueue.main.async { Helper.shared.viewerHello(conn); reply(true) }
    }
    func panelState(_ open: Bool, requestID: Int, windowNumber: Int) {
        guard Link.permits(role, .panelState), let conn else { return }
        DispatchQueue.main.async { Helper.shared.panelState(open, requestID: requestID, windowNumber: windowNumber, from: conn) }
    }
    func declined(_ requestID: Int) {
        guard Link.permits(role, .declined) else { return }
        DispatchQueue.main.async { Helper.shared.declined(requestID) }
    }
    func textSession(_ active: Bool, reply: @escaping (Bool) -> Void) {
        guard Link.permits(role, .textSession), let conn else { return reply(false) }
        DispatchQueue.main.async { reply(Helper.shared.textSession(active, from: conn)) }
    }
    func status(reply: @escaping (Data) -> Void) {
        guard Link.permits(role, .status) else { return reply(Data()) }
        DispatchQueue.main.async { reply((try? JSONEncoder().encode(Helper.shared.status())) ?? Data()) }
    }
    func promptAccessibility(reply: @escaping (Bool) -> Void) {
        guard Link.permits(role, .promptAccessibility) else { return reply(false) }
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
    private static let binary = HelperBinary.stamp(Bundle.main.executablePath ?? "")
    private var tapSource: CFRunLoopSource?
    private var route = KeyRoute()
    private var viewer: NSXPCConnection?
    private var viewerPid: pid_t = 0
    private var panelOpen = false
    /// When another app came forward over the open panel, which the viewer then ordered out; nil when nothing is suspended.
    private var suspendedAt: Date?
    /// Counts suspends and Finder's returns, so only the reads of the latest return over the current suspend decide.
    private var suspendSeq = 0
    /// The request bringing a suspended panel back: if it fails, the panel must not stay up without Finder's keys.
    private var restoring = 0
    /// The show on its way to the viewer: `space` when a swallowed Space asked for it, and so must go back to Finder if it fails.
    private var pending: (id: Int, finderPid: pid_t, space: Bool, acked: Bool, at: Date, paths: [String])?
    private var requestSeq = 0
    /// The selection of the show the helper last accepted on screen: what a restore must find selected in Finder.
    private var lastShown: [String] = []
    private var finderPid: pid_t = 0
    private var launching = false
    private var relaunchDelay = 1.0
    private var nextLaunch = Date.distantPast
    private var observer: AXObserver?
    private var observedFocus: AXUIElement?
    private var followPending = false
    private var finderTextFocus = false
    private var text = TextSession()
    /// The viewer's panel, as it reported it; checked on screen before its keys are taken, and again every 2 s.
    private var panelWindow = 0
    /// Checks in a row that found the panel's window off screen; one can be a frame the window server had not drawn yet.
    private var offscreenMisses = 0
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
            if panelOpen || pending != nil || suspendedAt != nil { viewerProxy()?.close() }
            // Time for the close to reach the viewer.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            watchTimer?.invalidate()
            return
        }
        settings = s
        switch Decision.tapAction(exists: tap != nil, trusted: AXIsProcessTrusted()) {
        case .create: createTap()
        case .remove: removeTap()
        case .none: break
        }
        if tap != nil { ensureViewer() }
        if tap != nil, observer == nil { observeFinder() }
        // The viewer gives up on a show after 4 s; one it never answered for is closed here.
        if let p = pending, Date().timeIntervalSince(p.at) > 5 { fail(p.id, "no panel in 5 s") }
        offscreenMisses = panelOpen && !panelOnScreen(panelWindow) ? offscreenMisses + 1 : 0
        if offscreenMisses >= 2 {
            log.error("panel window \(self.panelWindow) not on screen: its keys go back to Finder")
            close("panel not on screen")
        }
    }

    /// Whether window `n` is the viewer's, on screen, visible, and on a display (`Decision.panelVisible`).
    private func panelOnScreen(_ n: Int) -> Bool {
        guard n > 0, let w = (CGWindowListCopyWindowInfo(.optionIncludingWindow, CGWindowID(n)) as? [[String: Any]])?.first,
              let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }) else { return false }
        let info = WindowInfo(owner: w[kCGWindowOwnerPID as String] as? pid_t ?? 0, onScreen: w[kCGWindowIsOnscreen as String] as? Bool == true,
                              alpha: w[kCGWindowAlpha as String] as? Double ?? 0, bounds: b)
        return Decision.panelVisible(info, viewerPid: viewerPid, displays: Self.displays())
    }

    private static func displays() -> [CGRect] {
        var n: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &n) == .success, n > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(n))
        guard CGGetActiveDisplayList(n, &ids, &n) == .success else { return [] }
        return ids.prefix(Int(n)).map(CGDisplayBounds)
    }

    func status() -> HelperStatus {
        HelperStatus(pid: getpid(), version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                     enabled: settings.spaceHelper, trusted: AXIsProcessTrusted(), tap: tap.map { CGEvent.tapIsEnabled(tap: $0) } ?? false, viewer: viewer != nil,
                     binary: Self.binary)
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
        suspendedAt = nil
        text.clear()
    }

    private func lost(_ c: NSXPCConnection?, pid: pid_t) {
        guard pid == viewerPid, viewer == nil || viewer === c else { return }
        log.info("viewer gone (pid \(pid))")
        viewer = nil
        viewerPid = 0
        panelOpen = false
        suspendedAt = nil
        text.clear()
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
        guard open else {
            panelOpen = false
            panelWindow = 0
            suspendedAt = nil
            text.clear()
            if Decision.closeEndsPending(pendingID: pending?.id, requestID: requestID) { pending = nil }
            return
        }
        // So a viewer cannot claim Finder's keys on its own.
        switch Decision.panelOpened(pendingID: pending?.id, requestID: requestID, onScreen: panelOnScreen(windowNumber), retried: retried) {
        case .notPending:
            log.error("panel open for request \(requestID) not pending: ignored")
        case .retry:
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                self?.panelState(open, requestID: requestID, windowNumber: windowNumber, from: c, retried: true)
            }
        case .fail:
            log.error("panel open for request \(requestID): window \(windowNumber) not on screen")
            fail(requestID, "window not on screen")
        case .accept:
            if let p = pending { lastShown = p.paths }
            pending = nil
            panelOpen = true
            panelWindow = windowNumber
            offscreenMisses = 0
        }
    }

    func declined(_ id: Int) {
        guard let p = pending, p.id == id else { return }
        fail(id, "declined")
    }

    func textSession(_ active: Bool, from c: NSXPCConnection) -> Bool {
        guard c === viewer else { return false }
        let held = text.set(active, panelOpen: panelOpen || pending != nil)
        log.info("text session \(self.text.active ? "on" : "off", privacy: .public)\(held ? "" : " (refused: no panel)", privacy: .public)")
        return held
    }

    // MARK: Tap

    private func createTap() {
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil) else {
            return log.error("tap create failed")
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        tapSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        log.info("tap on")
    }

    /// Accessibility was revoked: the tap goes, the panel closes, and a new tap is made if it is granted again.
    private func removeTap() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        CFMachPortInvalidate(port)
        tap = nil
        tapSource = nil
        route.release()
        close("accessibility revoked")
        log.error("tap off: Accessibility revoked")
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
            route.release()
            let why = type == .tapDisabledByTimeout ? "timeout" : "user input"
            guard let tap, Decision.reenablesTap(trusted: AXIsProcessTrusted()) else {
                log.error("tap disabled (\(why, privacy: .public)), Accessibility not granted: not re-enabled")
                return pass
            }
            CGEvent.tapEnable(tap: tap, enable: true)
            log.error("tap re-enabled (\(why, privacy: .public))")
            return pass
        }
        guard type == .keyDown || type == .keyUp else { return pass }
        let e = Self.keyEvent(event, down: type == .keyDown)
        // A rename or the search field can open without a focus notification arriving first: read the focus now, before a key
        // that the panel would take from it. Any AX error counts as a text field, so the key stays Finder's.
        if panelOpen || pending != nil, !text.active, e.down, !e.isRepeat, !e.tagged, e.targetPid == finderPid, finderPid > 0,
           KeyRoute.closes(e) || KeyRoute.forwarded(e, sidebarKeys: settings.sidebarKeys) != nil {
            finderTextFocus = Self.textFocus(finderPid)
        }
        let ctx = PanelContext(open: panelOpen || pending != nil, finderPid: finderPid, viewerPid: viewerPid, sidebarKeys: settings.sidebarKeys,
                               textFocus: finderTextFocus, textSession: text.active)
        switch route.route(e, panel: ctx) {
        case .pass: return pass
        case .swallow: return nil
        case .close:
            close("key to pid \(e.targetPid)")
            return nil
        case .forward(let name):
            viewerProxy()?.key(name, isRepeat: e.isRepeat)
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
        if space { suspendedAt = nil }
        request(finderPid: finderPid, space: space, paths: paths) { proxy, id, reply in proxy.show(paths, requestID: id, reply: reply) }
    }

    /// Makes request `id` pending and sends it with `call`; one not acknowledged within 150 ms, or refused, fails.
    private func request(finderPid: pid_t, space: Bool, paths: [String], _ call: (SpacebarViewerProtocol, Int, @escaping (Bool) -> Void) -> Void) {
        requestSeq += 1
        let id = requestSeq
        pending = (id, finderPid, space, false, Date(), paths)
        guard let proxy = viewerProxy(onError: { [weak self] in self?.fail(id, "xpc error") }) else { return fail(id, "no viewer") }
        call(proxy, id) { ok in
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

    /// Another app came forward over the open panel: the viewer orders it out and Finder's keys are Finder's again.
    private func suspend(_ why: String) {
        viewerProxy()?.suspend()
        panelOpen = false
        text.clear()
        panelWindow = 0
        offscreenMisses = 0
        suspendedAt = Date()
        suspendSeq += 1
        log.info("suspend (\(why, privacy: .public))")
    }

    /// Finder came back: the viewer shows the suspended panel again as a new request, which, like a show, holds Finder's keys
    /// while pending and keeps them only once `panelState` has seen its window on screen.
    private func restore() {
        suspendedAt = nil
        guard viewer != nil, finderPid > 0 else { return }
        log.info("restore")
        request(finderPid: finderPid, space: false, paths: lastShown) { proxy, id, reply in
            restoring = id
            proxy.restore(id, reply: reply)
        }
    }

    private func fail(_ id: Int, _ why: String) {
        guard let p = pending, p.id == id else { return }
        pending = nil
        if !panelOpen { text.clear() }
        log.info("show \(id) failed: \(why, privacy: .public)")
        if id == restoring {
            viewerProxy()?.close()
            return
        }
        switch Decision.failed(space: p.space, age: Date().timeIntervalSince(p.at)) {
        case .leave: break
        case .close: viewerProxy()?.close()
        case .closeAndRepost:
            viewerProxy()?.close()
            repost(to: p.finderPid)
        }
    }

    private func close(_ why: String) {
        pending = nil
        suspendedAt = nil
        text.clear()
        guard panelOpen || viewer != nil else { return }
        viewerProxy()?.close()
        panelOpen = false
        log.info("close (\(why, privacy: .public))")
    }

    /// Hands a Space back to Finder, tagged so this tap lets it through. Whether Finder honours it is logged: not yet checked live.
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

    /// Another app coming forward hides the panel, as Finder going to the background hides Quick Look's; Finder coming back
    /// brings it back.
    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication, app.processIdentifier != viewerPid else { return }
        let who = app.bundleIdentifier ?? "another app"
        switch Decision.activated(isFinder: who == finderID, open: panelOpen, pending: pending != nil,
                                  suspendedFor: suspendedAt.map { Date().timeIntervalSince($0) }) {
        case .none: break
        case .close: close("\(who) active")
        case .suspend: suspend("\(who) active")
        case .check: resume(finderPid: app.processIdentifier)
        case .restore: restore()
        case .forget: forget("suspended too long")
        }
    }

    /// Brings the hidden panel back only for the selection it was showing (`Decision.resumes`). A "Show in Finder" or a click
    /// may still be changing the selection as Finder comes forward, so it is read twice, after 100 ms and again 200 ms later, and
    /// both reads must match; the first that does not drops the panel.
    private func resume(finderPid pid: pid_t) {
        suspendSeq += 1
        let seq = suspendSeq
        let clicked = Self.desktopClick()
        func read(_ delay: Double, then: @escaping () -> Void) {
            bg.asyncAfter(deadline: .now() + delay) {
                var r = FinderAX.resumeRead(finderPid: pid)
                r.clicked = clicked
                DispatchQueue.main.async {
                    guard let at = self.suspendedAt, self.suspendSeq == seq, !self.panelOpen, self.pending == nil,
                          NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return }
                    guard Decision.resumes(r, shown: self.lastShown, suspendedFor: Date().timeIntervalSince(at)) == .restore else {
                        return self.forget("Finder back: selection n=\(r.selection.count) desktop=\(r.desktop) clicked=\(clicked) errors=\(r.axErrors.joined(separator: ",")) in \(String(format: "%.1f", r.elapsedMs))ms")
                    }
                    then()
                }
            }
        }
        read(0.1) {
            read(0.2) {
                self.finderPid = pid
                self.restore()
            }
        }
    }

    /// Whether a mouse button went down in the last second over Finder's Desktop: the first window under the pointer, front to
    /// back, is below the normal window layer (the Desktop's icons or picture), not a window, the Dock or a menu.
    private static func desktopClick() -> Bool {
        let recent = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].contains {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < 1
        }
        guard recent, let primary = NSScreen.screens.first?.frame else { return false }
        let m = NSEvent.mouseLocation
        let point = CGPoint(x: m.x, y: primary.maxY - m.y)
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return false }
        for w in info {
            guard let b = (w[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }), b.contains(point),
                  (w[kCGWindowAlpha as String] as? Double ?? 1) > 0 else { continue }
            return (w[kCGWindowLayer as String] as? Int ?? 0) < 0
        }
        return false
    }

    /// Drops a hidden panel as a close does.
    private func forget(_ why: String) {
        suspendedAt = nil
        viewerProxy()?.close()
        log.info("forget (\(why, privacy: .public))")
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
                guard self.panelOpen, !paths.isEmpty, paths != (self.pending?.paths ?? self.lastShown) else { return }
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
        var r = FocusRead(found: false)
        if let f = t.element(AXUIElementCreateApplication(pid), kAXFocusedUIElementAttribute) {
            r.found = true
            if t.errors.isEmpty { r.role = t.role(f); r.subrole = t.subrole(f) }
        }
        r.errors = !t.errors.isEmpty
        r.expired = t.expired
        return Decision.textFocus(r)
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
