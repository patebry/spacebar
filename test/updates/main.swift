// Checks Shared/Updates.swift: version parsing and comparison, the release response, and the cache. Build and run with
// test/updates/run.sh. Touches no network.
import Foundation

var failures = 0
func check(_ name: String, _ ok: Bool) { print("\(ok ? "PASS" : "FAIL") \(name)"); if !ok { failures += 1 } }

check("tag v0.1.2", Updates.version(fromTag: "v0.1.2") == "0.1.2")
check("tag without v", Updates.version(fromTag: "1.0") == "1.0")
for bad in ["", "v", "latest", "v1.2.3-beta", "v1..2", "v1.2.3.4.5", "v1.2 ", "../1", "v" + String(repeating: "9", count: 40)] {
    check("tag refused \(bad.debugDescription)", Updates.version(fromTag: bad) == nil)
}
check("0.1.3 > 0.1.2", Updates.isNewer("0.1.3", than: "0.1.2"))
check("0.1.10 > 0.1.9", Updates.isNewer("0.1.10", than: "0.1.9"))
check("1.0 > 0.9.9", Updates.isNewer("1.0", than: "0.9.9"))
check("0.1.2 not > 0.1.2", !Updates.isNewer("0.1.2", than: "0.1.2"))
check("0.1.2 not > 0.1.2.0", !Updates.isNewer("0.1.2", than: "0.1.2.0"))
check("0.1.1 not > 0.1.2", !Updates.isNewer("0.1.1", than: "0.1.2"))
check("junk not newer", !Updates.isNewer("zzz", than: "0.1.2"))

check("release parsed", Updates.parseLatest(Data(#"{"tag_name":"v0.2.0","name":"x"}"#.utf8)) == "0.2.0")
check("release bad tag", Updates.parseLatest(Data(#"{"tag_name":"<script>"}"#.utf8)) == nil)
check("release not json", Updates.parseLatest(Data("nope".utf8)) == nil)

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-updates-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let cache = dir.appendingPathComponent("update.json")
check("no cache", Updates.readCache(at: cache) == nil)
Updates.writeCache(.init(checked: 100, latest: "0.1.3"), at: cache)
check("cache round trip", Updates.readCache(at: cache) == .init(checked: 100, latest: "0.1.3"))
try! Data(#"{"checked":5,"latest":"1.0; rm -rf"}"#.utf8).write(to: cache)
check("cache bad version dropped", Updates.readCache(at: cache) == .init(checked: 5, latest: nil))

check("checkUpdates defaults on", Settings().checkUpdates)
check("checkUpdates read", Settings(dictionary: ["checkUpdates": false]).checkUpdates == false)
check("checkUpdates not a panel key", Settings.panelPatch("checkUpdates", false) == nil)

check("install 0.1.3 over 0.1.2", Updates.installRefusal("0.1.3", current: "0.1.2", enabled: true) == nil)
check("install refused when checks are off", Updates.installRefusal("0.1.3", current: "0.1.2", enabled: false) != nil)
for bad in ["0.1.2", "0.1.1", "v0.1.3", "0.1.3 --no-register", "0.1.3;id", "", "../0.2"] {
    check("install refused \(bad.debugDescription)", Updates.installRefusal(bad, current: "0.1.2", enabled: true) != nil)
}
check("installer arguments", Updates.installerArguments("0.1.3") == ["--version", "v0.1.3", "--no-prompt"])

// The detached run, against a stub: never the real installer.
func waitFor(_ what: String, in url: URL, seconds: Double = 10) -> String {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let s = try? String(contentsOf: url, encoding: .utf8), s.contains(what) { return s }
        usleep(50_000)
    }
    return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
}
let stub = dir.appendingPathComponent("stub.sh")
try! """
echo "args: $*"
echo "home: $HOME path: $PATH"
if read line; then echo "stdin: $line"; else echo "stdin: eof"; fi
echo "fds: $(ls /dev/fd | tr "\\n" " ")"
echo "to stderr" >&2
echo started
while [ ! -e "$HOME/go" ]; do sleep 0.05; done
echo finished

""".write(to: stub, atomically: true, encoding: .utf8)
let logURL = dir.appendingPathComponent("Logs/spacebar-update.log")
let leaked = dup2(open("/dev/null", O_RDONLY), 57)
let env = ["HOME": dir.path, "PATH": "/usr/bin:/bin"]
let first = Updates.runDetached(script: stub, arguments: Updates.installerArguments("9.9.9"), log: logURL, environment: env)
check("stub spawned", (try? first.get()) != nil)
let pid = (try? first.get()) ?? -1
try? FileManager.default.removeItem(at: stub)
var log1 = waitFor("started", in: logURL)
check("stub gets the arguments", log1.contains("args: --version v9.9.9 --no-prompt"))
check("stub gets only the given environment", log1.contains("home: \(dir.path) path: /usr/bin:/bin"))
check("stub stdin is /dev/null", log1.contains("stdin: eof"))
check("stub stderr goes to the log", log1.contains("to stderr"))
let fds = log1.split(separator: "\n").first { $0.hasPrefix("fds: ") }?.split(separator: " ").dropFirst().map(String.init) ?? []
check("stub inherits no descriptor of the parent's", leaked == 57 && !fds.isEmpty && !fds.contains("57"))
check("stub runs from a copy, so the original can go", log1.contains("started"))
check("stub has a session of its own", pid > 0 && getsid(pid) == pid && getsid(pid) != getsid(0) && getpgid(pid) == pid)
check("a second run waits for the first", Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env)
      == .failure(.init(message: "an update is already running")))
FileManager.default.createFile(atPath: dir.appendingPathComponent("go").path, contents: nil)
log1 = waitFor("finished", in: logURL)
check("stub ran to the end", log1.contains("finished"))
var gone = false
for _ in 0..<100 { if kill(pid, 0) != 0 { gone = true; break }; usleep(50_000) }
check("stub reaped", gone)
check("log keeps the run's header", log1.contains("=== ") && log1.contains(" --version v9.9.9 --no-prompt ==="))
check("a missing script is an error", (try? Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env).get()) == nil)
close(leaked)

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
