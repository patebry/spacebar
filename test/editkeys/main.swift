// Sends Command shortcuts to the writer's edit text view in-process, in a panel that is never shown, and checks the caret,
// selection and text. Build and run with test/editkeys/run.sh. The general pasteboard is swapped for a private one, so the
// user's clipboard is never read or written.
import AppKit
import ObjectiveC

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let privateBoard = NSPasteboard(name: NSPasteboard.Name("md.spacebar.test.editkeys-\(UUID().uuidString)"))
extension NSPasteboard {
    @objc class var testGeneral: NSPasteboard { privateBoard }
}
method_exchangeImplementations(class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.general))!,
                               class_getClassMethod(NSPasteboard.self, #selector(getter: NSPasteboard.testGeneral))!)
check("pasteboard is private", NSPasteboard.general.name == privateBoard.name)

NSApplication.shared.setActivationPolicy(.prohibited)

final class SelectionCounter: NSObject, NSTextViewDelegate {
    var changes = 0
    func textViewDidChangeSelection(_ notification: Notification) { changes += 1 }
}

let frame = NSRect(x: 0, y: 0, width: 400, height: 24)
let panel = EditPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
let tv = EditTextView(frame: frame)
tv.isRichText = false
tv.allowsUndo = true
tv.font = .systemFont(ofSize: 15)
panel.contentView = tv
let counter = SelectionCounter()
tv.delegate = counter
check("panel is never shown", !panel.isVisible)

let arrowFlags: NSEvent.ModifierFlags = [.function, .numericPad]
func press(_ scalar: Int, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, function: Bool = true) -> Bool {
    let chars = String(Character(UnicodeScalar(scalar)!))
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags.union(function ? arrowFlags : []), timestamp: 0,
                             windowNumber: panel.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                             isARepeat: false, keyCode: keyCode)!
    return tv.performKeyEquivalent(with: e)
}
func letter(_ c: Character, _ flags: NSEvent.ModifierFlags = [.command]) -> Bool {
    press(Int(c.unicodeScalars.first!.value), 0, flags, function: false)
}
func set(_ text: String, caret: Int, length: Int = 0) {
    tv.setPlain(tv.plain)  // as a new session does: nothing learned from the last text
    tv.string = text
    tv.setSelectedRange(NSRange(location: caret, length: length))
    counter.changes = 0
}
func spin() { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
let left = NSLeftArrowFunctionKey, right = NSRightArrowFunctionKey, up = NSUpArrowFunctionKey, down = NSDownArrowFunctionKey

// Two paragraphs: "first line" (0..<10), "\n", "second line" (11..<22).
let doc = "first line\nsecond line"
set(doc, caret: 15)
check("Cmd+Left goes to the start of the line", press(left, 123, .command) && tv.selectedRange() == NSRange(location: 11, length: 0))
check("caret change is reported to the delegate", counter.changes > 0)
set(doc, caret: 15)
check("Cmd+Right goes to the end of the line", press(right, 124, .command) && tv.selectedRange() == NSRange(location: 22, length: 0))
set(doc, caret: 15)
check("Cmd+Up goes to the start of the text", press(up, 126, .command) && tv.selectedRange() == NSRange(location: 0, length: 0))
set(doc, caret: 3)
check("Cmd+Down goes to the end of the text", press(down, 125, .command) && tv.selectedRange() == NSRange(location: 22, length: 0))

set(doc, caret: 15)
check("Cmd+Shift+Left selects to the start of the line", press(left, 123, [.command, .shift]) && tv.selectedRange() == NSRange(location: 11, length: 4))
check("selection change is reported to the delegate", counter.changes > 0)
set(doc, caret: 15)
check("Cmd+Shift+Right selects to the end of the line", press(right, 124, [.command, .shift]) && tv.selectedRange() == NSRange(location: 15, length: 7))
set(doc, caret: 15)
check("Cmd+Shift+Up selects to the start of the text", press(up, 126, [.command, .shift]) && tv.selectedRange() == NSRange(location: 0, length: 15))
set(doc, caret: 3)
check("Cmd+Shift+Down selects to the end of the text", press(down, 125, [.command, .shift]) && tv.selectedRange() == NSRange(location: 3, length: 19))

// Visual lines: a paragraph wider than the view wraps, and Cmd+Right stops at the end of the first line on screen.
let long = String(repeating: "word ", count: 40)
set(long, caret: 0)
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
_ = press(right, 124, .command)
let end = tv.selectedRange().location
check("Cmd+Right stops at the end of the visual line, not the paragraph (at \(end) of \(long.count))", end > 0 && end < long.count - 1)

set(doc, caret: 15)
check("Cmd+Backspace deletes to the start of the line", press(NSDeleteCharacter, 51, .command, function: false) && tv.string == "first line\nnd line"
      && tv.selectedRange() == NSRange(location: 11, length: 0))
set(doc, caret: 15)
check("Cmd+Delete deletes to the end of the line", press(NSDeleteFunctionKey, 117, .command) && tv.string == "first line\nseco"
      && tv.selectedRange() == NSRange(location: 15, length: 0))
var merged = false
tv.onMergeBackward = { merged = true }
set(doc, caret: 0)
_ = press(NSDeleteCharacter, 51, .command, function: false)
check("Cmd+Backspace at the start of the block leaves the text alone (\(merged ? "merge requested" : "no merge"))", tv.string == doc)
tv.onMergeBackward = nil
tv.dropHeld()

set(doc, caret: 15)
check("Option+Cmd+Left is not taken as Cmd+Left", press(left, 123, [.command, .option]) && tv.selectedRange() == NSRange(location: 15, length: 0))

// The shortcuts that already worked.
set(doc, caret: 0)
check("Cmd+A selects all", letter("a") && tv.selectedRange() == NSRange(location: 0, length: 22))
set(doc, caret: 0, length: 5)
check("Cmd+C copies", letter("c") && NSPasteboard.general.string(forType: .string) == "first" && tv.string == doc)
check("Cmd+X cuts", letter("x") && NSPasteboard.general.string(forType: .string) == "first" && tv.string == " line\nsecond line")
spin()
tv.setSelectedRange(NSRange(location: tv.string.count, length: 0))
check("Cmd+V pastes", letter("v") && tv.string == " line\nsecond linefirst")
spin()
check("Cmd+Z undoes the paste", letter("z") && tv.string == " line\nsecond line")
spin()
check("Cmd+Shift+Z redoes it", letter("z", [.command, .shift]) && tv.string == " line\nsecond linefirst")
check("panel is still hidden", !panel.isVisible)

// A list session (a click on a sidebar row): only the list keys go anywhere; nothing is typed, no shortcut runs, and Esc or Space
// ends it. Keys go straight to keyDown, in-process; nothing is posted to the system.
func key(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    tv.keyDown(with: e)
}
var listed: [String] = [], ends = 0
set("", caret: 0)
tv.listKeys = true
tv.onFilterKey = { k, _ in listed.append(k) }
tv.onEscape = { ends += 1 }
let arrow = { (s: Int) in String(Character(UnicodeScalar(s)!)) }
key(arrow(down), 125, arrowFlags); key(arrow(up), 126, arrowFlags); key(arrow(left), 123, arrowFlags); key(arrow(right), 124, arrowFlags)
key("\r", 36); key(arrow(NSHomeFunctionKey), 115, [.function]); key(arrow(NSEndFunctionKey), 119, [.function])
check("list: ↓ ↑ ← → Return Home End are forwarded", listed == ["down", "up", "left", "right", "return", "home", "end"])
listed = []
key("a", 0); key("Z", 6, [.shift]); key("\t", 48); key(arrow(down), 125, arrowFlags.union(.shift))
check("list: letters, Tab and Shift+↓ type nothing and go nowhere", listed.isEmpty && tv.string.isEmpty && ends == 0)
NSPasteboard.general.clearContents()
NSPasteboard.general.setString("pasted", forType: .string)
check("list: Command shortcuts are swallowed (no paste)", letter("v") && letter("a") && tv.string.isEmpty)
check("list: a plain key offered as a key equivalent is left for keyDown (↓, Esc, Space, a letter)",
      !press(down, 125, []) && !press(0x1b, 53, [], function: false) && !press(0x20, 49, [], function: false) && !letter("q", []))
key(" ", 49)
check("list: Space ends it", ends == 1 && tv.string.isEmpty)
key("\u{1b}", 53)
check("list: Esc ends it", ends == 2)
tv.listKeys = false
tv.onFilterKey = nil
tv.onEscape = {}
check("after a list session, Command shortcuts work again", letter("v") && tv.string == "pasted")

// A text file (plain): Enter and Backspace edit the text as it is, Enter keeps the indentation, Tab types a tab, lines do not wrap.
func plainSession() {
    tv.setPlain(true)
    tv.onSplit = nil
    tv.onMergeBackward = nil
    tv.onEscape = { ends += 1 }
}
/// Through the key bindings, as keyDown does once the panel is key (a panel that is never shown has no input context of its own).
func type(_ chars: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) {
    let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                             characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: keyCode)!
    tv.interpretKeyEvents([e])
}
plainSession()
check("plain: monospaced and unwrapped", tv.plain && tv.font?.isFixedPitch == true && tv.textContainer?.widthTracksTextView == false)
let code = "func f() {\n    let x = 1\n}\n"
set(code, caret: 24)
type("\r", 36)
check("plain: Enter inserts a line that keeps the indentation", tv.string == "func f() {\n    let x = 1\n    \n}\n" && tv.selectedRange() == NSRange(location: 29, length: 0))
set(code, caret: 11)
type("\u{7f}", 51)
check("plain: Backspace at a line's start joins it to the line above", tv.string == "func f() {    let x = 1\n}\n")
set(code, caret: 0)
type("\u{7f}", 51)
check("plain: Backspace at the start of the file does nothing", tv.string == code)
set(code, caret: 15)
type("\t", 48)
check("plain: Tab types a tab", tv.string == "func f() {\n    \tlet x = 1\n}\n")
set(code, caret: 15)
type("\r", 36, [.shift])
check("plain: Shift+Enter is a plain line break too", tv.string.hasPrefix("func f() {\n    \n    let x"))
let longLine = String(repeating: "word ", count: 40) + "\nnext"
set(longLine, caret: 0)
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
_ = press(right, 124, .command)
check("plain: Cmd+Right goes to the end of the whole line (no wrapping)", tv.selectedRange().location == longLine.count - 5)
set("func f() {\n}\n", caret: 10)
type("\r", 36)
check("plain: Enter after { goes one step deeper (four spaces with no indentation to copy)", tv.string == "func f() {\n    \n}\n"
      && tv.selectedRange().location == 15)
set("{\n  \"a\": []\n}\n", caret: 10)
type("\r", 36)
check("plain: Enter between [ and ] puts ] on a line of its own, a step (the file's two spaces)",
      tv.string == "{\n  \"a\": [\n    \n  ]\n}\n" && tv.selectedRange().location == 15)
set("if x {\n\ty\n}\n", caret: 9)
type("\r", 36)
check("plain: Enter keeps a tab indentation", tv.string == "if x {\n\ty\n\t\n}\n")
set("a\n    b\n        c\n", caret: 16)
type("\u{19}", 48, [.shift])
check("plain: Shift-Tab takes one step (the file's four spaces) off the line and types nothing", tv.string == "a\n    b\n    c\n"
      && tv.selectedRange().location == 12)
set("a\n    b", caret: 0, length: 4)
type("\u{19}", 48, [.shift])
check("plain: Shift-Tab keeps the selected text that was not indentation selected", tv.string == "a\nb" && tv.selectedRange() == NSRange(location: 0, length: 2))
set("func main() {\n\tx()\n}\n\nfunc g() {\n}\n", caret: 32)
type("\r", 36)
check("plain: Enter after { in a tab-indented file indents with a tab", tv.string == "func main() {\n\tx()\n}\n\nfunc g() {\n\t\n}\n")
set("class A:\n    def f(self):\n        return (1 +\n          2)\n    x = f(", caret: 69)
type("\r", 36)
check("plain: the step is the file's usual one, not a smaller continuation indent", tv.string.hasSuffix("    x = f(\n        "))
set("\tx\n  y\nz\n", caret: 0, length: 9)
type("\u{19}", 48, [.shift])
check("plain: Shift-Tab over a selection outdents every line it touches", tv.string == "x\ny\nz\n")
set("none\n", caret: 2)
type("\u{19}", 48, [.shift])
check("plain: Shift-Tab on a line with no indentation does nothing", tv.string == "none\n" && tv.selectedRange().location == 2)
set("abc\nabcdef\nabcdef", caret: 5)
type(arrow(down), 125, arrowFlags)
check("plain: ↓ keeps the column", tv.selectedRange().location == 12)
set(code, caret: 4)
check("plain: Cmd+A, Cmd+Z work as in a block", letter("a") && tv.selectedRange() == NSRange(location: 0, length: (code as NSString).length))
ends = 0
key("\u{1b}", 53)
check("plain: Esc ends the edit", ends == 1)
tv.setPlain(false)
var splitAsked = 0
tv.onSplit = { _, _, _ in splitAsked += 1 }
set("", caret: 0)
type("\r", 36)
check("block: Enter in a block with no text yet is a line break, not a split", tv.string == "\n" && splitAsked == 0 && !tv.isHolding)
set("```\n    y\n```", caret: 9)
type("\r", 36)
check("block: Enter in a code fence keeps the line's indentation", tv.string == "```\n    y\n    \n```" && splitAsked == 0)
set("Para", caret: 4)
type("\r", 36)
check("block: Enter at the end of a paragraph asks for a split", splitAsked == 1 && tv.isHolding)
tv.dropHeld()
tv.onSplit = nil
check("a Markdown block again: proportional and wrapped", !tv.plain && tv.font?.isFixedPitch == false && tv.textContainer?.widthTracksTextView == true)
set(long, caret: 0)
tv.layoutManager!.ensureLayout(for: tv.textContainer!)
_ = press(right, 124, .command)
check("a Markdown block again: Cmd+Right stops at the visual line", tv.selectedRange().location < long.count - 1)

// ⌘F, ⌥⌘F and ⌘C in a list session go to the page as commands; nothing is copied or typed.
set("", caret: 0)
listed = []
tv.listKeys = true
tv.onFilterKey = { k, _ in listed.append(k) }
NSPasteboard.general.clearContents()
check("list: ⌘F, ⌥⌘F and ⌘C are find, filter and copy", letter("f") && letter("f", [.command, .option]) && letter("c") && listed == ["find", "filter", "copy"]
      && NSPasteboard.general.string(forType: .string) == nil && tv.string.isEmpty)
listed = []
check("list: ⌘V and ⇧⌘F are swallowed and go nowhere", letter("v") && letter("F", [.command, .shift]) && listed.isEmpty && tv.string.isEmpty)
tv.listKeys = false

// The find field: Return and Shift+Return (⌘G, ⇧⌘G) step through the matches; the text is the field's; Esc ends it.
set("needle", caret: 6)
listed = []
ends = 0
tv.findKeys = true
tv.onEscape = { ends += 1 }
key("\r", 36); key("\r", 36, [.shift]); key("\r", 76, [.numericPad])
check("find: Return is next, Shift+Return prev, and neither types", listed == ["next", "prev", "next"] && tv.string == "needle")
listed = []
check("find: ⌘G next, ⇧⌘G prev", letter("g") && letter("G", [.command, .shift]) && listed == ["next", "prev"])
listed = []
key(arrow(down), 125, arrowFlags); key(arrow(NSHomeFunctionKey), 115, [.function])
check("find: the arrows and Home stay in the field", listed.isEmpty)
NSPasteboard.general.setString("pasted", forType: .string)
check("find: ⌘A and ⌘V still edit the field", letter("a") && letter("v") && tv.string == "pasted" && listed.isEmpty)
key("\u{1b}", 53)
check("find: Esc ends it", ends == 1)
tv.findKeys = false
tv.onFilterKey = nil
tv.onEscape = {}

// An edit, of a Markdown block or a whole text file: Space is typing, in Quick Look (no helper) as in the Space panel. keyDown
// leaves it to the text system, which types it.
tv.onEscape = { ends += 1 }
ends = 0
for plain in [false, true] {
    tv.setPlain(plain)
    set("", caret: 0)
    key(" ", 49)
    check("\(plain ? "plain" : "block"): keyDown ends nothing on Space", ends == 0)
    set("", caret: 0)
    type("a", 0); type(" ", 49); type("b", 11)
    check("\(plain ? "plain" : "block"): a, Space, b types \"a b\"", tv.string == "a b" && ends == 0)
}
tv.setPlain(false)
tv.onEscape = {}

privateBoard.releaseGlobally()
print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") edit key checks")
exit(failures == 0 ? 0 : 1)
