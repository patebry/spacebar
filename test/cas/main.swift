// Checks Writer/FileWrite.swift on files in a fresh temp folder: build and run with test/cas/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-cas-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let path = dir.appendingPathComponent("doc.md").path
let old = Data("old line\n".utf8), new = Data("new\n".utf8), other = Data("someone else\n".utf8)
func contents(_ p: String = path) -> Data? { FileManager.default.contents(atPath: p) }
func inode(_ p: String = path) -> UInt64 { var s = stat(); stat(p, &s); return s.st_ino }

FileManager.default.createFile(atPath: path, contents: old, attributes: [.posixPermissions: 0o640])
_ = "tag".withCString { setxattr(path, "md.spacebar.test", $0, 3, 0, 0) }
let ino = inode()

check("write when the file holds the base (shorter content truncates)", compareAndWrite(new, path: path, expecting: old) == nil && contents() == new)
check("same inode, mode and xattr", inode() == ino
      && (try! FileManager.default.attributesOfItem(atPath: path))[.posixPermissions] as? Int == 0o640
      && getxattr(path, "md.spacebar.test", nil, 0, 0, 0) == 3)
check("longer content", compareAndWrite(old + old, path: path, expecting: new) == nil && contents() == old + old)
check("conflict when the file changed", compareAndWrite(other, path: path, expecting: old) == "conflict" && contents() == old + old)

let link = dir.appendingPathComponent("link.md").path
_ = Darwin.link(path, link)
check("hard link stays shared", compareAndWrite(new, path: path, expecting: old + old) == nil && contents(link) == new)

let sym = dir.appendingPathComponent("sym.md").path
try! FileManager.default.createSymbolicLink(atPath: sym, withDestinationPath: path)
check("symlink target written, link kept", compareAndWrite(old, path: sym, expecting: new) == nil && contents() == old
      && (try? FileManager.default.destinationOfSymbolicLink(atPath: sym)) == path)

check("missing file refused", compareAndWrite(new, path: dir.appendingPathComponent("gone.md").path, expecting: old) != nil)
check("no stray files", (try! FileManager.default.contentsOfDirectory(atPath: dir.path)).sorted() == ["doc.md", "link.md", "sym.md"])

// The SIGTERM gate: the writer exits only between writes, or after the cap.
var quits = 0
let gate = WriteGate(cap: 0.3) { quits += 1 }
gate.terminate()
check("gate: an idle writer quits at once", quits == 1)
quits = 0
let busy = WriteGate(cap: 0.3) { quits += 1 }
check("gate: a write starts", busy.begin())
busy.terminate()
check("gate: a write in flight holds the exit", quits == 0)
check("gate: no write starts once quitting", !busy.begin())
busy.end()
check("gate: the exit waits a moment after the write, so its reply is sent", quits == 0)
usleep(600_000)
check("gate: quits after the write ends", quits == 1)
let quitCapped = DispatchSemaphore(value: 0)
let stuck = WriteGate(cap: 0.3) { quitCapped.signal() }
_ = stuck.begin()
stuck.terminate()
check("gate: a stuck write is given up on after the cap", quitCapped.wait(timeout: .now() + 0.1) == .timedOut && quitCapped.wait(timeout: .now() + 2) == .success)
// A write ending near the cap: the cap and the end must not both quit.
let counted = NSLock()
var raced = 0
let race = WriteGate(cap: 0.3, grace: 0.2) { counted.lock(); raced += 1; counted.unlock() }
_ = race.begin()
race.terminate()
usleep(250_000)
race.end()
usleep(700_000)
counted.lock()
check("gate: quits once when the cap and the write's end meet", raced == 1)
counted.unlock()
let signalled = DispatchSemaphore(value: 0)
let real = WriteGate(cap: 0.3) { signalled.signal() }
let source = real.handleSIGTERM()
kill(getpid(), SIGTERM)
check("gate: SIGTERM reaches the gate instead of killing the process", signalled.wait(timeout: .now() + 2) == .success)
source.cancel()

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
