import Cocoa

/// The Space panel's size and place, remembered for each display in the viewer's own defaults (never settings.json).
enum PanelFrame {
    static let defaultsKey = "panelFrames"

    /// A display's lasting name: its UUID, which survives a restart and a reconnection where its display ID may not.
    static func key(for screen: NSScreen) -> String? {
        guard let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(n.uint32Value)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    /// Where the panel opens on a screen whose visible frame is `visible`: the saved frame moved and shrunk into it (the screen
    /// may have changed size since), else about 60% of it, between 640×480 and 1200×900, centred.
    static func placement(saved: NSRect?, visible vf: NSRect, minSize: NSSize) -> NSRect {
        guard let s = saved else {
            let w = min(max(vf.width * 0.6, 640), 1200, vf.width), h = min(max(vf.height * 0.6, 480), 900, vf.height)
            return NSRect(x: vf.midX - w / 2, y: vf.midY - h / 2, width: w, height: h).integral
        }
        let w = min(max(s.width, minSize.width), vf.width).rounded(.down)
        let h = min(max(s.height, minSize.height), vf.height).rounded(.down)
        let x = min(max(s.minX, vf.minX), vf.maxX - w).rounded(.down)
        let y = min(max(s.minY, vf.minY), vf.maxY - h).rounded(.down)
        return NSRect(x: max(x, vf.minX.rounded(.up)), y: max(y, vf.minY.rounded(.up)), width: w, height: h)
    }

    static func load(_ key: String, from defaults: UserDefaults = .standard) -> NSRect? {
        guard let s = (defaults.dictionary(forKey: defaultsKey) as? [String: String])?[key] else { return nil }
        let r = NSRectFromString(s)
        return r.width >= 1 && r.height >= 1 && r.origin.x.isFinite && r.origin.y.isFinite ? r : nil
    }

    static func save(_ frame: NSRect, _ key: String, to defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: defaultsKey) as? [String: String] ?? [:]
        all[key] = NSStringFromRect(frame)
        defaults.set(all, forKey: defaultsKey)
    }
}
