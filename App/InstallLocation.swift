import Foundation

/// Whether this copy of spacebar should offer to move itself into Applications at launch, and how. A copy run from a disk
/// image, or translocated by Gatekeeper (a quarantined copy macOS runs from a random read-only path), cannot register its
/// Quick Look extensions or keep the Space helper, so it offers the move before anything else runs. MoveToApplications
/// gathers the facts and carries the plan out; this part decides, and touches nothing.
enum InstallLocation {
    struct Facts {
        /// Where the running bundle is: the translocated path when translocated.
        var path: String
        /// Where a translocated bundle really is, when macOS says it is translocated.
        var original: String?
        /// The volume holding the real bundle is a mounted disk image.
        var diskImage = false
        /// The volume holding the real bundle is read-only.
        var readOnly = false
        var home: String
        var system = Updates.systemApplications
        var version: String
    }

    enum Plan: Equatable {
        /// Run as usual.
        case stay
        /// Copy into `to` (as .spacebar.app.new beside it, renamed into place), the copy already there to the Trash first.
        case move(to: String, replacing: Bool)
        /// A newer copy is already there: open it rather than replace it with an older one.
        case openExisting(String)
        /// The copy already there is open; it must quit before it is replaced.
        case quitRunning(String)
        /// This account cannot put a copy there, as install.sh would refuse.
        case cannotChange(String)
    }

    /// Only a translocated copy, or one on a disk image or read-only volume under /Volumes, is offered the move: a copy on a
    /// writable external disk runs where it is, as does a build run from its build folder.
    static func offersMove(_ f: Facts) -> Bool {
        if f.original != nil { return true }
        return f.path.hasPrefix("/Volumes/") && (f.diskImage || f.readOnly)
    }

    /// The folder install.sh installs into: the copy it would update (~/Applications's, else one only in /Applications, else
    /// where a swap was cut short), else ~/Applications.
    static func destination(home: String, system: String, exists: (String) -> Bool) -> String {
        Updates.managedCopy(home: home, system: system, exists: exists) ?? Updates.installPlaces(home: home, system: system)[0]
    }

    static func plan(_ f: Facts, exists: (String) -> Bool = Updates.isThere, canChange: (String) -> Bool = Updates.canChange,
                     isRunning: (String) -> Bool, versionAt: (String) -> String?) -> Plan {
        guard offersMove(f) else { return .stay }
        let real = ((f.original ?? f.path) as NSString).standardizingPath
        if Updates.installPlaces(home: f.home, system: f.system).contains(real) { return .stay }
        let dest = destination(home: f.home, system: f.system, exists: exists)
        let dir = (dest as NSString).deletingLastPathComponent
        let there = exists(dest)
        if there, let theirs = versionAt(dest), Updates.isNewer(theirs, than: f.version) { return .openExisting(dest) }
        if there, isRunning(dest) { return .quitRunning(dest) }
        let writable = exists(dir) ? [dest, dir + "/.spacebar.app.new"].allSatisfy(canChange) : canChange(dir)
        guard writable else { return .cannotChange(dest) }
        return .move(to: dest, replacing: there)
    }

    /// Once the copy in Applications is open: the disk image this one ran from is ejected; a translocated original elsewhere
    /// (a download) goes to the Trash, as the button says Move, unless a newer copy was opened and nothing was moved.
    static func afterOpening(_ plan: Plan, original: String?, diskImage: Bool) -> (eject: Bool, trashOriginal: Bool) {
        let moved: Bool
        switch plan {
        case .move, .quitRunning: moved = true
        case .stay, .openExisting, .cannotChange: moved = false
        }
        return (diskImage, moved && !diskImage && original != nil)
    }
}
