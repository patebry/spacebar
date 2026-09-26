#if PROBE
import Cocoa
import ObjectiveC
import os

// Route-1 instrumentation: records every event that reaches the extension process and tries each in-process way to get key focus.
// Modes are read per click from test/probe/probe.conf (space-separated): undecline, textview, makekey, activate.

private let plog = Logger(subsystem: logSubsystem, category: "probe")
/// SPACEBAR_PROBE_CONF when set (a process launched with it), otherwise probe.conf in the support folder.
private let confPath: String = {
    if let p = ProcessInfo.processInfo.environment["SPACEBAR_PROBE_CONF"], !p.isEmpty { return p }
    return SettingsFile.supportDir.appendingPathComponent("probe.conf").path
}()

private func modes() -> Set<String> {
    Set(((try? String(contentsOfFile: confPath, encoding: .utf8)) ?? "").split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init))
}

private func describe(_ e: NSEvent) -> String {
    var s = "type=\(e.type.rawValue) win=\(e.windowNumber)"
    if e.type == .keyDown || e.type == .keyUp { s += " chars=\(e.characters ?? "") code=\(e.keyCode)" }
    return s
}

final class KeyProbeView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var needsPanelToBecomeKey: Bool { true }
    override func becomeFirstResponder() -> Bool { plog.info("KeyProbeView becomeFirstResponder"); return true }
    override func keyDown(with e: NSEvent) { plog.info("KeyProbeView keyDown \(describe(e), privacy: .public)") }
    override func keyUp(with e: NSEvent) { plog.info("KeyProbeView keyUp \(describe(e), privacy: .public)") }
    override func flagsChanged(with e: NSEvent) { plog.info("KeyProbeView flagsChanged") }
    override func performKeyEquivalent(with e: NSEvent) -> Bool { plog.info("KeyProbeView performKeyEquivalent \(describe(e), privacy: .public)"); return false }
}

final class ProbeTextView: NSTextView {
    override func keyDown(with e: NSEvent) { plog.info("NSTextView keyDown \(describe(e), privacy: .public)"); super.keyDown(with: e) }
    override func insertText(_ s: Any, replacementRange r: NSRange) { plog.info("NSTextView insertText \(String(describing: s), privacy: .public)"); super.insertText(s, replacementRange: r) }
    override func becomeFirstResponder() -> Bool { let ok = super.becomeFirstResponder(); plog.info("NSTextView becomeFirstResponder=\(ok)"); return ok }
}

private var swizzledWindowClasses = Set<String>()
private var sendEventCounts: [UInt: Int] = [:]

private func swizzleSendEvent(_ cls: AnyClass) {
    let name = NSStringFromClass(cls)
    guard !swizzledWindowClasses.contains(name), let m = class_getInstanceMethod(cls, #selector(NSWindow.sendEvent(_:))) else { return }
    swizzledWindowClasses.insert(name)
    typealias IMP_t = @convention(c) (NSWindow, Selector, NSEvent) -> Void
    let orig = unsafeBitCast(method_getImplementation(m), to: IMP_t.self)
    let block: @convention(block) (NSWindow, NSEvent) -> Void = { w, e in
        sendEventCounts[e.type.rawValue, default: 0] += 1
        if e.type != .mouseMoved && e.type != .appKitDefined && e.type != .systemDefined {
            plog.info("sendEvent[\(NSStringFromClass(type(of: w)), privacy: .public)] \(describe(e), privacy: .public)")
        }
        orig(w, #selector(NSWindow.sendEvent(_:)), e)
    }
    // Add an override on this exact class so superclasses stay untouched.
    if !class_addMethod(cls, #selector(NSWindow.sendEvent(_:)), imp_implementationWithBlock(block), method_getTypeEncoding(m)) {
        method_setImplementation(m, imp_implementationWithBlock(block))
    }
    plog.info("swizzled sendEvent on \(name, privacy: .public)")
}

private func overrideMask(_ cls: AnyClass, _ sel: String, _ value: UInt64) {
    guard let m = class_getInstanceMethod(cls, NSSelectorFromString(sel)) else { plog.error("no \(sel, privacy: .public)"); return }
    let block: @convention(block) (AnyObject) -> UInt64 = { _ in value }
    method_setImplementation(m, imp_implementationWithBlock(block))
    plog.info("overrode \(NSStringFromClass(cls), privacy: .public) \(sel, privacy: .public)")
}

private func overrideBool(_ cls: AnyClass, _ sel: String, _ value: Bool) {
    guard let m = class_getInstanceMethod(cls, NSSelectorFromString(sel)) else { plog.error("no \(sel, privacy: .public)"); return }
    let block: @convention(block) (AnyObject) -> Bool = { _ in value }
    method_setImplementation(m, imp_implementationWithBlock(block))
    plog.info("overrode \(NSStringFromClass(cls), privacy: .public) \(sel, privacy: .public)")
}

enum CommandChannel {
    private static var timer: Timer?
    private static var last = 0

    static func start(path: String) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 0.02, repeats: true) { _ in
            guard let data = FileManager.default.contents(atPath: path),
                  let cmd = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let n = cmd["n"] as? Int, n > last, let js = cmd["js"] as? String else { return }
            last = n
            WebHost.shared.web.evaluateJavaScript("JSON.stringify((() => { \(js) })()) ?? 'null'") { res, err in
                let out = Data(((res as? String) ?? "null").utf8).base64EncodedString()
                plog.info("CMDRES \(n) \(out, privacy: .public)\(err.map { " ERR " + String(describing: $0) } ?? "", privacy: .public)")
            }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }
}

enum Probe {
    static var installed = false
    static weak var root: NSView?
    static var textView: ProbeTextView?

    static func has(_ mode: String) -> Bool { modes().contains(mode) }

    static func makeRoot(frame: NSRect) -> NSView { let v = KeyProbeView(frame: frame); root = v; return v }

    static func install() {
        guard !installed else { return }
        installed = true
        let m = modes()
        plog.info("probe install modes=\(m.sorted().joined(separator: ","), privacy: .public)")
        // Logs and swallows QuickLook's double-click-to-open so tests can observe it without launching the default app.
        if m.contains("dblprobe"), let c = NSClassFromString("QLUIServiceBaseViewController"),
           let meth = class_getInstanceMethod(c, NSSelectorFromString("doubleClickOnPreviewContent")) {
            let block: @convention(block) (AnyObject) -> Void = { _ in plog.info("DOUBLE-CLICK-OPEN: doubleClickOnPreviewContent called (swallowed)") }
            method_setImplementation(meth, imp_implementationWithBlock(block))
        }
        if m.contains("undecline"), let c = NSClassFromString("QLUIServiceBaseViewController") {
            overrideMask(c, "declinedEventMask", 0)
            overrideBool(c, "canBecomeKey", true)
        }
        NSEvent.addLocalMonitorForEvents(matching: .any) { e in
            if e.type != .mouseMoved && e.type != .appKitDefined && e.type != .systemDefined && e.type != .periodic {
                plog.info("localMonitor \(describe(e), privacy: .public)")
            }
            if e.type == .leftMouseUp { DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { afterClick() } }
            return e
        }
        _ = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { e in plog.info("globalMonitor(in appex) \(describe(e), privacy: .public)") }
    }

    static func windowAttached(_ view: NSView) {
        guard let w = view.window else { return }
        swizzleSendEvent(type(of: w))
        report("attached", view)
        if modes().contains("autofocus") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { afterClick() } }
        if modes().contains("jsdebug") {
            WebHost.shared.web.evaluateJavaScript("""
                for (const t of ['mousedown', 'mouseup', 'click', 'dblclick'])
                  document.addEventListener(t, (e) => window.webkit.messageHandlers.sb.postMessage({ type: 'log',
                    msg: `${t} ${e.clientX},${e.clientY} detail=${e.detail} target=${e.target.tagName} epoch=${performance.timeOrigin + performance.now()}` }), true); 0
                """)
        }
        // Timed page scripts for tests: `script=<path>` names a JSON list of {"t": seconds after attach, "js": source}.
        if let m = modes().first(where: { $0.hasPrefix("script=") }),
           let data = FileManager.default.contents(atPath: String(m.dropFirst(7))),
           let steps = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
            for step in steps {
                guard let t = step["t"] as? Double, let js = step["js"] as? String else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                    WebHost.shared.web.evaluateJavaScript(js + "; 0") { _, err in if let err { plog.error("script: \(String(describing: err), privacy: .public)") } }
                }
            }
        }
        // Command channel for test/corpus.py: `cmd=<path>` names a JSON file {"n": seq, "js": body}; each new n runs `body` as a
        // function in the page and logs "CMDRES n <base64 JSON result>".
        if let m = modes().first(where: { $0.hasPrefix("cmd=") }) { CommandChannel.start(path: String(m.dropFirst(4))) }
        // DOM clicks for test/edit_latency.py: the first block `latdelay` s after attach (cold), then alternating blocks (warm).
        if let d = modes().first(where: { $0.hasPrefix("latdelay=") }), let delay = Double(d.dropFirst(9)) {
            for i in 0..<5 {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay + Double(i) * 1.0) {
                    WebHost.shared.web.evaluateJavaScript("""
                        (() => { const b = document.querySelectorAll('#doc > [data-src]')[\(i % 2)]; const r = b.getBoundingClientRect();
                          b.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + 200, clientY: r.top + 8 })); })(); 0
                        """)
                }
            }
        }
        // DOM-level click on the first block: exercises the inline-edit path without any OS input.
        if modes().contains("autoedit") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                WebHost.shared.web.evaluateJavaScript("""
                    (() => { const b = document.querySelector('#doc > [data-src]'); const r = b.getBoundingClientRect();
                      b.dispatchEvent(new MouseEvent('click', { bubbles: true, clientX: r.left + 30, clientY: r.top + 8 })); })(); 0
                    """)
            }
        }
    }

    static func report(_ tag: String, _ view: NSView) {
        let w = view.window
        var chain: [String] = []
        var vc: NSViewController? = view.nextResponder as? NSViewController
        while let v = vc { chain.append(NSStringFromClass(type(of: v))); vc = v.parent }
        var hier: [String] = []
        var sv: NSView? = view
        while let s = sv { hier.append(NSStringFromClass(type(of: s))); sv = s.superview }
        var responders: [String] = []
        var r: NSResponder? = w?.firstResponder
        while let rr = r, responders.count < 12 { responders.append(NSStringFromClass(type(of: rr))); r = rr.nextResponder }
        var declined = "?"
        if let parent = (view.nextResponder as? NSViewController)?.parent, parent.responds(to: NSSelectorFromString("declinedEventMask")) {
            typealias U = @convention(c) (AnyObject, Selector) -> UInt64
            let sel = NSSelectorFromString("declinedEventMask")
            declined = "0x" + String(unsafeBitCast(parent.method(for: sel), to: U.self)(parent, sel), radix: 16)
        }
        plog.info("""
            [\(tag, privacy: .public)] window=\(w.map { NSStringFromClass(type(of: $0)) } ?? "nil", privacy: .public) \
            num=\(w?.windowNumber ?? -1) isKey=\(w?.isKeyWindow ?? false) canBecomeKey=\(w?.canBecomeKey ?? false) \
            isVisible=\(w?.isVisible ?? false) frame=\(NSStringFromRect(w?.frame ?? .zero), privacy: .public) \
            appActive=\(NSApp.isActive) keyWindow=\(NSApp.keyWindow.map { NSStringFromClass(type(of: $0)) } ?? "nil", privacy: .public) \
            vcChain=\(chain.joined(separator: ">"), privacy: .public) views=\(hier.joined(separator: "<"), privacy: .public) \
            responders=\(responders.joined(separator: ">"), privacy: .public) declinedEventMask=\(declined, privacy: .public) \
            windows=\(NSApp.windows.map { "\(NSStringFromClass(type(of: $0)))#\($0.windowNumber) key=\($0.isKeyWindow)" }.joined(separator: ","), privacy: .public)
            """)
    }

    static func afterClick() {
        guard let root, let w = root.window else { return }
        let m = modes()
        if m.contains("activate") { NSApp.activate(ignoringOtherApps: true) }
        if m.contains("makekey") { w.makeKeyAndOrderFront(nil); w.makeKey() }
        if m.contains("textview") {
            if textView == nil {
                let tv = ProbeTextView(frame: NSRect(x: 20, y: 20, width: 400, height: 120))
                tv.string = "native NSTextView probe"
                tv.backgroundColor = .systemYellow
                root.addSubview(tv)
                textView = tv
            }
            plog.info("makeFirstResponder(NSTextView)=\(w.makeFirstResponder(textView))")
        } else {
            plog.info("makeFirstResponder(KeyProbeView)=\(w.makeFirstResponder(root))")
        }
        report("afterClick", root)
        plog.info("sendEvent counts \(sendEventCounts.map { "\($0.key):\($0.value)" }.sorted().joined(separator: " "), privacy: .public)")
    }
}
#endif
