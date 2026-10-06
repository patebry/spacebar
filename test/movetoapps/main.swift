// Checks App/InstallLocation.swift's decision, at launch, to offer moving this copy into Applications, and where to, against
// scratch folders; and App/MoveToApplications.swift's volume facts and copy step, on disk images run.sh attaches hidden.
// Build and run with test/movetoapps/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ got: Any = "") { print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(got)")"); if !ok { failures += 1 } }

let args = CommandLine.arguments
let (roMount, rwMount, scratch) = (args[1], args[2], args[3])
let home = "/Users/ann", sys = "/Applications"
let homeApp = home + "/Applications/spacebar.app", sysApp = sys + "/spacebar.app"
let image = "/Volumes/spacebar/spacebar.app"

func plan(path: String = image, original: String? = nil, diskImage: Bool = true, readOnly: Bool = true, version: String = "0.4.0",
          present: Set<String> = [home + "/Applications"], locked: Set<String> = [], running: Set<String> = [],
          versions: [String: String] = [:]) -> InstallLocation.Plan {
    let f = InstallLocation.Facts(path: path, original: original, diskImage: diskImage, readOnly: readOnly, home: home, system: sys,
                                  version: version)
    return InstallLocation.plan(f, exists: { present.contains($0) }, canChange: { p in !locked.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) },
                                isRunning: { running.contains($0) }, versionAt: { versions[$0] })
}

// Where it runs from.
check("on a read-only disk image under /Volumes: moved to ~/Applications", plan() == .move(to: homeApp, replacing: false), plan())
check("on a writable disk image: moved too", plan(readOnly: false) == .move(to: homeApp, replacing: false), plan(readOnly: false))
check("on a read-only volume that is not an image: moved", plan(diskImage: false) == .move(to: homeApp, replacing: false))
check("on a writable external disk: runs there, no offer", plan(path: "/Volumes/Work/spacebar.app", diskImage: false, readOnly: false) == .stay)
check("a build in its build folder: no offer", plan(path: "/Users/ann/src/spacebar/build/spacebar.app", diskImage: false, readOnly: false) == .stay)
check("in ~/Applications: no offer", plan(path: homeApp, diskImage: false, readOnly: false, present: [homeApp]) == .stay)
check("in /Applications: no offer", plan(path: sysApp, diskImage: false, readOnly: false, present: [sysApp]) == .stay)
let transloc = "/private/var/folders/xy/T/AppTranslocation/1234/d/spacebar.app"
check("translocated from Downloads: moved to ~/Applications",
      plan(path: transloc, original: home + "/Downloads/spacebar.app", diskImage: false, readOnly: false) == .move(to: homeApp, replacing: false))
check("translocated from the disk image: moved", plan(path: transloc, original: image) == .move(to: homeApp, replacing: false))
check("translocated, but really in ~/Applications: no offer",
      plan(path: transloc, original: homeApp, diskImage: false, readOnly: false, present: [homeApp]) == .stay)

// Where it goes: as install.sh picks.
check("no ~/Applications yet: made there, the home writable", plan(present: []) == .move(to: homeApp, replacing: false))
check("only in /Applications: that copy is replaced", plan(present: [sysApp]) == .move(to: sysApp, replacing: true), plan(present: [sysApp]))
check("in both: ~/Applications's is replaced", plan(present: [homeApp, sysApp, home + "/Applications"]) == .move(to: homeApp, replacing: true))
check("a swap cut short in /Applications: back there", plan(present: [sys + "/.spacebar.app.old"]) == .move(to: sysApp, replacing: false))
check("/Applications not writable, no copy there: ~/Applications, as install.sh", plan(locked: [sys]) == .move(to: homeApp, replacing: false))
check("only in /Applications, which this account can't change: refused, as install.sh",
      plan(present: [sysApp], locked: [sys]) == .cannotChange(sysApp))
check("a copy there this account can't change: refused", plan(present: [homeApp, home + "/Applications"], locked: [homeApp]) == .cannotChange(homeApp))
check("a leftover .spacebar.app.new it can't change: refused",
      plan(present: [home + "/Applications"], locked: [home + "/Applications/.spacebar.app.new"]) == .cannotChange(homeApp))
check("no home to make ~/Applications in: refused", plan(present: [], locked: [home]) == .cannotChange(homeApp))

// A copy already there.
check("the copy there is open: it must quit first",
      plan(present: [homeApp, home + "/Applications"], running: [homeApp]) == .quitRunning(homeApp))
check("an older copy there: replaced", plan(present: [homeApp, home + "/Applications"], versions: [homeApp: "0.3.0"]) == .move(to: homeApp, replacing: true))
check("the same version there: replaced", plan(present: [homeApp, home + "/Applications"], versions: [homeApp: "0.4.0"]) == .move(to: homeApp, replacing: true))
check("a newer copy there: opened, not replaced", plan(present: [homeApp, home + "/Applications"], versions: [homeApp: "0.5.0"]) == .openExisting(homeApp))
check("a newer copy there that is open: opened", plan(present: [homeApp, home + "/Applications"], running: [homeApp], versions: [homeApp: "0.5.0"]) == .openExisting(homeApp))

// What follows opening the copy in Applications.
let dl = home + "/Downloads/spacebar.app"
check("from the disk image: ejected, nothing trashed",
      InstallLocation.afterOpening(.move(to: homeApp, replacing: false), original: nil, diskImage: true) == (true, false))
check("translocated from the disk image: ejected, the original on it left",
      InstallLocation.afterOpening(.move(to: homeApp, replacing: false), original: image, diskImage: true) == (true, false))
check("translocated from Downloads: the original moved to the Trash",
      InstallLocation.afterOpening(.move(to: homeApp, replacing: true), original: dl, diskImage: false) == (false, true))
check("translocated from Downloads, after the open copy quit: the original moved to the Trash",
      InstallLocation.afterOpening(.quitRunning(homeApp), original: dl, diskImage: false) == (false, true))
check("a newer copy opened instead: the download kept",
      InstallLocation.afterOpening(.openExisting(homeApp), original: dl, diskImage: false) == (false, false))
check("a read-only volume that is not an image: not ejected",
      InstallLocation.afterOpening(.move(to: homeApp, replacing: false), original: nil, diskImage: false) == (false, false))

// The facts MoveToApplications gathers, on real volumes.
let ro = MoveToApplications.volumeFacts(roMount)
check("a read-only disk image: read-only, an image", ro.readOnly && ro.diskImage, ro)
let rw = MoveToApplications.volumeFacts(rwMount)
check("a writable disk image: an image, not read-only", !rw.readOnly && rw.diskImage, rw)
try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
let local = MoveToApplications.volumeFacts(scratch)
check("the startup disk: neither", !local.readOnly && !local.diskImage, local)
check("this test is not translocated", MoveToApplications.originalPath(ofTranslocated: URL(fileURLWithPath: CommandLine.arguments[0])) == nil)
check("the volume named is the image's mount point", ro.url?.resolvingSymlinksInPath().path == URL(fileURLWithPath: roMount).resolvingSymlinksInPath().path, ro.url as Any)

// The copy itself, into a folder on the writable image, so a replaced copy goes to that volume's Trash, not the user's. This
// test binary stands in for the app: it is checked against its own designated requirement, as the app checks a copy of itself.
let fm = FileManager.default
let me = CommandLine.arguments[0]
let apps = rwMount + "/Applications", dest = apps + "/spacebar.app"
check("a first copy: in place, no .new left", (try? MoveToApplications.copy(from: me, to: dest, replacing: false)) == dest
      && fm.contentsEqual(atPath: me, andPath: dest) && !Updates.isThere(apps + "/.spacebar.app.new"))
try! Data("old".utf8).write(to: URL(fileURLWithPath: dest))
let replaced = try? MoveToApplications.copy(from: me, to: dest, replacing: true)
check("a copy over an older one: in place, the old one in the Trash", replaced == dest
      && fm.contentsEqual(atPath: me, andPath: dest)
      && (try? String(contentsOfFile: rwMount + "/.Trashes/\(getuid())/spacebar.app")) == "old")
try! Data("left".utf8).write(to: URL(fileURLWithPath: apps + "/.spacebar.app.old"))
check("a .spacebar.app.old left by install.sh goes to the Trash after a copy",
      (try? MoveToApplications.copy(from: me, to: dest, replacing: true)) == dest && !Updates.isThere(apps + "/.spacebar.app.old"))
let tampered = scratch + "/tampered"
var bytes = try! Data(contentsOf: URL(fileURLWithPath: me))
bytes[bytes.count / 2] ^= 0xff
try! bytes.write(to: URL(fileURLWithPath: tampered))
try! Data("keep".utf8).write(to: URL(fileURLWithPath: dest))
var refused = ""
do { _ = try MoveToApplications.copy(from: tampered, to: dest, replacing: true) } catch { refused = error.localizedDescription }
check("a copy that fails its signature: refused, the copy there kept, no .new left",
      refused.contains("did not verify") && (try? String(contentsOfFile: dest)) == "keep" && !Updates.isThere(apps + "/.spacebar.app.new"), refused)

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
