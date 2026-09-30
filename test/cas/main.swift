// Checks Writer/FileWrite.swift, and what the writer writes (EditableText in Shared/FolderListing.swift), on files in a fresh temp
// folder: build and run with test/cas/run.sh.
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

// What the writer writes (EditableText.writeRefusal) and how a text file's bytes go back (EditableText.Source).
let tdir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-cas-text-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: tdir, withIntermediateDirectories: true)
func put(_ name: String, _ d: Data) -> String {
    let p = tdir.appendingPathComponent(name).path
    FileManager.default.createFile(atPath: p, contents: d)
    return p
}
let editable = ["a.md", "notes.txt", "data.json", "c.yaml", "c.yml", "Cargo.toml", "pom.xml", "t.csv", "t.tsv", "setup.ini", "nginx.conf",
                "app.properties", "x.env", ".env", ".env.local", ".gitignore", "main.swift", "run.py", "Makefile", "Dockerfile", "server.log"]
let refused = ["photo.png", "doc.pdf", "page.html", "a.zip", "blob.dat", "tool", "letter.rtf", "report.docx", "Info.app", "movie.mp4", "font.ttf"]
check("allow-list: text, config and code (\(editable.count) names)", editable.allSatisfy(EditableText.allowed(name:)))
check("allow-list: binaries, documents and anything not text are refused (\(refused.count) names)", !refused.contains(where: EditableText.allowed(name:)))

let txt = put("notes.txt", Data("one\ntwo\n".utf8))
let ok = Data("one\nTWO\n".utf8)
check("write: an existing .txt", EditableText.writeRefusal(path: txt, data: ok, base: Data("one\ntwo\n".utf8)) == nil)
check("write: a relative path is refused", EditableText.writeRefusal(path: "notes.txt", data: ok, base: ok) != nil)
check("write: a missing file is refused", EditableText.writeRefusal(path: tdir.appendingPathComponent("gone.txt").path, data: ok, base: ok) != nil)
try! FileManager.default.createDirectory(at: tdir.appendingPathComponent("dir.txt"), withIntermediateDirectories: true)
check("write: a folder is refused", EditableText.writeRefusal(path: tdir.appendingPathComponent("dir.txt").path, data: ok, base: ok) != nil)
let png = put("photo.png", Data([0x89, 0x50, 0x4E, 0x47]))
check("write: a .png is refused", EditableText.writeRefusal(path: png, data: ok, base: Data([0x89, 0x50, 0x4E, 0x47])) != nil)
let fake = tdir.appendingPathComponent("fake.txt").path
try! FileManager.default.createSymbolicLink(atPath: fake, withDestinationPath: png)
check("write: a .txt link to a .png is refused", EditableText.writeRefusal(path: fake, data: ok, base: Data([0x89, 0x50, 0x4E, 0x47])) != nil)
let mdLink = tdir.appendingPathComponent("note.md").path
try! FileManager.default.createSymbolicLink(atPath: mdLink, withDestinationPath: txt)
check("write: a .md link to a .txt is refused (Markdown's bound is for Markdown on both sides)", EditableText.writeRefusal(path: mdLink, data: ok, base: ok) != nil)
check("write: a .txt holding binary is refused", EditableText.writeRefusal(path: txt, data: ok, base: Data([0, 1, 2, 0, 255])) != nil)
let bplist = try! PropertyListSerialization.data(fromPropertyList: ["k": "v"], format: .binary, options: 0)
let plist = put("Info.plist", bplist)
check("write: a binary property list is refused", EditableText.writeRefusal(path: plist, data: Data("<plist/>".utf8), base: bplist) != nil)
check("write: an empty file may be written and emptied", EditableText.writeRefusal(path: put("empty.txt", Data()), data: ok, base: Data()) == nil
      && EditableText.writeRefusal(path: txt, data: Data(), base: ok) == nil)
let big = Data(repeating: 0x61, count: FileTypes.maxTextBytes + 10)
let bigPath = put("big.log", big)
check("write: never a buffer cut from a file over 2 MB", EditableText.writeRefusal(path: bigPath, data: big.prefix(FileTypes.maxTextBytes), base: big.prefix(FileTypes.maxTextBytes)) != nil)
check("write: never more than 2 MB of text", EditableText.writeRefusal(path: txt, data: big, base: ok) != nil)
let bigMd = put("big.md", big)
check("write: Markdown keeps its 64 MB bound", EditableText.writeRefusal(path: bigMd, data: big, base: big) == nil)
check("write: .env is edited in place", EditableText.writeRefusal(path: put(".env", Data("A=1\n".utf8)), data: Data("A=2\n".utf8), base: Data("A=1\n".utf8)) == nil)
let agents = tdir.appendingPathComponent("Library/LaunchAgents")
try! FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
let hooks = tdir.appendingPathComponent("repo/.git/hooks")
try! FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
let runners = [put(".npmrc", Data("x=1\n".utf8)), put(".bash_profile", Data("x\n".utf8)), put(".gitconfig", Data("[user]\n".utf8)), put("go.command", Data("ls\n".utf8)),
               agents.appendingPathComponent("x.plist").path, hooks.appendingPathComponent("pre-commit.sh").path]
for r in runners.suffix(2) { FileManager.default.createFile(atPath: r, contents: Data("x\n".utf8)) }
check("write: files the shell, git, npm or launchd run are never edited (.npmrc, shell profiles, .gitconfig, .command, LaunchAgents, git hooks)",
      runners.allSatisfy { !EditableText.allowed(path: $0) && EditableText.writeRefusal(path: $0, data: Data("y\n".utf8), base: Data("x\n".utf8)) != nil })

// Round trips: the file is read as the viewer reads it, edited as text, and written back through the writer's compare-and-swap.
func roundTrip(_ name: String, _ bytes: Data, edit: (String) -> String, expect: (Data) -> Bool) -> Bool {
    let p = put(name, bytes)
    let (payload, opened) = FileView.payloadAndText(path: p, kind: FileTypes.kind(name: name), root: tdir.path, reason: "open", canOpen: true)
    guard let o = opened, payload["editable"] as? Bool == true, payload["text"] as? String == o.text, o.source.bytes(o.text) == bytes,
          let out = o.source.bytes(edit(o.text)), EditableText.writeRefusal(path: p, data: out, base: bytes) == nil,
          compareAndWrite(out, path: p, expecting: bytes) == nil, let back = FileManager.default.contents(atPath: p) else { return false }
    return expect(back)
}
let cp1252 = "Café — 25 €\nZoë’s façade\n".data(using: .windowsCP1252)!
check("round trip: Windows-1252 stays Windows-1252", roundTrip("latin.txt", cp1252, edit: { $0.replacingOccurrences(of: "25", with: "30 “net”") }) {
    $0 == "Café — 30 “net” €\nZoë’s façade\n".data(using: .windowsCP1252)! })
let sjis = String(repeating: "日本語のテキストです。これはテストです。\n", count: 4).data(using: .shiftJIS)!
check("round trip: Shift JIS stays Shift JIS", roundTrip("jp.txt", sjis, edit: { $0 + "追加しました。\n" }) {
    $0 == (String(repeating: "日本語のテキストです。これはテストです。\n", count: 4) + "追加しました。\n").data(using: .shiftJIS)! })
let u16 = Data([0xFF, 0xFE]) + "name: wide 🚀\nsecond: line\n".data(using: .utf16LittleEndian)!
check("round trip: UTF-16 LE keeps its byte order mark", roundTrip("wide.yaml", u16, edit: { $0.replacingOccurrences(of: "line", with: "row") }) {
    $0 == Data([0xFF, 0xFE]) + "name: wide 🚀\nsecond: row\n".data(using: .utf16LittleEndian)! })
let bom8 = Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n1,2\n".utf8)
check("round trip: a UTF-8 byte order mark is kept", roundTrip("t.csv", bom8, edit: { $0 + "3,4\n" }) { $0 == Data([0xEF, 0xBB, 0xBF]) + Data("a,b\n1,2\n3,4\n".utf8) })
let crlf = Data("[core]\r\n\tname = x\r\n".utf8)
check("round trip: CRLF line endings stay CRLF, edited as LF", roundTrip("git.ini", crlf, edit: { $0 + "\tmore = y\n" }) {
    $0 == Data("[core]\r\n\tname = x\r\n\tmore = y\r\n".utf8) })
check("round trip: no trailing newline stays none", roundTrip("t.toml", Data("a = 1".utf8), edit: { $0 + "2" }) { $0 == Data("a = 12".utf8) })
let mixed = Data("one\r\ntwo\nthree\r\n".utf8)
check("round trip: mixed line endings are kept as they are", roundTrip("mixed.txt", mixed, edit: { $0.replacingOccurrences(of: "two", with: "2") }) {
    $0 == Data("one\r\n2\nthree\r\n".utf8) })

let latin = EditableText.open(cp1252, decoded: TextDecoding.decode(cp1252)!)!
check("encoding: a character Windows-1252 cannot hold is refused, never converted", latin.source.bytes(latin.text + "☃") == nil
      && latin.source.unencodable(latin.text + "☃") == "☃")
let stray = Data("naïve café 日本語 ".utf8) + Data([0xFF]) + Data(" end\n".utf8)
check("encoding: UTF-8 with an invalid byte is not editable (it would come back as U+FFFD)", EditableText.open(stray, decoded: TextDecoding.decode(stray)!) == nil)
let bigTxt = put("huge.txt", Data(String(repeating: "x", count: FileTypes.maxTextBytes + 100).utf8))
let (hp, ho) = FileView.payloadAndText(path: bigTxt, kind: .text, root: tdir.path, reason: "open", canOpen: true)
check("a file over 2 MB is shown cut, and not editable", hp["truncated"] as? Bool == true && ho == nil && hp["editable"] == nil)
let (bp, bo) = FileView.payloadAndText(path: plist, kind: .code, root: tdir.path, reason: "open", canOpen: true)
check("a binary property list is shown as XML, and not editable", (bp["text"] as? String ?? "").contains("<plist") && bo == nil && bp["editable"] == nil)
let rc = put(".zshrc", Data("export A=1\n".utf8))
let rcLink = tdir.appendingPathComponent("readme.txt").path
try! FileManager.default.createSymbolicLink(atPath: rcLink, withDestinationPath: rc)
check("a .txt link to .zshrc is neither editable nor written", !EditableText.allowed(path: rcLink)
      && EditableText.writeRefusal(path: rcLink, data: Data("x\n".utf8), base: Data("export A=1\n".utf8)) != nil
      && FileView.payloadAndText(path: rcLink, kind: .text, root: tdir.path, reason: "open", canOpen: true).edit == nil)
let same = tdir.appendingPathComponent("sub").path
try! FileManager.default.createDirectory(atPath: same, withIntermediateDirectories: true)
let sameLink = (same as NSString).appendingPathComponent("notes.txt")
try! FileManager.default.createSymbolicLink(atPath: sameLink, withDestinationPath: txt)
check("a link to a file of the same name is editable", EditableText.allowed(path: sameLink))

// Only what was typed: the writer records the file as it read it and every buffer its edit sent (TypedTexts).
let typed = TypedTexts()
let notes = put("typed.txt", "Café 25 €\n".data(using: .windowsCP1252)!)
check("typed: an edit starts only from the file's own text", !typed.begin(path: notes, text: "something else\n") && typed.begin(path: notes, text: "Café 25 €\n"))
typed.sent(path: notes, text: "Café 30 €\n")
check("typed: a sent text may be written, in the file's encoding", typed.allows(path: notes, data: "Café 30 €\n".data(using: .windowsCP1252)!))
check("typed: the same text in another encoding, or text never typed, may not", !typed.allows(path: notes, data: Data("Café 30 €\n".utf8))
      && !typed.allows(path: notes, data: "rm -rf ~\n".data(using: .windowsCP1252)!) && !typed.allows(path: txt, data: ok))
check("typed: an edit may start again from a text it sent (a save still in flight)", typed.begin(path: notes, text: "Café 30 €\n"))
for n in 31...40 { typed.sent(path: notes, text: "Café \(n) €\n") }
typed.ended(path: notes)
check("typed: once the edit ends only its last buffers may still be saved", typed.allows(path: notes, data: "Café 40 €\n".data(using: .windowsCP1252)!)
      && !typed.allows(path: notes, data: "Café 31 €\n".data(using: .windowsCP1252)!))
check("typed: never for a file the writer cannot read as editable", !typed.begin(path: bigPath, text: "") && !typed.begin(path: rcLink, text: "export A=1\n"))
let u16log = put("wide.log", "Windows log line one\r\nline two: café\r\n".data(using: .utf16LittleEndian)!)
check("typed: a UTF-16 file without a byte order mark", typed.begin(path: u16log, text: "Windows log line one\nline two: café\n"))
typed.sent(path: u16log, text: "日本")
let short16 = "日本\r\n".data(using: .utf16LittleEndian)!
check("typed: a short CJK edit of it is saved in UTF-16, not refused as binary", typed.allows(path: u16log, data: "日本".data(using: .utf16LittleEndian)!)
      && EditableText.writeRefusal(path: u16log, data: short16, base: FileManager.default.contents(atPath: u16log)!) == nil)

// The resolved path is written without following a link swapped in for it.
let target = put("target.txt", ok)
let swapped = tdir.appendingPathComponent("swapped.txt").path
try! FileManager.default.createSymbolicLink(atPath: swapped, withDestinationPath: target)
check("write: a link at the resolved path is not followed", compareAndWrite(Data("new\n".utf8), path: swapped, expecting: ok, noFollow: true) != nil
      && FileManager.default.contents(atPath: target) == ok)

let hostsLink = tdir.appendingPathComponent("hosts.txt").path
try! FileManager.default.createSymbolicLink(atPath: hostsLink, withDestinationPath: put("hosts", Data("127.0.0.1 x\n".utf8)))
check("a .txt link to a file of another name is shown, and not editable", FileView.payloadAndText(path: hostsLink, kind: .text, root: tdir.path, reason: "open", canOpen: true).edit == nil)

try? FileManager.default.removeItem(at: tdir)
try? FileManager.default.removeItem(at: dir)
exit(failures == 0 ? 0 : 1)
