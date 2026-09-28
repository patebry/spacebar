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
key(" ", 49)
check("list: Space ends it", ends == 1 && tv.string.isEmpty)
key("\u{1b}", 53)
check("list: Esc ends it", ends == 2)
tv.listKeys = false
tv.onFilterKey = nil
tv.onEscape = {}
check("after a list session, Command shortcuts work again", letter("v") && tv.string == "pasted")

privateBoard.releaseGlobally()
print("\n\(failures == 0 ? "all" : "\(failures) FAILED of") edit key checks")
exit(failures == 0 ? 0 : 1)
