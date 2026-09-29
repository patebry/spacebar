import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
func details(_ name: String) -> [[String]] { DiskImage.details(dir.appendingPathComponent(name).path) }

let want: [(String, String)] = [("UDZO", "Compressed (zlib)"), ("ULFO", "Compressed (LZFSE)"), ("UDBZ", "Compressed (bzip2)"), ("UDRO", "Uncompressed")]
for (f, name) in want {
    check("\(f): format \(name), not encrypted", details("\(f).dmg") == [["Format", name], ["Encrypted", "No"]], "\(details("\(f).dmg"))")
}
check("an encrypted image says so, and nothing it cannot read", details("locked.dmg") == [["Encrypted", "Yes, with a password"]], "\(details("locked.dmg"))")
check("a raw image with no trailer: not encrypted, no format", details("raw.dmg") == [["Encrypted", "No"]], "\(details("raw.dmg"))")

// Hostile trailers: a table past the end, one too large, a table that is not a plist, a chunk count far beyond the data.
func koly(xmlOffset: UInt64, xmlLength: UInt64) -> Data {
    var k = Data(count: 512)
    k.replaceSubrange(0..<4, with: Data("koly".utf8))
    for (at, v) in [(216, xmlOffset), (224, xmlLength)] { for i in 0..<8 { k[at + i] = UInt8((v >> (56 - 8 * UInt64(i))) & 0xff) } }
    return k
}
func write(_ name: String, _ body: Data, _ trailer: Data) { try! (body + trailer).write(to: dir.appendingPathComponent(name)) }
write("past.dmg", Data(count: 1024), koly(xmlOffset: 1 << 40, xmlLength: 100))
write("huge.dmg", Data(count: 1024), koly(xmlOffset: 0, xmlLength: UInt64(DiskImage.maxTableBytes) + 1))
write("wrap.dmg", Data(count: 1024), koly(xmlOffset: .max - 10, xmlLength: 100))
write("junk.dmg", Data(repeating: 0x41, count: 1024), koly(xmlOffset: 0, xmlLength: 1024))
var mish = Data("mish".utf8) + Data(count: 196) + Data([0xff, 0xff, 0xff, 0xff]) + Data(count: 40)
mish[204] = 0x80
mish[204 + 3] = 5
mish[204 + 16 + 7] = 9
let table = try! PropertyListSerialization.data(fromPropertyList: ["resource-fork": ["blkx": [["Data": mish]]]], format: .xml, options: 0)
write("lying.dmg", table, koly(xmlOffset: 0, xmlLength: UInt64(table.count)))
for n in ["past", "huge", "wrap", "junk"] {
    check("\(n): a bad trailer gives no format, and no crash", details("\(n).dmg") == [["Encrypted", "No"]], "\(details("\(n).dmg"))")
}
check("a block table claiming 4 billion chunks reads only the one it holds", details("lying.dmg") == [["Format", "Compressed (zlib)"], ["Encrypted", "No"]],
      "\(details("lying.dmg"))")
try! Data(count: 100).write(to: dir.appendingPathComponent("tiny.dmg"))
check("a file too small for a trailer, a folder and a missing file: nothing", details("tiny.dmg").isEmpty && DiskImage.details(dir.path).isEmpty
      && details("missing.dmg").isEmpty)
print(failures == 0 ? "diskimage: all passed" : "diskimage: \(failures) failed")
exit(failures == 0 ? 0 : 1)
