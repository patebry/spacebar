// Checks TextDecoding (Shared/FolderListing.swift) and the text view FileView builds with it. Build and run with test/encoding/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}
let fx = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
func data(_ name: String) -> Data { try! Data(contentsOf: fx.appendingPathComponent(name)) }
func decode(_ name: String) -> TextDecoding.Decoded? { TextDecoding.decode(data(name)) }

let cafe = "Café naïve — “quoted” résumé, 25 €\nZoë’s façade, Grüße aus München\n"
let wide = "Hello, wide world: café, 日本語, emoji 🚀\nsecond line\n"
check("UTF-8 stays UTF-8", TextDecoding.decode(Data(cafe.utf8)) == TextDecoding.Decoded(text: cafe, name: "UTF-8"))
check("UTF-8 with a BOM: the mark is dropped", decode("utf8-bom.csv") == TextDecoding.Decoded(text: "name,city\nZoë,Zürich\n", name: "UTF-8"))
check("Windows-1252: curly quotes, dashes and the euro sign", decode("latin1-cp1252.txt") == TextDecoding.Decoded(text: cafe, name: "Windows-1252"),
      "\(String(describing: decode("latin1-cp1252.txt")))")
check("ISO Latin-1 reads the same letters", decode("latin1-iso.txt")?.text == "Grüße aus München, ß ä ö ü, Ångström\n", "\(String(describing: decode("latin1-iso.txt")))")
for (f, name) in [("utf16le-bom.txt", "UTF-16 LE"), ("utf16be-bom.txt", "UTF-16 BE"), ("utf32le-bom.txt", "UTF-32 LE"), ("utf32be-bom.txt", "UTF-32 BE")] {
    check("\(name) with a BOM, emoji included", decode(f) == TextDecoding.Decoded(text: wide, name: name), "\(String(describing: decode(f)))")
}
check("UTF-16 LE without a BOM (a Windows log)", decode("utf16le-nobom.log") == TextDecoding.Decoded(text: String(repeating: "Windows log line one\r\nline two: café\r\n", count: 3), name: "UTF-16 LE"),
      "\(String(describing: decode("utf16le-nobom.log")))")
check("Shift JIS is found by the detector", decode("shiftjis.txt") == TextDecoding.Decoded(text: "日本語のテキストです。これはテストです。\n", name: "Shift JIS"),
      "\(String(describing: decode("shiftjis.txt")))")

check("binary with NUL bytes is not text", decode("binary-nul.dat") == nil)
check("binary of control bytes without a NUL is not text", decode("binary-controls.dat") == nil)
check("UTF-16 holding a NUL character is not text", decode("utf16-nul.txt") == nil)
check("a PNG header is not text", TextDecoding.decode(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0x0D, 0x49, 0x48, 0x44, 0x52])) == nil)
check("a bare UTF-16 BOM is empty text", TextDecoding.decode(Data([0xFF, 0xFE])) == TextDecoding.Decoded(text: "", name: "UTF-16 LE"))
check("ASCII is never mistaken for UTF-16", TextDecoding.decode(Data(String(repeating: "plain ascii text\n", count: 20).utf8))?.name == "UTF-8")

// Cut anywhere, as the first 2 MB of a file are: a code unit or character cut at the end goes, the rest reads.
let w16 = data("utf16le-bom.txt"), w32 = data("utf32be-bom.txt"), c8 = Data(cafe.utf8)
check("UTF-16 cut mid code unit", TextDecoding.decode(w16.prefix(w16.count - 1))?.text == String(wide.dropLast()))
let emoji16 = Data([0xFF, 0xFE]) + "ab🚀".data(using: .utf16LittleEndian)!
check("UTF-16 cut inside a surrogate pair drops the half", TextDecoding.decode(emoji16.prefix(emoji16.count - 2))?.text == "ab")
check("UTF-32 cut mid character", TextDecoding.decode(w32.prefix(w32.count - 3))?.text == String(wide.dropLast()))
check("UTF-8 cut inside a character", TextDecoding.decode(c8.prefix(4)) == TextDecoding.Decoded(text: "Caf", name: "UTF-8"))

// The file view: what used to be an info card is text, named with its encoding; binary is still the info card.
let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("spacebar-encoding-\(getpid())")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
func payload(_ f: String, as name: String, kind: FileKind) -> [String: Any] {
    let u = dir.appendingPathComponent(name)
    try? FileManager.default.removeItem(at: u)
    try! FileManager.default.copyItem(at: fx.appendingPathComponent(f), to: u)
    return FileView.payload(path: u.path, kind: kind, root: dir.path, reason: "open", canOpen: true)
}
let l = payload("latin1-cp1252.txt", as: "notes.txt", kind: .text)
check("payload: a Windows-1252 .txt is text, its kind naming the encoding", l["view"] as? String == "text" && l["text"] as? String == cafe
      && l["encoding"] as? String == "Windows-1252" && (l["kindName"] as? String ?? "").hasSuffix("(Windows-1252)"), "\(l)")
let u16 = payload("utf16le-bom.txt", as: "strings.swift", kind: .code)
check("payload: UTF-16 source is highlighted code", u16["view"] as? String == "code" && u16["text"] as? String == wide && u16["lang"] as? String == "swift")
let csv = payload("utf8-bom.csv", as: "t.csv", kind: .csv)
check("payload: a UTF-8 CSV with a BOM is a table without the mark, and no encoding note", csv["view"] as? String == "csv"
      && csv["text"] as? String == "name,city\nZoë,Zürich\n" && csv["encoding"] == nil)
let unknown = payload("utf32le-bom.txt", as: "README-WIDE", kind: .other)
check("payload: a file of unknown kind in UTF-32 is shown as text", unknown["view"] as? String == "text")
check("payload: binary stays the info card", payload("binary-nul.dat", as: "x.dat", kind: .other)["view"] as? String == "info"
      && payload("binary-controls.dat", as: "y.dat", kind: .other)["view"] as? String == "info")
check("the sniff for Markdown notes is unchanged: UTF-8 only", FileTypes.looksLikeText(Data(cafe.utf8))
      && !FileTypes.looksLikeText(data("latin1-cp1252.txt")) && !FileTypes.looksLikeText(data("utf16le-bom.txt")))

print(failures == 0 ? "\nall encoding checks passed" : "\n\(failures) encoding checks failed")
exit(failures == 0 ? 0 : 1)
