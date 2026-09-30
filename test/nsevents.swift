import AppKit

/// Trackpad and mouse NSEvents for a harness's own window, made from CGEvents as the window server's arrive (the gesture fields
/// were found by experiment) and meant for NSApp.sendEvent, the path real input takes. Nothing is posted to the system.
/// Points are in the window's coordinates, from its bottom left.
enum Synth {
    private typealias SetWindowLocation = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation = unsafeBitCast(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGEventSetWindowLocation"), to: SetWindowLocation.self)

    private static func place(_ e: CGEvent, _ w: NSWindow, _ p: NSPoint) {
        e.setIntegerValueField(CGEventField(rawValue: 51)!, value: Int64(w.windowNumber))
        setWindowLocation(e, CGPoint(x: p.x, y: w.frame.height - p.y))
    }

    private static func cgPhase(_ phase: NSEvent.Phase) -> Int64 {
        switch phase {
        case .began: return 1
        case .changed: return 2
        case .ended: return 4
        case .cancelled: return 8
        case .mayBegin: return 128
        default: return 0
        }
    }

    private static func gesture(_ hid: Int64, _ w: NSWindow, _ p: NSPoint, phase: NSEvent.Phase = [], value: Double = 0) -> NSEvent {
        let e = CGEvent(source: nil)!
        e.type = CGEventType(rawValue: 29)!
        e.setIntegerValueField(CGEventField(rawValue: 110)!, value: hid)
        e.setDoubleValueField(CGEventField(rawValue: 113)!, value: value)
        e.setIntegerValueField(CGEventField(rawValue: 132)!, value: cgPhase(phase))
        place(e, w, p)
        return NSEvent(cgEvent: e)!
    }

    /// A pinch: began, `steps` changes of `by` each (0.1 is a tenth larger), ended.
    static func pinch(_ w: NSWindow, at p: NSPoint, by m: Double, steps: Int = 5) -> [NSEvent] {
        [gesture(8, w, p, phase: .began)] + (0..<steps).map { _ in gesture(8, w, p, phase: .changed, value: m) } + [gesture(8, w, p, phase: .ended)]
    }

    /// A two-finger double tap.
    static func smartMagnify(_ w: NSWindow, at p: NSPoint) -> NSEvent { gesture(22, w, p) }

    /// Two fingers on the trackpad, moving the content by (dx, dy) points in `steps` (positive dy shows what is above), or a
    /// mouse wheel's notch when `precise` is false.
    static func scroll(_ w: NSWindow, at p: NSPoint, dx: Double = 0, dy: Double, steps: Int = 5, precise: Bool = true, control: Bool = false) -> [NSEvent] {
        let n = precise ? steps : 1
        return (0..<n).map { i in
            let e = CGEvent(scrollWheelEvent2Source: nil, units: precise ? .pixel : .line, wheelCount: 2,
                            wheel1: Int32(dy / Double(n)), wheel2: Int32(dx / Double(n)), wheel3: 0)!
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
            if precise { e.setIntegerValueField(.scrollWheelEventScrollPhase, value: i == 0 ? 1 : 2) }
            if control { e.flags = .maskControl }
            place(e, w, p)
            return NSEvent(cgEvent: e)!
        } + (precise ? [{ let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0)!
            e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            e.setIntegerValueField(.scrollWheelEventScrollPhase, value: 4)
            if control { e.flags = .maskControl }
            place(e, w, p)
            return NSEvent(cgEvent: e)! }()] : [])
    }

    /// Down and up, the `clicks`-th click of a series; a double-click is `click(…, 1) + click(…, 2)`.
    static func click(_ w: NSWindow, at p: NSPoint, _ clicks: Int = 1) -> [NSEvent] {
        [NSEvent.EventType.leftMouseDown, .leftMouseUp].map {
            NSEvent.mouseEvent(with: $0, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: w.windowNumber,
                               context: nil, eventNumber: 0, clickCount: clicks, pressure: $0 == .leftMouseDown ? 1 : 0)!
        }
    }

    static func send(_ events: [NSEvent], pause: Double = 0.01) {
        for e in events {
            NSApp.sendEvent(e)
            RunLoop.main.run(until: Date().addingTimeInterval(pause))
        }
    }
}
