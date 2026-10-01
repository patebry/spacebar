// Checks ContentSearch (Shared/FolderScan.swift). Build and run with test/search/run.sh.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
    if !ok { failures += 1 }
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok ? "" : ": \(detail())")")
}

let fx = CommandLine.arguments[1], repo = CommandLine.arguments[2]
let fm = FileManager.default
func put(_ rel: String, _ text: String) { put(rel, Data(text.utf8)) }
func put(_ rel: String, _ data: Data) {
    let p = (fx as NSString).appendingPathComponent(rel)
    try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: p))
}

/// Every report of one search, and the hits in order.
func search(_ q: String, root: String = fx, hidden: Bool = false, only: Set<String>? = nil, limits: ContentSearch.Limits = .init(),
            cancel: ContentSearch.Cancel = .init()) -> (reports: [ContentSearch.Progress], hits: [ContentSearch.Hit]) {
    var reports: [ContentSearch.Progress] = []
    ContentSearch.run(query: q, root: root, showHidden: hidden, only: only, limits: limits, cancel: cancel) { reports.append($0) }
    return (reports, reports.flatMap(\.hits))
}
func names(_ hits: [ContentSearch.Hit]) -> [String] { hits.map { String($0.path.dropFirst(fx.count + 1)) } }

put("README.md", "# Project\n\nThe Widget renders fast.\nAnother widget line, and WIDGET again.\n")
put("src/app.ts", "export function widget() {\n\treturn 'widgetwidget';\n}\n")
put("src/deep/more/notes.txt", "nothing here\n")
put("data.json", "{\"name\": \"widget\"}")
put("table.csv", "a,b\nwidget,1\n")
put("photo.png", Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) + Data("widget".utf8))
put("blob.txt", Data([0x77, 0x69, 0x64, 0x67, 0x65, 0x74, 0, 0, 1, 2, 3]))
put("utf16.txt", Data([0xFF, 0xFE]) + "a Widget in UTF-16\n".data(using: .utf16LittleEndian)!)
put("latin1.txt", "caf\u{E9} widget\n".data(using: .isoLatin1)!)
put(".hidden.md", "widget in a hidden file\n")
put(".hid/inside.md", "widget in a hidden folder\n")
put("node_modules/pkg/index.js", "widget in a dependency\n")
put("unicode.md", "Straße und STRASSE, Ünïcödé ÜNÏCÖDÉ\n")
put("long.md", String(repeating: "x", count: 400) + " the needle here " + String(repeating: "y", count: 400) + "\n")
put("big.log", String(repeating: "filler line\n", count: (2 << 20) / 12 + 10) + "widget past the cap\n")
put("Package.app/Contents/x.txt", "widget inside a package\n")
try? fm.createSymbolicLink(atPath: fx + "/outside.md", withDestinationPath: "/etc/hosts")
try? fm.createSymbolicLink(atPath: fx + "/loop", withDestinationPath: fx + "/src")

// Matching and snippets.
let w = search("widget")
check("finds text, code, JSON, CSV, Markdown, UTF-16 and Latin-1, root first",
      Array(names(w.hits).prefix(5)) == ["data.json", "latin1.txt", "README.md", "table.csv", "utf16.txt"] && w.hits.count == 6
      && w.hits[5].path.hasSuffix("/app.ts"), "\(names(w.hits))")
let readme = w.hits.first { $0.path.hasSuffix("README.md") }
check("case-insensitive, every match counted", readme?.count == 3, "\(String(describing: readme))")
check("the snippet is the first match's line, its line number 1-based", readme?.snippet == "The Widget renders fast." && readme?.line == 3,
      "\(String(describing: readme))")
let app = w.hits.first { $0.path.hasSuffix("app.ts") }
check("matches do not overlap; a tab reads as a space and the snippet is trimmed", app?.count == 3 && app?.snippet == "export function widget() {",
      "\(String(describing: app))")
check("binary is skipped: an image and a file with NUL bytes", !names(w.hits).contains("photo.png") && !names(w.hits).contains("blob.txt"))
check("hidden files and folders are not searched unless shown", !names(w.hits).contains { $0.contains(".hid") })
check("dependency folders and packages are never entered", !names(w.hits).contains { $0.contains("node_modules") || $0.contains("Package.app") })
check("a link out of the root is not followed, and a folder reached twice is searched once",
      !names(w.hits).contains("outside.md") && names(w.hits).filter { $0.hasSuffix("app.ts") }.count == 1,
      "\(names(w.hits))")
check("the text past the per-file cap is not read", !names(w.hits).contains("big.log"))
let last = w.reports.last!
check("one final report: every file searched, nothing cut short", last.done && last.stopped == nil && last.searched == last.total && last.total > 0,
      "\(last)")
let hw = search("widget", hidden: true)
check("with hidden files shown, hidden files and folders are searched", names(hw.hits).contains(".hidden.md") && names(hw.hits).contains(".hid/inside.md"),
      "\(names(hw.hits))")
let u = search("straße").hits.first
check("a non-ASCII query matches case-insensitively", u?.path.hasSuffix("unicode.md") == true && u?.count == 1, "\(String(describing: u))")
check("an accented query matches its capitals", search("ünïcödé").hits.first?.count == 2)
put("../\((fx as NSString).lastPathComponent)-drift/d.md", "İİİİİİ ẞẞẞẞ \u{212A}\u{212A}\u{212A} then the straße is here and more text after it to make the line long enough to cut\n")
let drift = search("straße", root: fx + "-drift").hits.first
check("a non-ASCII match is found in its own line after letters whose lowercase is longer or shorter", drift?.snippet.contains("straße") == true,
      "\(String(describing: drift?.snippet))")
let long = search("NEEDLE").hits.first
check("a long line's snippet is cut around the match with ellipses",
      long.map { $0.snippet.hasPrefix("…") && $0.snippet.hasSuffix("…") && $0.snippet.contains("the needle here") && $0.snippet.utf8.count <= 170 } == true,
      "\(String(describing: long?.snippet))")
check("no match: a final report with no hits", search("zzzqqq").hits.isEmpty && search("zzzqqq").reports.last?.done == true)
check("an empty or oversized query searches nothing", search("").reports.count == 1 && search("").reports[0].total == 0
      && search(String(repeating: "a", count: 300)).reports[0].total == 0)
let picked: Set<String> = [fx + "/README.md", fx + "/src"]
check("a selection's sidebar searches only the selected items", names(search("widget", only: picked).hits) == ["README.md", "src/app.ts"],
      "\(names(search("widget", only: picked).hits))")
put("src/other.ts", "widget not selected\n")
let nested: Set<String> = [fx + "/data.json", fx + "/src/app.ts"]
check("a selection across folders searches the selected files in each, and nothing else beside them",
      names(search("widget", only: nested).hits) == ["data.json", "src/app.ts"], "\(names(search("widget", only: nested).hits))")
try! fm.removeItem(atPath: fx + "/src/other.ts")

// Caps: each stops the search and says which.
var lim = ContentSearch.Limits()
lim.maxFiles = 3
let f3 = search("widget", limits: lim)
check("the file cap: only the first files, and the search says so", f3.reports.last?.total == 3 && f3.reports.last?.stopped == "files", "\(f3.reports.last!)")
lim = .init(); lim.maxTotalBytes = 40
let b = search("widget", limits: lim).reports.last!
check("the total bytes cap stops the search, partial", b.stopped == "bytes" && b.searched < b.total, "\(b)")
lim = .init(); lim.maxResults = 2
let r2 = search("widget", limits: lim)
check("the results cap", r2.hits.count == 2 && r2.reports.last?.stopped == "results", "\(r2.reports.last!)")
lim = .init(); lim.budget = 0
check("the time budget", search("widget", limits: lim).reports.last?.stopped == "time")
lim = .init(); lim.maxFileBytes = 12
check("the per-file cap: a match past it is not found", !names(search("renders", limits: lim).hits).contains("README.md"))

// Cancellation: nothing is reported after it, and it stops the search between files.
let many = fx + "-many"
for i in 0..<400 { put("../\((many as NSString).lastPathComponent)/f\(i).txt", String(repeating: "lorem ipsum widget\n", count: 50)) }
let c = ContentSearch.Cancel()
var after = 0, seen = 0
ContentSearch.run(query: "widget", root: many, showHidden: false, every: 0, cancel: c) { p in
    if c.isCancelled { after += 1 }
    seen += p.hits.count
    if seen >= 5 { c.cancel() }
}
check("a cancelled search reports nothing more and stops early", after == 0 && seen < 400, "after=\(after) seen=\(seen)")
let pre = ContentSearch.Cancel()
pre.cancel()
var any = false
ContentSearch.run(query: "widget", root: many, showHidden: false, cancel: pre) { _ in any = true }
check("a search cancelled before it starts reports nothing", !any)

// Timings: the first result and the whole search, warm (the second run of each).
func timed(_ q: String, root: String) -> (first: Double, total: Double, files: Int, hits: Int) {
    var first = -1.0, files = 0, hits = 0
    let t0 = Date()
    ContentSearch.run(query: q, root: root, showHidden: false, cancel: .init()) { p in
        if first < 0 && !p.hits.isEmpty { first = Date().timeIntervalSince(t0) * 1000 }
        hits += p.hits.count
        files = p.total
    }
    return (first, Date().timeIntervalSince(t0) * 1000, files, hits)
}
let gen = fx + "-repo"
var rnd = SystemRandomNumberGenerator()
let words = ["alpha", "beta", "gamma", "delta", "render", "sidebar", "folder", "listing", "cursor", "session", "window", "filter"]
for i in 0..<1000 {
    let ext = ["swift", "ts", "md", "json", "txt"][i % 5]
    var body = ""
    for _ in 0..<(40 + Int.random(in: 0..<200, using: &rnd)) { body += (0..<8).map { _ in words.randomElement(using: &rnd)! }.joined(separator: " ") + "\n" }
    if i % 97 == 50 { body += "let quokka = true\n" }
    put("../\((gen as NSString).lastPathComponent)/pkg\(i / 50)/mod\(i % 7)/file\(i).\(ext)", body)
}
// Warm: the files have been read once (the disk cache). "walk": the tree is listed again, as for the first keystroke on a root;
// "cached": the listing is reused, as for the keystrokes after it.
for (label, root, q) in [("generated 1,000 files", gen, "quokka"), ("generated 1,000 files, common word", gen, "sidebar"),
                         ("this repository", repo, "FolderListing"), ("this repository, rare", repo, "quokka")] {
    _ = timed(q, root: root)
    ContentSearch.run(query: "", root: fx, showHidden: false, cancel: .init()) { _ in }
    _ = timed("zz" + q, root: fx)
    let walk = timed(q, root: root)
    let cached = timed(q, root: root)
    print(String(format: "TIME %@ \"%@\": %d files, %d hits; walk: first result %.1f ms, done %.1f ms; cached: first result %.1f ms, done %.1f ms",
                 label, q, walk.files, walk.hits, walk.first, walk.total, cached.first, cached.total))
    if label == "generated 1,000 files" {
        check("first result within 100 ms on 1,000 files (warm), the tree listed afresh", walk.first >= 0 && walk.first < 100, "\(walk.first) ms")
    }
}

print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
