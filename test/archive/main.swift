// Checks Shared/ArchiveListing.swift: the bsdtar -tv parser on output captured from real archives (test/archive/fixtures,
// listed with TZ=UTC), then the whole listing on archives made here in a temp folder. Build and run with test/archive/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : " \(detail())")")
    if !ok { failures += 1 }
}

let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
let utc = TimeZone(identifier: "UTC")!
let captured = Date(timeIntervalSince1970: Double(try! String(contentsOf: fixtures.appendingPathComponent("now.txt"), encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines))!)
let recent = Double(1789899300) * 1000   // 2026-09-20 10:15 UTC
let old = Double(1577923200) * 1000      // 2020-01-02, the day only: bsdtar prints an old date without its time
func nfc(_ s: String) -> String { s.precomposedStringWithCanonicalMapping }

// ---- the parser, on every format's captured output ----
let expected: [String: (size: Int64?, modified: Double, isDir: Bool)] = [
    "src/": (nil, recent, true), "src/sub/": (nil, recent, true), "src/sub/deep/": (nil, recent, true),
    "src/a.txt": (6, recent, false), "src/link": (0, recent, false), "src/sub/deep/blob.bin": (5000, old, false),
    "src/sub/file with space.md": (4, recent, false), "src/sub/new\nline.txt": (1, recent, false),
    "src/sub/back\\slash.txt": (1, recent, false), nfc("src/sub/é ünï 日本.txt"): (2, recent, false), "src/hard.txt": (6, recent, false),
]
for format in ["zip", "tar", "tgz", "tar.bz2", "tar.xz", "7z"] {
    let text = try! String(contentsOf: fixtures.appendingPathComponent("\(format).txt"), encoding: .utf8)
    let entries = ArchiveListing.parse(text, now: captured, timeZone: utc)
    var wrong: [String] = []
    for e in entries {
        guard let want = expected[nfc(e.name)] else { wrong.append("unexpected \(e.name)"); continue }
        // A hard link's size is 0 in tar; a directory has none.
        let sizeOK = e.size == want.size || (e.name == "src/a.txt" && e.size == 0)
        if !sizeOK || e.modified != want.modified || e.isDir != want.isDir { wrong.append("\(e.name) \(String(describing: e.size)) \(String(describing: e.modified)) \(e.isDir)") }
    }
    // 7z does not keep directories that tar and zip list, but every file is there.
    let names = Set(entries.map { nfc($0.name) })
    let files = expected.filter { !$0.value.isDir }.map(\.key)
    check("parse \(format): \(entries.count) entries, names with spaces, escapes, UTF-8, links and both date forms", wrong.isEmpty && files.allSatisfy(names.contains)
          && entries.count == text.split(separator: "\n").count, wrong.joined(separator: "; ") + " missing: \(files.filter { !names.contains($0) })")
}

// ---- dates, escapes and odd lines ----
func at(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    var c = Calendar(identifier: .gregorian); c.timeZone = utc
    return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}
let janNow = at(2027, 1, 5, 12)
let line = { (date: String) in ArchiveListing.parseLine(Substring("-rw-r--r--  0 u g 3 \(date) f.txt"), now: janNow, timeZone: utc)?.modified }
check("date: a time late last year belongs to last year", line("Dec 30 10:00") == at(2026, 12, 30, 10).timeIntervalSince1970 * 1000)
check("date: a time early this year belongs to this year", line("Jan  4 09:30") == at(2027, 1, 4, 9, 30).timeIntervalSince1970 * 1000)
check("date: a year is taken as is", line("Mar  1  1999") == at(1999, 3, 1).timeIntervalSince1970 * 1000)
check("date: nonsense is no date", ArchiveListing.parseLine("-rw-r--r--  0 u g 3 Foo 30 10:00 f.txt", now: janNow, timeZone: utc) == nil)
check("unescape: letters, backslash and octal UTF-8 bytes", ArchiveListing.unescape("a\\tb\\\\c\\303\\251\\x") == "a\tb\\cé\\x")
check("unescape: a lone trailing backslash is kept", ArchiveListing.unescape("x\\") == "x\\")
let odd = "garbage\n-rw-r--r--  0 u g 12 Jan  1  2020 has -> arrow.txt\nlrwxr-xr-x  0 u g 0 Jan  1  2020 ln -> t\n-rw-r--r--  0 u g 5 Jan  1  2020 cut"
let oddEntries = ArchiveListing.parse(odd, now: janNow, timeZone: utc)
check("parse: a garbage line and an unfinished last line are skipped; only a link's target is cut",
      oddEntries.map(\.name) == ["has -> arrow.txt", "ln"], "\(oddEntries.map(\.name))")
let many = String(repeating: "-rw-r--r--  0 u g 1 Jan  1  2020 f\n", count: ArchiveListing.maxEntries + 10)
let spaced = ArchiveListing.parseLine("-rw-r--r--  0 Jane Doe Domain Users 42 Jan  1  2020 odd owner.txt", now: janNow, timeZone: utc)
check("parse: owner and group names with spaces still find the size, date and name",
      spaced?.name == "odd owner.txt" && spaced?.size == 42 && spaced?.modified == at(2020, 1, 1).timeIntervalSince1970 * 1000, "\(String(describing: spaced))")
let arrow = ArchiveListing.parseLine("lrwxr-xr-x  0 u g 0 Jan  1  2020 a -> b -> target", now: janNow, timeZone: utc)
check("parse: a link's target is cut at the last arrow", arrow?.name == "a -> b", "\(String(describing: arrow))")
check("parse: at most \(ArchiveListing.maxEntries) entries", ArchiveListing.parse(many, now: janNow).count == ArchiveListing.maxEntries)
let wrapped = try! JSONSerialization.jsonObject(with: ArchiveListing.json([.init(name: "d/", size: nil, modified: nil, isDir: true),
                                                                          .init(name: "d/f", size: 7, modified: 1000, isDir: false)], truncated: true)) as! [String: Any]
let json = wrapped["entries"] as! [[String: Any]]
check("json: name, size, modified and isDir, null when unknown, and whether the listing was cut",
      wrapped["truncated"] as? Bool == true && json.count == 2 && json[0]["size"] is NSNull && json[0]["modified"] is NSNull && json[0]["isDir"] as? Bool == true
      && json[1]["name"] as? String == "d/f" && json[1]["size"] as? Int == 7 && json[1]["modified"] as? Double == 1000 && json[1]["isDir"] as? Bool == false)

// ---- the whole listing, on archives made here ----
let fm = FileManager.default
let work = fm.temporaryDirectory.appendingPathComponent("spacebar-archive-\(UUID().uuidString)")
let src = work.appendingPathComponent("src")
try! fm.createDirectory(at: src.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! Data("hello\n".utf8).write(to: src.appendingPathComponent("a.txt"))
try! Data(repeating: 7, count: 3000).write(to: src.appendingPathComponent("sub/b.bin"))
@discardableResult
func sh(_ args: [String], in dir: URL = work) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    p.currentDirectoryURL = dir
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run(); p.waitUntilExit()
    return p.terminationStatus
}
sh(["/usr/bin/zip", "-qr", "t.zip", "src"])
for (name, flag) in [("t.tar", ""), ("t.tgz", "z"), ("t.tar.bz2", "j"), ("t.tar.xz", "J")] { sh(["/usr/bin/tar", "-c\(flag)f", name, "src"]) }
sh(["/usr/bin/tar", "--format", "7zip", "-cf", "t.7z", "src"])
func listing(_ name: String) -> [String: Any]? {
    ArchiveListing.list(work.appendingPathComponent(name).path).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
}
func listed(_ name: String) -> [[String: Any]]? { listing(name)?["entries"] as? [[String: Any]] }
for name in ["t.zip", "t.tar", "t.tgz", "t.tar.bz2", "t.tar.xz", "t.7z"] {
    let l = listed(name) ?? []
    let files = Dictionary(l.filter { $0["isDir"] as? Bool == false }.map { ($0["name"] as! String, $0["size"] as? Int ?? -1) }, uniquingKeysWith: { a, _ in a })
    check("list \(name): its files and sizes, from bsdtar", files == ["src/a.txt": 6, "src/sub/b.bin": 3000], "\(l)")
}

let single = work.appendingPathComponent("notes.txt")
try! Data(repeating: 65, count: 12345).write(to: single)
sh(["/usr/bin/gzip", "-k", "notes.txt"])
sh(["/usr/bin/bzip2", "-k", "notes.txt"])
let gz = listed("notes.txt.gz")
check("list notes.txt.gz: a lone gzip file is the one file inside, sized from its trailer",
      gz?.count == 1 && gz?[0]["name"] as? String == "notes.txt" && gz?[0]["size"] as? Int == 12345 && gz?[0]["isDir"] as? Bool == false, "\(String(describing: gz))")
let bz = listed("notes.txt.bz2")
check("list notes.txt.bz2: a lone bzip2 file is the one file inside, size unknown",
      bz?.count == 1 && bz?[0]["name"] as? String == "notes.txt" && bz?[0]["size"] is NSNull, "\(String(describing: bz))")

try! Data("this is not a zip".utf8).write(to: work.appendingPathComponent("fake.zip"))
check("list fake.zip: not an archive, no listing", listed("fake.zip") == nil)
try! fm.copyItem(at: work.appendingPathComponent("t.zip"), to: work.appendingPathComponent("t.png"))
check("list t.png: only a file named as an archive is listed", listed("t.png") == nil)
try! fm.copyItem(at: work.appendingPathComponent("t.tgz"), to: work.appendingPathComponent("backup.gz"))
check("list backup.gz: a tar in a plain .gz is listed as the tar, not as one file", (listed("backup.gz") ?? []).count >= 2, "\(String(describing: listed("backup.gz")))")
check("list t.tar: a whole listing is not marked cut", listing("t.tar")?["truncated"] as? Bool == false)
check("list a folder: no listing", ArchiveListing.list(src.path) == nil)
check("list a missing file: no listing", ArchiveListing.list(work.appendingPathComponent("gone.zip").path) == nil)

// bsdtar reads zstd only through a zstd program, and PATH is the system's: none there on a stock Mac.
if fm.fileExists(atPath: "/opt/homebrew/bin/zstd") || fm.fileExists(atPath: "/usr/local/bin/zstd") {
    let zstd = fm.fileExists(atPath: "/opt/homebrew/bin/zstd") ? "/opt/homebrew/bin/zstd" : "/usr/local/bin/zstd"
    sh([zstd, "-q", "t.tar", "-o", "t.tar.zst"])
    let z = listed("t.tar.zst")
    check("list t.tar.zst: no listing without a system zstd (bsdtar needs the program)", fm.fileExists(atPath: "/usr/bin/zstd") ? z != nil : z == nil)
}

let big = work.appendingPathComponent("big")
try! fm.createDirectory(at: big, withIntermediateDirectories: true)
for i in 0..<(ArchiveListing.maxEntries + 200) { fm.createFile(atPath: big.appendingPathComponent("f\(i)").path, contents: nil) }
sh(["/usr/bin/tar", "-cf", "big.tar", "big"])
let t0 = Date()
let bigList = listed("big.tar")
check("list big.tar: cut at \(ArchiveListing.maxEntries) entries, and says so (\(Int(Date().timeIntervalSince(t0) * 1000)) ms)",
      bigList?.count == ArchiveListing.maxEntries && listing("big.tar")?["truncated"] as? Bool == true, "\(String(describing: bigList?.count))")
let exact = work.appendingPathComponent("exact")
try! fm.createDirectory(at: exact, withIntermediateDirectories: true)
for i in 0..<(ArchiveListing.maxEntries - 1) { fm.createFile(atPath: exact.appendingPathComponent("f\(i)").path, contents: nil) }
sh(["/usr/bin/tar", "-cf", "exact.tar", "exact"])
check("list exact.tar: exactly \(ArchiveListing.maxEntries) entries is whole", listed("exact.tar")?.count == ArchiveListing.maxEntries && listing("exact.tar")?["truncated"] as? Bool == false)

// The sandbox: bsdtar reads only its standard input, so a path it is handed, or a file it would write, is refused.
let probe = Process()
probe.executableURL = URL(fileURLWithPath: ArchiveListing.sandboxExec)
probe.arguments = ["-p", ArchiveListing.profile, ArchiveListing.tool, "-tf", work.appendingPathComponent("t.zip").path]
probe.standardOutput = FileHandle.nullDevice; probe.standardError = FileHandle.nullDevice
try! probe.run(); probe.waitUntilExit()
let writer = Process()
writer.executableURL = URL(fileURLWithPath: ArchiveListing.sandboxExec)
writer.arguments = ["-p", ArchiveListing.profile, ArchiveListing.tool, "-cf", work.appendingPathComponent("out.tar").path, src.path]
writer.standardOutput = FileHandle.nullDevice; writer.standardError = FileHandle.nullDevice
try! writer.run(); writer.waitUntilExit()
check("sandbox: bsdtar can open no file by path and write none", probe.terminationStatus != 0 && writer.terminationStatus != 0
      && !fm.fileExists(atPath: work.appendingPathComponent("out.tar").path))

try? fm.removeItem(at: work)
print(failures == 0 ? "archive: all passed" : "archive: \(failures) failed")
exit(failures == 0 ? 0 : 1)
