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
    /// A find session: Return and Shift+Return (⌘G and ⇧⌘G too) go to onFilterKey as FilterKeys.findNames.
    var findKeys = false
    /// ⌘F while an edit holds the keys: the edit ends (its text is already saved) and the page opens find.
    var onFind: (() -> Void)?
    var session = 0
    var firstKeyLogged = false
    /// A whole text file rather than a Markdown block (see setPlain).
    private(set) var plain = false
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
        if let key = onFilterKey, !hasMarkedText(),
           let name = findKeys ? FilterKeys.findName(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue)
                               : FilterKeys.name(keyCode: event.keyCode, modifiers: event.modifierFlags.rawValue) {
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
        // A plain key may come here before keyDown: only Command shortcuts are swallowed, so the list keys, Esc and Space still arrive.
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        if listKeys, event.modifierFlags.contains(.command) {
            if let name = FilterKeys.command(chars, modifiers: event.modifierFlags.rawValue, find: false) { onFilterKey?(name, event.isARepeat) }
            return true
        }
        if findKeys, let key = onFilterKey, let name = FilterKeys.command(chars, modifiers: event.modifierFlags.rawValue, find: true) {
            key(name, event.isARepeat)
            return true
        }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command), !chars.isEmpty else { return super.performKeyEquivalent(with: event) }
        let key = chars
        let shift = flags.contains(.shift)
        if flags.isDisjoint(with: [.option, .control]), let binding = Self.commandBindings[key] {
            if let command = shift ? binding.extend : binding.move { doCommand(by: command) }
            return true
        }
        switch key {
        case "f" where flags.isDisjoint(with: [.shift, .option, .control]): onFind?()
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

    /// A text file: monospaced and unwrapped like the page's code view, so ↑ and ↓ keep the column and Command-arrows reach the
    /// ends of the real line; a Markdown block: the proportional font, wrapped at the block's width.
    func setPlain(_ on: Bool) {
        plain = on
        indentStep = nil
        font = on ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 15)
        layoutManager?.allowsNonContiguousLayout = on
        isHorizontallyResizable = on
        textContainer?.widthTracksTextView = !on
        textContainer?.containerSize = NSSize(width: on ? CGFloat.greatestFiniteMagnitude : frame.width, height: CGFloat.greatestFiniteMagnitude)
    }

    /// Enter ends the block like a block editor: the text after the caret becomes a new paragraph below, shown as one new line
    /// (the blank line markdown needs between them is never part of an edited block). A list item or quote line continues with
    /// its marker; Enter on an empty one leaves the list or quote. Code, math and HTML blocks take a line break that keeps the
    /// indentation, as a text file does; elsewhere Shift+Enter, and Enter in a block with no text yet (so a second Enter shows a
    /// blank line), take a plain line break.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        let literal = !plain && Self.matches(Self.literal, string) != nil
        if plain || literal { return indentedNewline() }
        guard let split = onSplit, sel.length == 0, (replaying ?? NSApp.currentEvent)?.modifierFlags.contains(.shift) != true,
              string.contains(where: { !$0.isWhitespace }) else { return insertText("\n", replacementRange: sel) }
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

    /// The indentation one level adds in this text: the file's own step, else four spaces.
    private var indentStep: String?

    /// A line break that keeps the line's indentation, as a code editor does. After an opening bracket the new line is one step
    /// deeper, and a closing bracket right after the caret goes to a line of its own at the old depth.
    private func indentedNewline() {
        let ns = string as NSString
        let sel = selectedRange()
        let start = ns.lineRange(for: NSRange(location: sel.location, length: 0)).location
        let head = ns.substring(with: NSRange(location: start, length: sel.location - start))
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        guard let open = head.last(where: { !$0.isWhitespace }), let close = Self.pairs[open] else {
            return insertText("\n" + indent, replacementRange: sel)
        }
        let inner = "\n" + indent + step(for: indent)
        let end = NSMaxRange(sel)
        if end < ns.length, ns.substring(with: NSRange(location: end, length: 1)) == String(close) {
            insertText(inner + "\n" + indent, replacementRange: sel)
            return setSelectedRange(NSRange(location: sel.location + (inner as NSString).length, length: 0))
        }
        insertText(inner, replacementRange: sel)
    }

    private static let pairs: [Character: Character] = ["{": "}", "[": "]", "(": ")"]

    /// One indentation step: a tab where the line, or most of the text, is indented with tabs; else the commonest step by which
    /// one line's space indentation exceeds the line before it (2 to 8), else four spaces.
    private func step(for indent: String) -> String {
        if indent.hasPrefix("\t") { return "\t" }
        if let s = indentStep { return s }
        var tabs = 0, spaces = 0, prev = 0
        var steps: [Int: Int] = [:]
        (string as NSString).enumerateSubstrings(in: NSRange(location: 0, length: min((string as NSString).length, 1 << 16)), options: .byLines) { line, _, _, _ in
            guard let line, line.contains(where: { !$0.isWhitespace }) else { return }
            if line.hasPrefix("\t") { tabs += 1; return }
            let n = line.prefix { $0 == " " }.count
            if n > 0 { spaces += 1 }
            if (2...8).contains(n - prev) { steps[n - prev, default: 0] += 1 }
            prev = n
        }
        let s = tabs > spaces ? "\t" : String(repeating: " ", count: steps.max { ($0.value, -$0.key) < ($1.value, -$1.key) }?.key ?? 4)
        if plain { indentStep = s }
        return s
    }

    /// Shift-Tab takes one step of indentation off each line the selection touches, and never types anything.
    override func insertBacktab(_ sender: Any?) {
        let ns = string as NSString
        let sel = selectedRange()
        // A selection that ends at a line's start (⇧↓) does not take that line in.
        let touched = sel.length > 0 && ns.character(at: NSMaxRange(sel) - 1) == 10 ? NSRange(location: sel.location, length: sel.length - 1) : sel
        let lines = ns.lineRange(for: touched)
        let unit = step(for: "").count
        var out = "", removedBefore = 0, removedInside = 0
        var at = lines.location
        ns.substring(with: lines).split(separator: "\n", omittingEmptySubsequences: false).enumerated().forEach { i, line in
            if i > 0 { out += "\n"; at += 1 }
            let cut = line.hasPrefix("\t") ? 1 : min(line.prefix { $0 == " " }.count, unit)
            out += line.dropFirst(cut)
            if at < sel.location { removedBefore += min(cut, sel.location - at) }
            removedInside += max(0, min(at + cut, NSMaxRange(sel)) - max(at, sel.location))
            at += line.utf16.count
        }
        guard out != ns.substring(with: lines), shouldChangeText(in: lines, replacementString: out) else { return }
        textStorage?.replaceCharacters(in: lines, with: out)
        didChangeText()
        let loc = sel.location - removedBefore
        setSelectedRange(NSRange(location: loc, length: sel.length - removedInside))
    }

    private static func trimNewlines(_ s: String, trailing: Bool) -> String {
        var s = Substring(s)
        if trailing { while s.last == "\n" { s.removeLast() } } else { while s.first == "\n" { s.removeFirst() } }
        return String(s)
    }
}
