// Checks FilterKeys in Shared/WriterProtocol.swift: which keys the writer's panel forwards to the sidebar during a filter session,
// what text it sends, and when Esc ends the session. Build and run with test/filterkeys/run.sh. Opens no window.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

// Arrow keys carry the function and numeric-pad flags; those do not count as modifiers.
let arrowFlags: UInt = 1 << 23 | 1 << 21
check("↑ is up", FilterKeys.name(keyCode: 126, modifiers: arrowFlags) == "up")
check("↓ is down", FilterKeys.name(keyCode: 125, modifiers: arrowFlags) == "down")
check("Home and End", FilterKeys.name(keyCode: 115, modifiers: 1 << 23) == "home" && FilterKeys.name(keyCode: 119, modifiers: 1 << 23) == "end")
check("Return and keypad Enter", FilterKeys.name(keyCode: 36, modifiers: 0) == "return" && FilterKeys.name(keyCode: 76, modifiers: 1 << 21) == "return")
check("caps lock does not count", FilterKeys.name(keyCode: 125, modifiers: arrowFlags | 1 << 16) == "down")
for (flag, name) in [(1 << 17, "shift"), (1 << 18, "control"), (1 << 19, "option"), (1 << 20, "command")] as [(UInt, String)] {
    check("\(name)+↓ stays in the field", FilterKeys.name(keyCode: 125, modifiers: arrowFlags | flag) == nil)
}
for (code, name) in [(49, "Space"), (123, "←"), (124, "→"), (53, "Esc"), (48, "Tab"), (51, "Delete"), (0, "A")] as [(UInt16, String)] {
    check("\(name) stays in the field", FilterKeys.name(keyCode: code, modifiers: 0) == nil)
}
let named = Set([126, 125, 115, 119, 36, 76].compactMap { FilterKeys.name(keyCode: $0, modifiers: 0) })
check("every forwarded name is one the extension accepts", named == FilterKeys.names)

check("plain text passes", FilterKeys.clean("Read me.md") == "Read me.md")
check("a pasted line break goes", FilterKeys.clean("one\ntwo\r\nthree\tfour") == "onetwothreefour")
check("other control characters go", FilterKeys.clean("a\u{0}b\u{1B}[31mc\u{7F}") == "ab[31mc")
check("accents and emoji stay", FilterKeys.clean("café 🚀") == "café 🚀")
check("cut to maxLength", FilterKeys.clean(String(repeating: "x", count: 1000)).count == FilterKeys.maxLength)
check("cut on a scalar, never mid-character", FilterKeys.clean(String(repeating: "é", count: 300)).unicodeScalars.count == FilterKeys.maxLength)

// A list session (a click on a row): ← and → move through the tree too; Esc and Space end it.
check("list: ← and → are list keys", FilterKeys.name(keyCode: 123, modifiers: arrowFlags, list: true) == "left"
      && FilterKeys.name(keyCode: 124, modifiers: arrowFlags, list: true) == "right")
check("list: the filter's keys too", [126, 125, 115, 119, 36, 76].allSatisfy { FilterKeys.name(keyCode: UInt16($0), modifiers: 0, list: true) != nil })
check("list: Shift+← or Command+→ are nothing", FilterKeys.name(keyCode: 123, modifiers: arrowFlags | 1 << 17, list: true) == nil
      && FilterKeys.name(keyCode: 124, modifiers: arrowFlags | 1 << 20, list: true) == nil)
check("list: Space, letters and Tab are not list keys", [49, 0, 48].allSatisfy { FilterKeys.name(keyCode: UInt16($0), modifiers: 0, list: true) == nil })
let listNamed = Set([126, 125, 115, 119, 36, 76, 123, 124].compactMap { FilterKeys.name(keyCode: UInt16($0), modifiers: 0, list: true) })
check("list: every forwarded name is one the extension accepts", listNamed == FilterKeys.listNames && FilterKeys.names.isSubset(of: FilterKeys.listNames))
check("list: Esc and Space end it", FilterKeys.listEnds(keyCode: 53, modifiers: 0) && FilterKeys.listEnds(keyCode: 49, modifiers: 0))
check("list: ⌘Space and other keys do not", !FilterKeys.listEnds(keyCode: 49, modifiers: 1 << 20) && !FilterKeys.listEnds(keyCode: 125, modifiers: arrowFlags)
      && !FilterKeys.listEnds(keyCode: 0, modifiers: 0))

check("the list takes the keys again after Esc leaves an edit or the filter", FilterKeys.relists(afterEnding: "escape", list: false))
check("not after Esc or Space in a list session: those hand the keys to Quick Look", !FilterKeys.relists(afterEnding: "escape", list: true))
check("not after the keyboard went elsewhere", ["blur", "app-activated", "not-key", "host", "replaced", "disconnected", "host-gone", "hold-timeout"]
      .allSatisfy { !FilterKeys.relists(afterEnding: $0, list: false) && !FilterKeys.relists(afterEnding: $0, list: true) })

check("Esc on text clears it", !FilterKeys.escapeEnds(text: "abc"))
check("Esc on an empty field ends the session", FilterKeys.escapeEnds(text: ""))

print(failures == 0 ? "\nall filter key checks passed" : "\n\(failures) filter key checks failed")
exit(failures == 0 ? 0 : 1)
