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
let deepName = (0..<20_000).map { "d\($0)" }.joined(separator: "/")
let deep = ArchiveListing.parseLine(Substring("-rw-r--r--  0 u g 1 Jan  1  2020 " + deepName), now: janNow, timeZone: utc)
check("parse: a path thousands of folders deep keeps \(ArchiveListing.maxDepth) levels and a name of at most \(ArchiveListing.maxNameBytes) bytes",
      deep.map { $0.name.split(separator: "/").count == ArchiveListing.maxDepth && $0.name.utf8.count <= ArchiveListing.maxNameBytes && $0.name.hasPrefix("d0/d1/") } == true,
      "\(deep?.name.split(separator: "/").count ?? -1) \(deep?.name.utf8.count ?? -1)")
let long = ArchiveListing.parseLine(Substring("-rw-r--r--  0 u g 1 Jan  1  2020 " + String(repeating: "é", count: 5000)), now: janNow, timeZone: utc)
check("parse: a long name is cut at a character, with an ellipsis", long.map { $0.name.utf8.count <= ArchiveListing.maxNameBytes && $0.name.hasSuffix("é…") } == true)
let bytesLine = Data("-rw-r--r--  0 u g 1 Jan  1  2020 caf\\303\\251 \\377.txt\n".utf8)
let fromBytes = ArchiveListing.parse(data: bytesLine, now: janNow, timeZone: utc).first?.name
check("parse: escapes are undone on the bytes, then read as UTF-8 (an invalid byte is one replacement character)",
      fromBytes == "café \u{FFFD}.txt", fromBytes ?? "nil")
let rawLatin = Data("-rw-r--r--  0 u g 1 Jan  1  2020 caf".utf8) + Data([0xC3, 0xA9]) + Data(".txt\n".utf8)
check("parse: raw UTF-8 bytes in the output survive", ArchiveListing.parse(data: rawLatin, now: janNow, timeZone: utc).first?.name == "café.txt")
let notLink = ArchiveListing.parseLine("-rw-r--r--  0 u g 1 Jan  1  2020 a -> b.txt", now: janNow, timeZone: utc)
check("parse: a file (not a link) whose name holds an arrow keeps it", notLink?.name == "a -> b.txt")
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
check("list big.tar: the listing past the cap is counted, so the page can say of how many", listing("big.tar")?["total"] as? Int == ArchiveListing.maxEntries + 201,
      "\(String(describing: listing("big.tar")?["total"]))")
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
// Extracting from standard input, into a folder it could otherwise write: nothing is written.
let into = work.appendingPathComponent("extract-here")
try! fm.createDirectory(at: into, withIntermediateDirectories: true)
let extractor = Process()
extractor.executableURL = URL(fileURLWithPath: ArchiveListing.sandboxExec)
extractor.arguments = ["-p", ArchiveListing.profile, ArchiveListing.tool, "-xf", "-", "-C", into.path]
extractor.standardInput = try! FileHandle(forReadingFrom: work.appendingPathComponent("t.zip"))
extractor.standardOutput = FileHandle.nullDevice; extractor.standardError = FileHandle.nullDevice
try! extractor.run(); extractor.waitUntilExit()
check("sandbox: bsdtar extracting from its input writes nothing", extractor.terminationStatus != 0 && ((try? fm.contentsOfDirectory(atPath: into.path)) ?? ["?"]).isEmpty,
      "\(extractor.terminationStatus) \((try? fm.contentsOfDirectory(atPath: into.path)) ?? [])")
check("sandbox: the profile imports system.sb, not bsd.sb, and denies writes", ArchiveListing.profile.contains(#"(import "system.sb")"#)
      && !ArchiveListing.profile.contains("bsd.sb") && ArchiveListing.profile.contains("(deny file-write*)"))

// ---- one entry, streamed without extracting (ArchiveEntry) ----
check("entry pattern: a name starting with - is refused, however long", ArchiveEntry.pattern("-rf") == nil
      && ArchiveEntry.pattern("--use-compress-program=x") == nil && ArchiveEntry.pattern("-") == nil)
check("entry pattern: wildcards and the escape character are escaped, so a pattern matches only its own name",
      ArchiveEntry.pattern("*") == "\\*" && ArchiveEntry.pattern("?") == "\\?" && ArchiveEntry.pattern("[") == "\\["
      && ArchiveEntry.pattern("a]b") == "a\\]b" && ArchiveEntry.pattern("x\\*") == "x\\\\\\*" && ArchiveEntry.pattern("^a") == "\\^a"
      && ArchiveEntry.pattern("a^b") == "a^b")
check("entry pattern: a folder, an empty name, a NUL and an over-long name are refused",
      ArchiveEntry.pattern("dir/") == nil && ArchiveEntry.pattern("") == nil && ArchiveEntry.pattern("a\u{0}b") == nil
      && ArchiveEntry.pattern(String(repeating: "a", count: ArchiveListing.maxNameBytes + 1)) == nil)
check("entry pattern: ../, absolute and Unicode names are kept as they are", ArchiveEntry.pattern("../../etc/passwd") == "../../etc/passwd"
      && ArchiveEntry.pattern("/abs.txt") == "/abs.txt" && ArchiveEntry.pattern("caf\u{E9} 日本.md") == "caf\u{E9} 日本.md"
      && ArchiveEntry.pattern("./-rf") == "./-rf")
let argv = ArchiveEntry.arguments(pattern: "\\*")
check("entry command: sandbox-exec with the lister's profile, bsdtar -x -O -q -n from stdin, the pattern alone after --",
      argv == ["-p", ArchiveListing.profile, "/usr/bin/bsdtar", "-x", "-O", "-q", "-n", "-f", "-", "--", "\\*"], "\(argv.dropFirst(2))")
check("entry ratio: at least the floor, the ratio above it, no overflow", ArchiveEntry.ratioLimit(archiveBytes: 10) == ArchiveEntry.ratioFloor
      && ArchiveEntry.ratioLimit(archiveBytes: 1 << 20) == (1 << 20) * ArchiveEntry.maxRatio && ArchiveEntry.ratioLimit(archiveBytes: .max) == .max)

// Hostile names, made safely on disk and renamed as bsdtar writes them (-s), in zip, tar.gz and 7z.
let hsrc = work.appendingPathComponent("hsrc")
try! fm.createDirectory(at: hsrc.appendingPathComponent("a"), withIntermediateDirectories: true)
let named: [(disk: String, entry: String, text: String)] = [
    ("star", "*", "only the star\n"), ("q", "?", "only the question\n"), ("br", "[", "only the bracket\n"), ("rb", "x]", "close bracket\n"),
    ("dash", "-rf", "dash rf\n"), ("dash2", "./-rf", "dot dash\n"), ("prog", "--use-compress-program=x", "not a program\n"), ("bs", "b\\*", "backslash star\n"),
    ("pw", "../../etc/passwd", "archive passwd\n"), ("uni", "caf\u{E9} 日本.md", "# unicode\n"), ("one", "one.txt", "one\n"), ("caret", "^one.txt", "caret\n"),
    ("dup1", "dup.txt", "first\n"), ("dup2", "dup.txt", "second\n"), ("a/x", "a/x", "under a\n"), ("afile", "a", "the file a\n"),
]
for n in named { try! Data(n.text.utf8).write(to: hsrc.appendingPathComponent(n.disk)) }
let regex = { (s: String) in s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ".", with: "\\.")
    .replacingOccurrences(of: "*", with: "\\*").replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "?", with: "\\?")
    .replacingOccurrences(of: "]", with: "\\]") }
// "a/x" comes first so "a" is also a folder of the archive; the file "a" follows it.
let order = ["a/x"] + named.map(\.disk).filter { $0 != "a/x" && $0 != "a" }
let renames = named.filter { $0.disk != $0.entry }.flatMap { ["-s", ",^\(regex($0.disk))$,\($0.entry),"] }
for (file, fmt) in [("h.zip", ["--format", "zip"]), ("h.tgz", ["-z"]), ("h.7z", ["--format", "7zip"])] {
    sh(["/usr/bin/bsdtar", "-c", "-P"] + fmt + ["-f", work.appendingPathComponent(file).path] + renames + order, in: hsrc)
}
let before = Set((try? fm.contentsOfDirectory(atPath: work.path)) ?? [])
let passwd = try? Data(contentsOf: URL(fileURLWithPath: "/etc/passwd"))
for file in ["h.zip", "h.tgz", "h.7z"] {
    let path = work.appendingPathComponent(file).path
    let listedNames = Set((listed(file) ?? []).compactMap { $0["name"] as? String })
    let read = { (name: String) -> ArchiveEntry.Outcome in ArchiveEntry.read(path, name: name, cap: 1 << 20) }
    let text = { (name: String) -> String? in if case .data(let d) = read(name) { return String(decoding: d, as: UTF8.self) }; return nil }
    // libarchive reads a zip's backslash as a folder separator: the name is asked for as it was listed.
    let bs = listedNames.first { $0.hasPrefix("b") && $0.hasSuffix("*") } ?? "b\\*"
    check("entry \(file): * ? [ ] and a backslash each read only their own file", text("*") == "only the star\n" && text("?") == "only the question\n"
          && text("[") == "only the bracket\n" && text("x]") == "close bracket\n" && text(bs) == "backslash star\n",
          "\([text("*"), text("?"), text("["), text("x]"), text(bs)]) \(bs)")
    check("entry \(file): a name that is an option is refused, never passed", read("-rf") == .refused && read("--use-compress-program=x") == .refused)
    check("entry \(file): ./-rf, which bsdtar would read as -rf, is a name after --, not an option", ["dash rf\n", "dot dash\n"].contains(text("./-rf") ?? ""),
          text("./-rf") ?? "nil")
    check("entry \(file): ../../etc/passwd is the archive's own file, streamed, never the system's", text("../../etc/passwd") == "archive passwd\n"
          && text("../../etc/passwd").map { Data($0.utf8) } != passwd)
    let uni = listedNames.first { $0.precomposedStringWithCanonicalMapping == "caf\u{E9} 日本.md" } ?? "caf\u{E9} 日本.md"
    check("entry \(file): a Unicode name, as listed, reads", text(uni) == "# unicode\n", "\(listedNames.sorted())")
    check("entry \(file): the file a is only a, not a/x after it", text("a") == "the file a\n", text("a") ?? "nil")
    check("entry \(file): ^one.txt reads itself, not one.txt (a leading ^ is escaped)", text("^one.txt") == "caret\n", text("^one.txt") ?? "nil")
    check("entry \(file): a name listed twice reads once, the first", text("dup.txt") == "first\n", text("dup.txt") ?? "nil")
    check("entry \(file): a missing name is not found", read("nope.txt") == .notFound)
    check("entry \(file): past its cap it is too large, and no bytes come back", ArchiveEntry.read(path, name: "one.txt", cap: 2) == .tooLarge)
}
check("entry: a file not named as an archive is refused", ArchiveEntry.read(work.appendingPathComponent("t.png").path, name: "src/a.txt", cap: 100) == .refused)
check("entry: reading writes nothing anywhere near the archives", Set((try? fm.contentsOfDirectory(atPath: work.path)) ?? []) == before
      && (try? Data(contentsOf: URL(fileURLWithPath: "/etc/passwd"))) == passwd)
for lone in ["notes.txt.gz", "notes.txt.bz2"] {
    let path = work.appendingPathComponent(lone).path
    check("entry \(lone): a lone compressed file's one file is decompressed whole", ArchiveEntry.read(path, name: "notes.txt", cap: 1 << 20) == .data(Data(repeating: 65, count: 12345)))
    check("entry \(lone): past the cap, its first part", ArchiveEntry.read(path, name: "notes.txt", cap: 100) == .partial(Data(repeating: 65, count: 100)))
    check("entry \(lone): no other name is read from it", ArchiveEntry.read(path, name: "other.txt", cap: 1 << 20) != .data(Data(repeating: 65, count: 12345)))
}
let loneBomb = work.appendingPathComponent("zeros.log")
try! Data(count: 8 << 20).write(to: loneBomb)
sh(["/usr/bin/gzip", "-k", "zeros.log"])
check("entry zeros.log.gz: a lone file expanding past the ratio is a bomb, not a partial read",
      ArchiveEntry.read(work.appendingPathComponent("zeros.log.gz").path, name: "zeros.log", cap: 64 << 20) == .bomb)
let pic = work.appendingPathComponent("pic.png")
try! Data(repeating: 9, count: 5000).write(to: pic)
sh(["/usr/bin/gzip", "-k", "pic.png"])
check("entry pic.png.gz: a lone file that is not text is too large past its cap, never shown in part",
      ArchiveEntry.read(work.appendingPathComponent("pic.png.gz").path, name: "pic.png", cap: 100) == .tooLarge)
check("lone: a .zst is listed as its one file but not read (nothing decompresses it)", ArchiveEntryView.isLoneCompressed("/x/a.log.zst")
      && !ArchiveEntryView.isLoneReadable("/x/a.log.zst") && ArchiveEntryView.isLoneReadable("/x/a.log.xz"))
check("lone: ArchiveEntryView names the one file and knows a tar in disguise", ArchiveEntryView.isLoneCompressed("/x/server.log.gz") && ArchiveEntryView.loneName("/x/server.log.gz") == "server.log"
      && !ArchiveEntryView.isLoneCompressed("/x/backup.tar.gz") && !ArchiveEntryView.isLoneCompressed("/x/t.zip"))

// Links inside an archive: listed as links, never read (bsdtar -x -O prints nothing for one), never followed.
let lsrc = work.appendingPathComponent("lsrc")
try! fm.createDirectory(at: lsrc, withIntermediateDirectories: true)
try! Data("target text\n".utf8).write(to: lsrc.appendingPathComponent("target.txt"))
try! fm.createSymbolicLink(atPath: lsrc.appendingPathComponent("soft.txt").path, withDestinationPath: "target.txt")
try! fm.createSymbolicLink(atPath: lsrc.appendingPathComponent("out.txt").path, withDestinationPath: "/etc/passwd")
try! fm.linkItem(at: lsrc.appendingPathComponent("target.txt"), to: lsrc.appendingPathComponent("hard.txt"))
sh(["/usr/bin/tar", "-cf", work.appendingPathComponent("links.tar").path, "target.txt", "hard.txt", "soft.txt", "out.txt"], in: lsrc)
let links = Dictionary((listed("links.tar") ?? []).map { ($0["name"] as? String ?? "", $0) }, uniquingKeysWith: { a, _ in a })
check("links: a symbolic and a hard link are marked as links, not folders; the file itself is not",
      ["soft.txt", "hard.txt", "out.txt"].allSatisfy { links[$0]?["isLink"] as? Bool == true && links[$0]?["isDir"] as? Bool == false }
      && links["target.txt"]?["isLink"] as? Bool == false, "\(links)")
let linksPath = work.appendingPathComponent("links.tar").path
check("links: bsdtar reads no bytes for a link member (why the preview never asks), and never the file outside",
      ["soft.txt", "out.txt"].allSatisfy { ArchiveEntry.read(linksPath, name: $0, cap: 1 << 20) == .data(Data()) }
      && ArchiveEntry.read(linksPath, name: "target.txt", cap: 1 << 20) == .data(Data("target text\n".utf8)))
let linkNote = ArchiveEntryView.payload(archive: linksPath, root: work.path, entry: "soft.txt", size: 0, modified: nil, data: nil, failure: "link")
check("links: the entry view says it is a link", linkNote["view"] as? String == "info" && (linkNote["note"] as? String)?.contains("link") == true)

// -n anchors a member's name: a top-level notes.txt listed after sub/notes.txt still reads itself.
let nsrc = work.appendingPathComponent("nsrc")
try! fm.createDirectory(at: nsrc.appendingPathComponent("sub"), withIntermediateDirectories: true)
try! Data("nested\n".utf8).write(to: nsrc.appendingPathComponent("sub/notes.txt"))
try! Data("top\n".utf8).write(to: nsrc.appendingPathComponent("notes.txt"))
sh(["/usr/bin/tar", "-cf", work.appendingPathComponent("order.tar").path, "sub/notes.txt", "notes.txt"], in: nsrc)
check("entry order.tar: notes.txt after sub/notes.txt reads the top-level one", ArchiveEntry.read(work.appendingPathComponent("order.tar").path, name: "notes.txt", cap: 1 << 20)
      == .data(Data("top\n".utf8)))

// A bomb: 40 MB of zeros that bzip2 packs into a few hundred bytes.
let bombDir = work.appendingPathComponent("bomb")
try! fm.createDirectory(at: bombDir, withIntermediateDirectories: true)
fm.createFile(atPath: bombDir.appendingPathComponent("zeros.txt").path, contents: Data(count: 40 << 20))
sh(["/usr/bin/tar", "-cjf", "bomb.tar.bz2", "bomb"])
let bombSize = ((try? fm.attributesOfItem(atPath: work.appendingPathComponent("bomb.tar.bz2").path))?[.size] as? Int) ?? 0
let t1 = Date()
let bomb = ArchiveEntry.read(work.appendingPathComponent("bomb.tar.bz2").path, name: "bomb/zeros.txt", cap: 20 << 20)
check("entry bomb: \(bombSize) bytes that expand to 40 MB are stopped at the ratio, not read to the cap (\(Int(Date().timeIntervalSince(t1) * 1000)) ms)",
      bomb == .bomb && Date().timeIntervalSince(t1) < 3, "\(bomb)")
let ok = ArchiveEntry.read(work.appendingPathComponent("t.tgz").path, name: "src/sub/b.bin", cap: 1 << 20)
check("entry: an ordinary file reads whole", ok == .data(Data(repeating: 7, count: 3000)))

// The stream itself: stopped past its limit, and on its timeout.
let t2 = Date()
let slow = ArchiveEntry.stream("/bin/sleep", ["30"], input: FileHandle.nullDevice, limit: 10, timeout: 0.5)
check("entry stream: a run past its timeout is stopped and says so (\(Int(Date().timeIntervalSince(t2) * 1000)) ms)",
      slow?.timedOut == true && slow?.over == false && Date().timeIntervalSince(t2) < 2, "\(String(describing: slow))")
let zeros = try! FileHandle(forReadingFrom: URL(fileURLWithPath: "/dev/zero"))
let t3 = Date()
let endless = ArchiveEntry.stream("/bin/cat", [], input: zeros, limit: 100_000, timeout: 5)
check("entry stream: endless output is cut at its limit and stopped at once", endless?.over == true && endless?.data.count == 100_000
      && Date().timeIntervalSince(t3) < 2, "\(String(describing: endless?.data.count))")

try? fm.removeItem(at: work)
print(failures == 0 ? "archive: all passed" : "archive: \(failures) failed")
exit(failures == 0 ? 0 : 1)
