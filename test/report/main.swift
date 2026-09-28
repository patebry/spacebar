// Checks App/ProblemReport.swift: the prefilled GitHub issue URL (encoding, the log's tail and truncation) and reading the log.
// Build and run with test/report/run.sh. Touches no network and opens nothing.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool, _ detail: String = "") {
    print("\(ok ? "PASS" : "FAIL") \(name)\(ok || detail.isEmpty ? "" : ": \(detail)")")
    if !ok { failures += 1 }
}

func query(_ url: URL) -> [String: String] {
    Dictionary((URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { a, _ in a }
}

let sys = ProblemReport.System(version: "0.2.0 (7)", macOS: "Version 15.0 (Build 24A335)", model: "Mac14,2", arch: "arm64")

let plain = ProblemReport.url(sys, log: nil)
let q = query(plain)
check("the new-issue page of patebry/spacebar", plain.absoluteString.hasPrefix("https://github.com/patebry/spacebar/issues/new?title="))
check("title and body only", Set(q.keys) == ["title", "body"], "\(q.keys)")
check("title", q["title"] == "Problem: ")
for part in ["spacebar: 0.2.0 (7)", "macOS: Version 15.0 (Build 24A335)", "Mac: Mac14,2, arm64", "Remove anything you would rather not share."] {
    check("body has \(part.debugDescription)", q["body"]?.contains(part) == true)
}
check("no log section without a log", q["body"]?.contains("spacebar-update.log") == false)

let tricky = "a & b = c + d # e ? f / g % h\n\"quoted\" <tag> é 🚀 \\ `tick` ```fence```"
let u = ProblemReport.url(sys, log: tricky)
let raw = u.absoluteString
let bodyPart = String(raw[raw.range(of: "&body=")!.upperBound...])
check("only unreserved characters are left bare", bodyPart.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-._~%".contains($0)) }, bodyPart)
check("exactly two query items: & = + # in the text stay text", query(u).count == 2 && raw.components(separatedBy: "&").count == 2)
check("the log round-trips, its fence neutralised", query(u)["body"]?.contains(tricky.replacingOccurrences(of: "```", with: "'''")) == true)
check("+ is encoded (it would read as a space)", bodyPart.contains("%2B") && !bodyPart.contains("+"))
check("a space is %20", bodyPart.contains("%20"))

let lines = (1...100).map { "line \($0)" }.joined(separator: "\n") + "\n"
let t = ProblemReport.tail(lines, home: "/Users/someone")
check("tail keeps the last 40 lines", t.split(separator: "\n") == (61...100).map { Substring("line \($0)") }, t)
check("tail of a short log is all of it", ProblemReport.tail("one\ntwo", home: "/x") == "one\ntwo")
let long = ProblemReport.tail(String(repeating: "x", count: 500), home: "/x")
check("a long line is cut to 200 characters", long.count == 201 && long.hasSuffix("…"), "\(long.count)")
check("the home folder shows as ~", ProblemReport.tail("rm /Users/someone/Applications/spacebar.app", home: "/Users/someone") == "rm ~/Applications/spacebar.app")
check("a longer name that starts with the home folder's is left alone",
      ProblemReport.tail("/Users/someone2/x and /Users/someone.old and '/Users/someone'", home: "/Users/someone") == "/Users/someone2/x and /Users/someone.old and '~'")
let esc = ProblemReport.tail(#"would run: pkill -f ^/Users/a\.b/Applications/spacebar\.app/ and /Users/a.b/x"#, home: "/Users/a.b")
check("the home folder is redacted as the installer escapes it too", esc == #"would run: pkill -f ^~/Applications/spacebar\.app/ and ~/x"#, esc)

let noisy = (1...40).map { "\($0) " + String(repeating: "é&", count: 90) }.joined(separator: "\n")
let big = ProblemReport.url(sys, log: ProblemReport.tail(noisy, home: "/x"))
let bigBody = query(big)["body"] ?? ""
check("a long log is trimmed to fit the URL limit", big.absoluteString.count <= ProblemReport.maxURL, "\(big.absoluteString.count)")
check("trimming drops the oldest lines and keeps the newest", bigBody.contains("40 é&") && !bigBody.contains("\n1 é&"), String(bigBody.suffix(80)))
check("the system details survive trimming", bigBody.contains("Mac: Mac14,2, arm64"))

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-report-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: dir) }
let log = dir.appendingPathComponent("spacebar-update.log")
check("no log file: no log", ProblemReport.readLog(at: log) == nil)
try! Data().write(to: log)
check("an empty log: no log", ProblemReport.readLog(at: log) == nil)
try! Data(((1...5000).map { "entry \($0) " + String(repeating: "-", count: 40) }.joined(separator: "\n") + "\n").utf8).write(to: log)
let read = ProblemReport.readLog(at: log) ?? ""
check("a large log: its last 40 lines", read.split(separator: "\n").count == 40 && read.hasSuffix("entry 5000 " + String(repeating: "-", count: 40))
      && read.hasPrefix("entry 4961 "), String(read.prefix(40)))

let me = ProblemReport.current()
check("this Mac's details are filled", !me.macOS.isEmpty && !me.model.isEmpty && me.model != "unknown" && !me.arch.isEmpty, "\(me)")

print(failures == 0 ? "\nall report checks passed" : "\n\(failures) report checks failed")
exit(failures == 0 ? 0 : 1)
