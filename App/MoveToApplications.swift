import AppKit
import DiskArbitration
import Security

/// The launch-time offer to move a copy run from spacebar.dmg, or translocated, into Applications (InstallLocation decides).
/// Until the user answers nothing else runs: no settings written, no welcome, no extension or helper registered from here.
enum MoveToApplications {
    private static let fallback = "Drag spacebar into your Applications folder in Finder, then open it from there."

    /// Set while the offer, or the move, is under way: the app delegate then shows no settings window and does not quit
    /// when its last window closes.
    static private(set) var active = false

    /// Shows the offer when this copy needs it; true when it did, and the rest of launch must not run.
    static func offerIfNeeded() -> Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let original = originalPath(ofTranslocated: Bundle.main.bundleURL)
        let volume = volumeFacts(original ?? path)
        let facts = InstallLocation.Facts(path: path, original: original, diskImage: volume.diskImage, readOnly: volume.readOnly,
                                          home: NSHomeDirectory(), version: version(of: Bundle.main) ?? "0")
        let plan = { InstallLocation.plan(facts, isRunning: { !running(at: $0).isEmpty }, versionAt: { Bundle(path: $0).flatMap(version(of:)) }) }
        let first = plan()
        guard first != .stay else { return false }
        active = true
        NSLog("spacebar: running from %@ (original %@, disk image %d, read-only %d): %@", path, original ?? "-",
              volume.diskImage ? 1 : 0, volume.readOnly ? 1 : 0, String(describing: first))
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Move spacebar to Applications?"
        alert.informativeText = "spacebar works best from your Applications folder: Quick Look and the Space helper need it there."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Quit")
        guard alert.runModal() == .alertFirstButtonReturn else { NSApp.terminate(nil); return true }
        // Decided again: a copy may have been opened or put there while the question was up.
        let chosen = plan()
        let progress = progressPanel()
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try carryOut(chosen, from: path) }
            DispatchQueue.main.async {
                progress.orderOut(nil)
                switch result {
                case .success(let dest):
                    let after = InstallLocation.afterOpening(chosen, original: original, diskImage: volume.diskImage)
                    open(dest, eject: after.eject ? volume.url : nil, trash: after.trashOriginal ? original : nil)
                case .failure(let error):
                    fail(error.localizedDescription)
                }
            }
        }
        return true
    }

    private static func progressPanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 72), styleMask: [.titled], backing: .buffered, defer: false)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.startAnimation(nil)
        let label = NSTextField(labelWithString: "Moving spacebar to Applications…")
        let row = NSStackView(views: [spinner, label])
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        panel.contentView = row
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        return panel
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ s: String) { errorDescription = s }
    }

    /// Puts the copy in place and returns where it is; throws, with nothing half made left behind, when it cannot.
    private static func carryOut(_ plan: InstallLocation.Plan, from source: String) throws -> String {
        switch plan {
        case .stay: return source
        case .openExisting(let dest): return dest
        case .cannotChange(let dest):
            throw Failure("This account can't change \(shown((dest as NSString).deletingLastPathComponent)), where spacebar goes. An administrator can move it there.")
        case .quitRunning(let dest):
            for app in running(at: dest) { app.terminate() }
            let deadline = Date().addingTimeInterval(5)
            while !running(at: dest).isEmpty, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            guard running(at: dest).isEmpty else { throw Failure("spacebar is open from \(shown(dest)). Quit it, then open this copy again.") }
            return try copy(from: source, to: dest, replacing: true)
        case .move(let dest, let replacing):
            return try copy(from: source, to: dest, replacing: replacing)
        }
    }

    /// ditto into .spacebar.app.new beside `dest`, without the quarantine flag (as install.sh's copy has none), checked to be
    /// signed as this copy is; then the copy there to the Trash and the new one renamed into place, the old put back if that fails.
    static func copy(from source: String, to dest: String, replacing: Bool) throws -> String {
        let fm = FileManager.default
        let dir = (dest as NSString).deletingLastPathComponent
        let new = dir + "/.spacebar.app.new"
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        if Updates.isThere(new) { try fm.removeItem(atPath: new) }
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["--noqtn", source, new]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else {
            try? fm.removeItem(atPath: new)
            throw Failure("Copying spacebar into \(shown(dir)) failed.")
        }
        if let problem = signatureProblem(new) {
            try? fm.removeItem(atPath: new)
            throw Failure("The copy in \(shown(dir)) did not verify: \(problem)")
        }
        var trashed: NSURL?
        let helpers = replacing ? running(inside: dest) : []
        if replacing {
            do { try fm.trashItem(at: URL(fileURLWithPath: dest), resultingItemURL: &trashed) } catch {
                try? fm.removeItem(atPath: new)
                throw Failure("The spacebar already in \(shown(dir)) could not be moved to the Trash: \(error.localizedDescription)")
            }
        }
        guard rename(new, dest) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(atPath: new)
            if let t = trashed as URL?, (try? fm.moveItem(at: t, to: URL(fileURLWithPath: dest))) == nil {
                throw Failure("spacebar could not be put in \(shown(dir)): \(reason). Your previous copy is in the Trash.")
            }
            throw Failure("spacebar could not be put in \(shown(dir)): \(reason).")
        }
        // Left by an install.sh swap cut short; this copy now stands where it would have restored.
        if Updates.isThere(dir + "/.spacebar.app.old") { try? fm.trashItem(at: URL(fileURLWithPath: dir + "/.spacebar.app.old"), resultingItemURL: nil) }
        // The replaced copy's Space helper and viewer; the new copy re-registers the helper when it finds it not answering.
        for app in helpers { app.forceTerminate() }
        return dest
    }

    /// Opens the copy at `dest` (a new instance, unless that copy is open already), then quits this one, ejecting the disk image it came from (best effort, once
    /// this copy has quit) or moving a translocated original to the Trash.
    private static func open(_ dest: String, eject volume: URL?, trash original: String?) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = running(at: dest).isEmpty
        config.activates = true
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: dest), configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error { fail("spacebar was put in \(shown(dest)), but could not be opened: \(error.localizedDescription)"); return }
                if let original, original != dest, Updates.canChange(original) {
                    try? FileManager.default.trashItem(at: URL(fileURLWithPath: original), resultingItemURL: nil)
                }
                if let volume { detachLater(volume) }
                NSApp.terminate(nil)
            }
        }
    }

    /// hdiutil detach from a shell that waits for this copy, which runs from the image, to quit. Not forced: an image
    /// something else holds stays mounted.
    private static func detachLater(_ volume: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 2; exec /usr/bin/hdiutil detach -quiet \"$0\"", volume.path]
        p.currentDirectoryURL = URL(fileURLWithPath: "/")
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    private static func fail(_ message: String) {
        NSLog("spacebar: move to Applications: %@", message)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "spacebar couldn't be moved to Applications"
        alert.informativeText = message + "\n\n" + fallback
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }

    // MARK: Facts

    /// The real path of a bundle Gatekeeper translocated, through Security's SecTranslocate calls (looked up at run time,
    /// as they are not in the SDK headers); nil when it is not translocated.
    static func originalPath(ofTranslocated url: URL) -> String? {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Bool
        typealias OriginalPath = @convention(c) (CFURL, UnsafeMutablePointer<Unmanaged<CFError>?>?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY) else { return nil }
        defer { dlclose(handle) }
        guard let isSym = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let origSym = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return nil }
        var translocated = false
        guard unsafeBitCast(isSym, to: IsTranslocated.self)(url as CFURL, &translocated, nil), translocated,
              let original = unsafeBitCast(origSym, to: OriginalPath.self)(url as CFURL, nil)?.takeRetainedValue() else { return nil }
        return (original as URL).resolvingSymlinksInPath().path
    }

    /// The volume holding `path`: whether it is read-only, and whether Disk Arbitration names its device a disk image.
    static func volumeFacts(_ path: String) -> (url: URL?, readOnly: Bool, diskImage: Bool) {
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeURLKey, .volumeIsReadOnlyKey])
        guard let volume = values?.volume else { return (nil, false, false) }
        var image = false
        if let session = DASessionCreate(kCFAllocatorDefault),
           let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL),
           let info = DADiskCopyDescription(disk) as? [String: Any] {
            image = (info[kDADiskDescriptionDeviceModelKey as String] as? String)?.trimmingCharacters(in: .whitespaces) == "Disk Image"
        }
        return (volume, values?.volumeIsReadOnly ?? false, image)
    }

    private static func version(of bundle: Bundle) -> String? {
        bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    /// spacebar itself open from `path` (not its helper or viewer, which run from inside it).
    private static func running(at path: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path == path }
    }

    /// Apps running from inside the bundle at `path`: its Space helper and viewer.
    private static func running(inside path: String) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.resolvingSymlinksInPath().path.hasPrefix(path + "/") == true }
    }

    /// Why the bundle at `path` fails to verify (all architectures, nested code, strictly) against this copy's designated
    /// requirement, so it is this same build signed by the same identity; nil when it verifies.
    private static func signatureProblem(_ path: String) -> String? {
        var me: SecCode?, requirement: SecRequirement?, staticMe: SecStaticCode?, copy: SecStaticCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &copy) == errSecSuccess, let copy else {
            return "its signature could not be read"
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(copy, flags, requirement)
        return status == errSecSuccess ? nil : (SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")
    }

    private static func shown(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path == home || path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }
}
