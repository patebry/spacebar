// The editflows harness's hook in the real writer: run.sh puts this file in front of Writer/main.swift, so the XPC service is
// the real writer (its EditSession, EditTextView, writes and refusals) with a key driver. The edit panel is never ordered on
// screen and never takes the keyboard: it reports itself key, and keys are NSEvents dispatched in-process as AppKit dispatches
// a key (performKeyEquivalent, then sendEvent), with NSApp.currentEvent set to each while it is handled. The general pasteboard
// is a private one. The harness writes cmd.json in $EDITFLOWS_DIR and posts a Darwin notification; the driver runs its steps
// against the current session's text view and answers with result.json.
import AppKit
import ObjectiveC

enum EditFlowsDriver {
    static let dir = URL(fileURLWithPath: ProcessInfo.processInfo.environment["EDITFLOWS_DIR"] ?? NSTemporaryDirectory())
    static let board = NSPasteboard(name: NSPasteboard.Name("md.spacebar.test.editflows-\(getpid())"))
    static let releaseBoard: Void = { atexit { EditFlowsDriver.board.releaseGlobally() } }()
    static var dispatching: NSEvent?
    static var panelOrderedFront = 0
    /// Named for this run, so no other run's writer answers.
    static let note = "md.spacebar.test.editflows.cmd.\(ProcessInfo.processInfo.environment["EDITFLOWS_TOKEN"] ?? "")" as CFString

    static func install() {
        _ = releaseBoard
        let general: @convention(block) (AnyObject) -> NSPasteboard = { _ in board }
        method_setImplementation(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general))!, imp_implementationWithBlock(general))

        let sel = #selector(getter: NSApplication.currentEvent)
        typealias Getter = @convention(c) (AnyObject, Selector) -> NSEvent?
        let original = unsafeBitCast(method_getImplementation(class_getInstanceMethod(NSApplication.self, sel)!), to: Getter.self)
        let current: @convention(block) (AnyObject) -> NSEvent? = { app in dispatching ?? original(app, sel) }
        method_setImplementation(class_getInstanceMethod(NSApplication.self, sel)!, imp_implementationWithBlock(current))

        let key: @convention(block) (AnyObject) -> Bool = { _ in true }
        class_replaceMethod(EditPanel.self, #selector(getter: NSWindow.isKeyWindow), imp_implementationWithBlock(key), "c@:")
        let front: @convention(block) (AnyObject, AnyObject?) -> Void = { _, _ in panelOrderedFront += 1 }
        class_replaceMethod(EditPanel.self, #selector(NSWindow.makeKeyAndOrderFront(_:)), imp_implementationWithBlock(front), "v@:@")

        // App activations are the user's, elsewhere on this Mac: they must not end the harness's sessions.
        let addSel = #selector(NotificationCenter.addObserver(_:selector:name:object:))
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject, Selector, NSString?, AnyObject?) -> Void
        let add = unsafeBitCast(method_getImplementation(class_getInstanceMethod(NotificationCenter.self, addSel)!), to: Add.self)
        let filtered: @convention(block) (AnyObject, AnyObject, Selector, NSString?, AnyObject?) -> Void = { center, observer, s, name, object in
            if name as String? == NSWorkspace.didActivateApplicationNotification.rawValue { return }
            add(center, addSel, observer, s, name, object)
        }
        method_setImplementation(class_getInstanceMethod(NotificationCenter.self, addSel)!, imp_implementationWithBlock(filtered))

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { EditFlowsDriver.run() }
        }, note, nil, .deliverImmediately)
    }

    static var tv: EditTextView { EditSurface.shared.textView }

    static let letterCodes: [Character: UInt16] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]
    static func fn(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }
    /// Named keys: key code, characters, and whether it is a function key (arrows are also numeric-pad keys).
    static let named: [String: (UInt16, String, NSEvent.ModifierFlags)] = [
        "return": (36, "\r", []), "enter": (76, "\u{3}", [.numericPad]), "tab": (48, "\t", []), "backspace": (51, "\u{7f}", []),
        "delete": (117, fn(NSDeleteFunctionKey), [.function]), "escape": (53, "\u{1b}", []), "space": (49, " ", []),
        "left": (123, fn(NSLeftArrowFunctionKey), [.function, .numericPad]), "right": (124, fn(NSRightArrowFunctionKey), [.function, .numericPad]),
        "down": (125, fn(NSDownArrowFunctionKey), [.function, .numericPad]), "up": (126, fn(NSUpArrowFunctionKey), [.function, .numericPad]),
        "home": (115, fn(NSHomeFunctionKey), [.function]), "end": (119, fn(NSEndFunctionKey), [.function]),
        "pageup": (116, fn(NSPageUpFunctionKey), [.function]), "pagedown": (121, fn(NSPageDownFunctionKey), [.function]),
    ]

    static func mods(_ names: [String]) -> NSEvent.ModifierFlags {
        var f: NSEvent.ModifierFlags = []
        for n in names {
            switch n {
            case "shift": f.insert(.shift)
            case "option": f.insert(.option)
            case "command": f.insert(.command)
            case "control": f.insert(.control)
            default: break
            }
        }
        return f
    }

    static func event(_ chars: String, ignoring: String, code: UInt16, flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: EditSurface.shared.panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: ignoring,
                         isARepeat: false, keyCode: code)!
    }

    /// As NSApplication hands a key to the key window: a key equivalent first, then keyDown to the first responder.
    static func dispatch(_ e: NSEvent) {
        let panel = EditSurface.shared.panel
        dispatching = e
        if !panel.performKeyEquivalent(with: e) { panel.sendEvent(e) }
        dispatching = nil
    }

    static func typeChar(_ c: Character) {
        if c == "\n" { return press("return", []) }
        if c == "\t" { return press("tab", []) }
        let lower = Character(c.lowercased())
        let shift = c.isUppercase || "!@#$%^&*()_+{}|:\"<>?~".contains(c)
        dispatch(event(String(c), ignoring: String(c), code: letterCodes[lower] ?? 0, flags: shift ? .shift : []))
    }

    static func press(_ name: String, _ modNames: [String]) {
        var flags = mods(modNames)
        if let (code, chars, extra) = named[name] {
            flags.formUnion(extra)
            var c = chars
            if name == "tab", flags.contains(.shift) { c = "\u{19}" }
            // Shift-Tab is the backtab character, even ignoring modifiers (Shift is not ignored there).
            dispatch(event(flags.contains(.command) ? chars : c, ignoring: c, code: code, flags: flags))
        } else if let ch = name.first, name.count == 1 {
            // A letter with modifiers: ⌘A, ⇧⌘Z, ⌥⌘F. The characters are what the layout gives (Command leaves the letter).
            let shown = flags.contains(.shift) ? name.uppercased() : name
            dispatch(event(shown, ignoring: flags.contains(.shift) ? name.uppercased() : name, code: letterCodes[ch] ?? 0, flags: flags))
        }
    }

    /// One step; returns the gap to wait before the next, in seconds.
    static func step(_ s: [String: Any], gap: Double) -> Double {
        if let t = s["type"] as? String {
            for c in t { typeChar(c) }
            return gap
        }
        if let k = s["key"] as? String {
            let n = s["times"] as? Int ?? 1
            for _ in 0..<n { press(k, s["mods"] as? [String] ?? []) }
            return gap
        }
        if let t = s["burst"] as? String {
            for c in t { typeChar(c) }
            return gap
        }
        if let m = s["marked"] as? String {
            tv.setMarkedText(m, selectedRange: NSRange(location: (m as NSString).length, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            return gap
        }
        if let i = s["commit"] as? String {
            tv.insertText(i, replacementRange: NSRange(location: NSNotFound, length: 0))
            return gap
        }
        if let p = s["paste"] as? String {
            board.clearContents()
            board.setString(p, forType: .string)
            return 0
        }
        if let w = s["wait"] as? Double { return w / 1000 }
        return 0
    }

    static func run() {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("cmd.json")),
              let cmd = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let n = cmd["n"] as? Int else { return }
        let gap = (cmd["gap"] as? Double ?? 30) / 1000
        var steps: [[String: Any]] = []
        // "type" steps are split into one step per character, so every key gets its own run-loop turn and gap.
        for s in cmd["steps"] as? [[String: Any]] ?? [] {
            if let t = s["type"] as? String, t.count > 1 { steps += t.map { ["type": String($0)] } } else { steps.append(s) }
        }
        let after = cmd["afterSession"] as? Int ?? -1
        let deadline = Date().addingTimeInterval(5)
        func waitSession() {
            if let s = EditSession.current, s.id > after { return next(0) }
            if Date() > deadline { return finish(n, error: "no edit session after \(after)") }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { waitSession() }
        }
        func next(_ i: Int) {
            guard i < steps.count else {
                return DispatchQueue.main.asyncAfter(deadline: .now() + (cmd["settle"] as? Double ?? 300) / 1000) { finish(n, error: nil) }
            }
            let wait = step(steps[i], gap: gap)
            if wait <= 0 { next(i + 1) } else { DispatchQueue.main.asyncAfter(deadline: .now() + wait) { next(i + 1) } }
        }
        if cmd["noSession"] as? Bool == true { next(0) } else { waitSession() }
    }

    static func finish(_ n: Int, error: String?) {
        let nonce = (try? Data(contentsOf: dir.appendingPathComponent("cmd.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["nonce"] ?? NSNull()
        let sel = tv.selectedRange()
        var r: [String: Any] = ["n": n, "text": tv.string, "selStart": sel.location, "selLen": sel.length, "marked": tv.hasMarkedText(),
                                "session": EditSession.current?.id ?? -1, "plain": tv.plain, "board": board.string(forType: .string) ?? NSNull(),
                                "orderedFront": panelOrderedFront, "nonce": nonce]
        if let error { r["error"] = error }
        let url = dir.appendingPathComponent("result.json")
        try? JSONSerialization.data(withJSONObject: r).write(to: url, options: .atomic)
    }
}

EditFlowsDriver.install()
