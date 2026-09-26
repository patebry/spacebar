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

try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
