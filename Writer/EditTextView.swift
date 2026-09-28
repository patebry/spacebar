import AppKit
import os

private let log = Logger(subsystem: logSubsystem, category: "writer")

final class EditPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Invisible, click-through panel that holds keyboard focus while a block is edited; the preview draws the text and caret.
final class EditTextView: NSTextView {
    var onEscape: () -> Void = {}
    /// Set while a session is active; called for Backspace with an empty selection at the start of the block.
    var onMergeBackward: (() -> Void)?
    /// Set while a session is active; called for Enter that ends the block (see insertNewline).
    var onSplit: ((_ before: String, _ after: String, _ tail: String) -> Void)?
    /// Called when a merge or split gets no answer: the held keys cannot be applied safely, so the session ends.
    var onHoldTimeout: () -> Void = {}
    /// Set while a filter session is active; takes the keys FilterKeys names instead of the text.
    var onFilterKey: ((_ key: String, _ isRepeat: Bool) -> Void)?
    /// A list session: only the list keys (FilterKeys.listNames) go anywhere, Esc and Space end it (onEscape), nothing is typed
    /// and no shortcut runs.
    var listKeys = false
    var session = 0
    var firstKeyLogged = false
    /// Keys (and shortcuts) that arrive between a merge or split request and its resetEdit, replayed onto the new text. They are
    /// never applied to the old buffer: the host has already saved the change, so the buffer must not change until the reset.
    private var held: [NSEvent]?
    private var holdGeneration = 0

    override func keyDown(with event: NSEvent) {
        if !firstKeyLogged {
            firstKeyLogged = true
            log.info("lat[\(self.session)] first-key \(upMs(), format: .fixed(precision: 1)) (event \(event.timestamp * 1000, format: .fixed(precision: 1)))")
        }
        if held != nil { held!.append(event); return }
        if listKeys {
            let mods = event.modifierFlags.rawValue
            if FilterKeys.listEnds(keyCode: event.keyCode, modifiers: mods) { onEscape(); return }
            if let name = FilterKeys.name(keyCode: event.keyCode, modifiers: mods, list: true) { onFilterKey?(name, event.isARepeat) }
            return
        }
        // While an input method composes, its keys (Esc to cancel, arrows to choose, Return to commit) belong to it.
        if event.keyCode == 53, !hasMarkedText() { onEscape(); return }
        if let key = onFilterKey, !hasMarkedText(), let name = FilterKeys.name(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue) {
            key(name, event.isARepeat)
            return
        }
        super.keyDown(with: event)
    }

    override func deleteBackward(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.location == 0, sel.length == 0, let merge = onMergeBackward else { return super.deleteBackward(sender) }
        holdKeys(while: merge)
    }

    /// Holds every key from here until resetEdit (or the timeout, which ends the session) and sends `request` to the host.
    private func holdKeys(while request: () -> Void) {
        held = []
        holdGeneration += 1
        let gen = holdGeneration
        request()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.holdGeneration == gen, self.held != nil else { return }
            self.dropHeld()
            self.onHoldTimeout()
        }
    }

    /// Pasted CRLF text becomes LF, so the buffer's offsets match the text the host and page keep.
    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard let s = string as? String, s.contains("\r") else { return super.insertText(string, replacementRange: replacementRange) }
        super.insertText(s.replacingOccurrences(of: "\r\n", with: "\n"), replacementRange: replacementRange)
    }

    var isHolding: Bool { held != nil }
    /// The held event being replayed; NSApp.currentEvent is some later event then.
    private(set) var replaying: NSEvent?

    /// Ends the hold, runs `prepare` (the new buffer and caret), then replays the held keys onto it.
    func releaseHeld(after prepare: () -> Void = {}) {
        let events = held ?? []
        held = nil
        holdGeneration += 1
        prepare()
        for e in events {
            replaying = e
            if e.modifierFlags.contains(.command) { _ = performKeyEquivalent(with: e) } else { keyDown(with: e) }
        }
        replaying = nil
    }

    func dropHeld() {
        held = nil
        holdGeneration += 1
    }

    // The service has no main menu, so the standard editing shortcuts are routed here.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if held != nil, event.modifierFlags.contains(.command) { held!.append(event); return true }
        if listKeys { return true }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), let key = event.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: event) }
        let shift = flags.contains(.shift)
        if flags.isDisjoint(with: [.option, .control]), let binding = Self.commandBindings[key] {
            if let command = shift ? binding.extend : binding.move { doCommand(by: command) }
            return true
        }
        switch key {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": pasteAsPlainText(nil)
        case "z": shift ? undoManager?.redo() : undoManager?.undo()
        default: return true  // swallow everything else so no shortcut leaks to another window
        }
        return true
    }

    /// Command+arrow and Command+delete arrive as key equivalents, so keyDown's key bindings never see them; these are the
    /// standard macOS bindings for them. `extend` is the Shift variant (nil: Shift does nothing extra).
    private static let commandBindings: [String: (move: Selector?, extend: Selector?)] = {
        func key(_ c: Int) -> String { String(Character(UnicodeScalar(c)!)) }
        return [
            key(NSLeftArrowFunctionKey): (#selector(moveToLeftEndOfLine(_:)), #selector(moveToLeftEndOfLineAndModifySelection(_:))),
            key(NSRightArrowFunctionKey): (#selector(moveToRightEndOfLine(_:)), #selector(moveToRightEndOfLineAndModifySelection(_:))),
            key(NSUpArrowFunctionKey): (#selector(moveToBeginningOfDocument(_:)), #selector(moveToBeginningOfDocumentAndModifySelection(_:))),
            key(NSDownArrowFunctionKey): (#selector(moveToEndOfDocument(_:)), #selector(moveToEndOfDocumentAndModifySelection(_:))),
            key(NSDeleteCharacter): (#selector(deleteToBeginningOfLine(_:)), nil),
            key(NSDeleteFunctionKey): (#selector(deleteToEndOfLine(_:)), nil),
        ]
    }()

    private static let listItem = try! NSRegularExpression(pattern: #"^(\s*)([-*+]|(\d+)[.)])\s+(\[[ xX]\]\s+)?"#)
    private static let quote = try! NSRegularExpression(pattern: #"^\s{0,3}(?:>\s?)+"#)
    /// Blocks whose text keeps Enter as a line break: fenced code, math, indented code, raw HTML.
    private static let literal = try! NSRegularExpression(pattern: #"\A(?:\s{0,3}(?:```|~~~|\$\$)|    |\t|\s{0,3}<)"#)
    /// Blocks that Enter leaves whole, opening a paragraph below: tables (a delimiter row) and setext headings.
    private static let whole = try! NSRegularExpression(pattern: #"(?m)^(?=[^\n]*\|)[ \t]*\|?[ \t]*:?-+:?[ \t]*(?:\|[ \t]*:?-+:?[ \t]*)*\|?[ \t]*$|\n[ \t]{0,3}=+[ \t]*\z"#)

    private static func matches(_ re: NSRegularExpression, _ s: String) -> NSTextCheckingResult? {
        re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length))
    }

    /// Enter ends the block like a block editor: the text after the caret becomes a new paragraph below, shown as one new line
    /// (the blank line markdown needs between them is never part of an edited block). A list item or quote line continues with
    /// its marker; Enter on an empty one leaves the list or quote. Code, math and HTML blocks take a plain line break, and so
    /// does Shift+Enter anywhere.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        guard let split = onSplit, sel.length == 0, (replaying ?? NSApp.currentEvent)?.modifierFlags.contains(.shift) != true,
              Self.matches(Self.literal, string) == nil else { return insertText("\n", replacementRange: sel) }
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        var lineEnd = NSMaxRange(lineRange)
        if lineEnd > lineRange.location, ns.character(at: lineEnd - 1) == 10 { lineEnd -= 1 }
        let head = ns.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))
        let line = ns.substring(with: NSRange(location: lineRange.location, length: lineEnd - lineRange.location))
        let marker = Self.matches(Self.listItem, head) ?? Self.matches(Self.quote, head)
        if let m = marker {
            let prefix = (head as NSString).substring(with: m.range)
            if line.trimmingCharacters(in: .whitespaces) == prefix.trimmingCharacters(in: .whitespaces) {
                // An empty item or quote line: drop it and continue below the list in a new paragraph.
                let before = Self.trimNewlines(ns.substring(to: lineRange.location), trailing: true)
                let rest = Self.trimNewlines(ns.substring(from: lineEnd), trailing: false)
                if before.isEmpty { return holdKeys { split("", rest, "") } }
                return holdKeys { split(before, "", rest) }
            }
            var next = prefix
            if m.numberOfRanges > 3, m.range(at: 2).location != NSNotFound {
                let indent = (head as NSString).substring(with: m.range(at: 1))
                var bullet = (head as NSString).substring(with: m.range(at: 2))
                if m.range(at: 3).location != NSNotFound, let n = Int((head as NSString).substring(with: m.range(at: 3))) {
                    bullet = "\(n + 1)" + String(bullet.last!)
                }
                next = "\(indent)\(bullet) " + (m.range(at: 4).location != NSNotFound ? "[ ] " : "")
            }
            return insertText("\n" + next, replacementRange: sel)
        }
        if Self.matches(Self.whole, string) != nil { return holdKeys { split(string, "", "") } }
        let before = Self.trimNewlines(ns.substring(to: sel.location), trailing: true)
        let after = Self.trimNewlines(ns.substring(from: NSMaxRange(sel)), trailing: false)
        holdKeys { split(before, after, "") }
    }

    private static func trimNewlines(_ s: String, trailing: Bool) -> String {
        var s = Substring(s)
        if trailing { while s.last == "\n" { s.removeLast() } } else { while s.first == "\n" { s.removeFirst() } }
        return String(s)
    }
}
