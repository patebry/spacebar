// The Space panel as a real window, parked off screen (test/offscreen.swift): the frame it is given is the frame it keeps, through
// showing a file, layout, closing and opening again. A preferred content size on the panel's controller once overrode every frame
// (AppKit turns it into constraints at priority 501), so remembered sizes and the default placement never applied.
import Cocoa
import WebKit

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> Any = "") {
    print("\(ok ? "PASS" : "FAIL") window: \(name)\(ok ? "" : " \(detail())")")
    if !ok { failures += 1 }
    fflush(stdout)
}
func spin(_ s: Double) { let end = Date().addingTimeInterval(s); while Date() < end { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.01))) } }
func spin(until s: Double, _ done: () -> Bool) { let end = Date().addingTimeInterval(s); while !done() && Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01)) } }

WebHost.pageHost = "panel"
_ = NSApplication.shared
OffScreen.install()
NSApp.setActivationPolicy(.accessory)
let first = NSRect(x: -20000, y: -20000, width: 1000, height: 600)
Viewer.parkedFrame = first
let viewer = Viewer.shared
let panel = viewer.panel

spin(until: 15) { WebHost.shared.ready }
guard WebHost.shared.ready else { print("FAIL window: the page never became ready"); exit(1) }

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let notes = dir.appendingPathComponent("Notes.md"), other = dir.appendingPathComponent("Other.md")
try! "# Notes\n\nSome text.\n".write(to: notes, atomically: true, encoding: .utf8)
try! "# Other\n\nMore text.\n".write(to: other, atomically: true, encoding: .utf8)

var shown = 0
func show(_ url: URL) {
    shown += 1
    let id = shown
    viewer.show([url.path], requestID: id) { _ in }
    spin(until: 5) { panel.isVisible && panel.alphaValue == 1 }
    spin(0.5)
}

show(notes)
check("shown at the frame it was given", panel.isVisible && panel.frame == first, panel.frame)
let sizing = (panel.contentView?.constraints ?? []).filter { ($0.identifier ?? "").hasPrefix("NSViewController.preferredContentSize") }
check("the content view has no preferred-size constraints", sizing.isEmpty, sizing)
spin(1)
check("still that frame after layout and a second", panel.frame == first, panel.frame)

let resized = NSRect(x: -20000, y: -20000, width: 1180, height: 640)
panel.setFrame(resized, display: true)
spin(0.5)
check("a resize while open holds", panel.frame == resized, panel.frame)
show(other)
check("showing another file keeps the resized frame", panel.frame == resized, panel.frame)

viewer.close()
spin(0.5)
check("closed", !panel.isVisible)
let next = NSRect(x: -21000, y: -20500, width: 860, height: 540)
Viewer.parkedFrame = next
show(notes)
check("opened again at the new frame, not the controller's size", panel.frame == next, panel.frame)
viewer.close()
spin(0.3)

print(failures == 0 ? "panel window: all passed" : "panel window: \(failures) failed")
exit(failures == 0 ? 0 : 1)
