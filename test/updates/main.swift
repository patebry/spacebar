// Checks Shared/Updates.swift: version parsing and comparison, the release response, the cache and the last run's status, what
// the popover offers, the detached run (against a stub), scripts/install.sh's exit record in a dry run that fails its
// download from a missing file:// URL, the order its quit_extensions and quit_viewer stop stand-in processes in, and its dry run
// through registration with the Space helper's agent loaded or not. Build and run with test/updates/run.sh. Touches no network
// and installs nothing.
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
check("release tag without v refused", Updates.parseLatest(Data(#"{"tag_name":"0.2.0"}"#.utf8)) == nil)

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("spacebar-updates-\(UUID().uuidString)")
try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let cache = dir.appendingPathComponent("update.json")
check("no cache", Updates.readCache(at: cache) == nil)
Updates.writeCache(.init(checked: 100, latest: "0.1.3"), at: cache)
check("cache round trip", Updates.readCache(at: cache) == .init(checked: 100, latest: "0.1.3"))
try! Data(#"{"checked":5,"latest":"1.0; rm -rf"}"#.utf8).write(to: cache)
check("cache bad version dropped", Updates.readCache(at: cache) == .init(checked: 5, latest: nil))
Updates.writeCache(.init(checked: 100, latest: "0.1.3", started: .init(version: "0.1.3", at: 90)), at: cache)
check("cache keeps the started update", Updates.readCache(at: cache)?.started == .init(version: "0.1.3", at: 90))
try! Data(#"{"checked":5,"latest":"0.1.3","started":{"version":"v0.1.3","at":1}}"#.utf8).write(to: cache)
check("cache bad started dropped", Updates.readCache(at: cache) == .init(checked: 5, latest: "0.1.3"))
let statusFile = dir.appendingPathComponent("update-status.json")
check("no status", Updates.readStatus(at: statusFile) == nil)
Updates.writeStatus(.init(version: "0.1.3", exitStatus: 1, finishedAt: 120), at: statusFile)
check("status round trip", Updates.readStatus(at: statusFile) == .init(version: "0.1.3", exitStatus: 1, finishedAt: 120))
try! Data(#"{"version":"x","exitStatus":0,"finishedAt":1}"#.utf8).write(to: statusFile)
check("status bad version refused", Updates.readStatus(at: statusFile) == nil)

check("release build checks", Updates.checks(build: "42", testFlag: false))
check("dev build does not check", !Updates.checks(build: "1", testFlag: false))
check("dev build checks with the test flag", Updates.checks(build: "1", testFlag: true))

// What the popover offers.
let started = Updates.Started(version: "0.1.3", at: 1000)
func offer(latest: String? = "0.1.3", started: Updates.Started? = nil, finished: Updates.Finished? = nil, place: String? = nil, running: Bool = true) -> Updates.Offer {
    Updates.offer(current: "0.1.2", latest: latest, started: started, finished: finished, place: place, running: running)
}
check("offer: nothing newer", offer(latest: "0.1.2") == .none && offer(latest: nil) == .none)
check("offer: available", offer() == .available("0.1.3"))
check("offer: elsewhere is never installable", offer(place: "/Applications/spacebar.app") == .elsewhere("0.1.3", place: "/Applications/spacebar.app"))
check("offer: started, still running", offer(started: started) == .inProgress("0.1.3"))
check("offer: a start for an older release does not hide this one", offer(started: .init(version: "0.1.2", at: 1000)) == .available("0.1.3"))
if case .failed(_, let reason) = offer(started: started, finished: .init(version: "0.1.3", exitStatus: 1, finishedAt: 1050)) {
    check("offer: failed run shows its status and the log", reason.contains("status 1") && reason.contains("spacebar-update.log"))
} else { check("offer: failed run", false) }
check("offer: an earlier run's end does not count", offer(started: started, finished: .init(version: "0.1.3", exitStatus: 1, finishedAt: 900)) == .inProgress("0.1.3"))
check("offer: finished fine, old copy still running", offer(started: started, finished: .init(version: "0.1.3", exitStatus: 0, finishedAt: 1050)) == .none)
if case .failed = offer(started: started, running: false) { check("offer: a run no longer running with no end recorded fails", true) } else { check("offer: a run no longer running with no end recorded fails", false) }
check("offer: a run holding the lock is in progress however long", offer(started: .init(version: "0.1.3", at: 0)) == .inProgress("0.1.3"))
for o: Updates.Offer in [.none, .available("0.1.3"), .elsewhere("0.1.3", place: "~/x"), .inProgress("0.1.3"), .failed("0.1.3", reason: "r")] {
    check("offer json round trip \(o)", Updates.Offer(json: o.json) == o)
}
for bad in [#"{"state":"available"}"#, #"{"state":"available","version":"v0.1.3"}"#, #"{"state":"install","version":"0.1.3"}"#, "[]", "x"] {
    check("offer json refused \(bad)", Updates.Offer(json: Data(bad.utf8)) == nil)
}
let busy = Updates.advice(for: "an update is already running"), cannot = Updates.advice(for: "could not start the installer: x")
check("advice: already running, no install command", busy == ("An update is already running.", false))
check("advice: start failure offers the install command", cannot.copy && cannot.text == "Could not start the installer: x.")
check("advice: not in ~/Applications, no install command", !Updates.advice(for: "spacebar is not in ~/Applications").copy)
check("advice: installer failure offers the install command", Updates.advice(for: "The installer stopped with status 1. See x.").copy)

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
let first = Updates.runDetached(script: stub, arguments: Updates.installerArguments("9.9.9"), log: logURL, environment: env, temporary: dir)
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
check("running while the stub holds the log", Updates.isRunning(log: logURL))
check("stub has a session of its own", pid > 0 && getsid(pid) == pid && getsid(pid) != getsid(0) && getpgid(pid) == pid)
check("a second run waits for the first", Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env, temporary: dir)
      == .failure(.init(message: "an update is already running")))
check("an uninstall says so when its lock is held", Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env, temporary: dir, job: .uninstall)
      == .failure(.init(message: "an uninstall is already running")))
FileManager.default.createFile(atPath: dir.appendingPathComponent("go").path, contents: nil)
log1 = waitFor("finished", in: logURL)
check("stub ran to the end", log1.contains("finished"))
var gone = false
for _ in 0..<100 { if kill(pid, 0) != 0 { gone = true; break }; usleep(50_000) }
check("stub reaped", gone)
check("not running once the stub is gone", !Updates.isRunning(log: logURL))
check("not running without a log", !Updates.isRunning(log: dir.appendingPathComponent("none.log")))
check("log keeps the run's header", log1.contains("=== ") && log1.contains(" --version v9.9.9 --no-prompt ==="))
check("a missing script is an error", (try? Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env, temporary: dir).get()) == nil)
do {
    // The uninstaller's copy keeps its name, so the script (which removes its own folder) runs as uninstall.sh.
    let named = dir.appendingPathComponent("named", isDirectory: true)
    try! FileManager.default.createDirectory(at: named, withIntermediateDirectories: true)
    let script = named.appendingPathComponent("uninstall.sh")
    try! "echo \"ran as $0\"\n".write(to: script, atomically: true, encoding: .utf8)
    let ranLog = dir.appendingPathComponent("Logs/named.log")
    let done = DispatchSemaphore(value: 0)
    _ = Updates.runDetached(script: script, arguments: [], log: ranLog, environment: env, temporary: dir, job: .uninstall) { _ in done.signal() }
    _ = done.wait(timeout: .now() + 10)
    let said = (try? String(contentsOf: ranLog, encoding: .utf8)) ?? ""
    check("an uninstall runs from a private copy named uninstall.sh", said.contains("/spacebar-update-") && said.contains("/uninstall.sh"))
}
check("a missing uninstaller is named", Updates.runDetached(script: stub, arguments: [], log: logURL, environment: env, temporary: dir, job: .uninstall)
      == .failure(.init(message: "cannot copy the uninstaller")))

// The exit status reaches onExit, and a log past its limit is cut to its tail first.
let exiting = dir.appendingPathComponent("exit.sh")
try! "echo tail-marker; exit 3\n".write(to: exiting, atomically: true, encoding: .utf8)
var big = String(repeating: "old line\n", count: Updates.logLimit / 9 + 100)
big += "last old line\n"
try! big.write(to: logURL, atomically: true, encoding: .utf8)
let exited = DispatchSemaphore(value: 0)
var code = -1
_ = Updates.runDetached(script: exiting, arguments: [], log: logURL, environment: env, temporary: dir) { code = $0; exited.signal() }
check("exit status reported", exited.wait(timeout: .now() + 10) == .success && code == 3)
let trimmed = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
check("long log trimmed to its tail", trimmed.utf8.count <= Updates.logKeep + 200 && trimmed.hasPrefix("old line") && trimmed.contains("last old line\n")
      && trimmed.contains("tail-marker"))
try! "sleep 30\n".write(to: exiting, atomically: true, encoding: .utf8)
let killed = DispatchSemaphore(value: 0)
if case .success(let p) = Updates.runDetached(script: exiting, arguments: [], log: logURL, environment: env, temporary: dir, onExit: { code = $0; killed.signal() }) {
    usleep(200_000)
    kill(p, SIGTERM)
}
check("a killed installer reports 128 + the signal", killed.wait(timeout: .now() + 10) == .success && code == 128 + Int(SIGTERM))

// install.sh itself, in a dry run whose download fails at once: it records the run's end and removes its private copy, but
// only a copy the Update button made (a status path is set) directly in $TMPDIR.
func dryRun(tmp: String, status: URL?) -> (code: Int32, said: String, copyLeft: Bool) {
    let own = dir.appendingPathComponent("spacebar-update-test", isDirectory: true)
    try? FileManager.default.removeItem(at: own)
    try! FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
    let script = own.appendingPathComponent("install.sh")
    try! FileManager.default.copyItem(at: URL(fileURLWithPath: "scripts/install.sh"), to: script)
    try? FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
    let sh = Process()
    sh.executableURL = URL(fileURLWithPath: "/bin/sh")
    sh.arguments = [script.path, "--dry-run", "--no-prompt", "--version", "v9.9.9"]
    var env = ["HOME": dir.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": tmp, "SPACEBAR_RELEASE_URL": "file://\(dir.path)/no-such-release"]
    if let status { env["SPACEBAR_UPDATE_STATUS"] = status.path }
    sh.environment = env
    let out = Pipe()
    sh.standardOutput = out
    sh.standardError = out
    try! sh.run()
    let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    sh.waitUntilExit()
    return (sh.terminationStatus, said, FileManager.default.fileExists(atPath: own.path))
}
let recorded = dir.appendingPathComponent("recorded.json")
let run1 = dryRun(tmp: dir.path + "/", status: recorded)
let rec = Updates.readStatus(at: recorded)
check("install.sh: a failed download exits 1", run1.code == 1 && run1.said.contains("download failed"))
check("install.sh: records the version and exit status", rec?.version == "9.9.9" && rec?.exitStatus == 1 && (rec?.finishedAt ?? 0) > 1_700_000_000)
check("install.sh: removes its private copy", !run1.copyLeft)
check("install.sh: keeps a copy outside $TMPDIR", dryRun(tmp: dir.path + "/elsewhere/", status: recorded).copyLeft)
check("install.sh: keeps a copy when not started by the Update button", dryRun(tmp: dir.path + "/", status: nil).copyLeft)

// install.sh's quit_extensions on a fake bundle of stand-in processes: the writer goes first and is waited for (it takes 1 s
// to finish, like a write in flight), then the extension; a process of another app is left alone.
if let proc = ProcessInfo.processInfo.environment["SPACEBAR_TEST_PROC"] {
    let bundle = dir.appendingPathComponent("Apps/spacebar.app")
    let marker = dir.appendingPathComponent("quit-order.txt")
    let exes = [("writer", bundle.appendingPathComponent("Contents/PlugIns/P.appex/Contents/XPCServices/w.xpc/Contents/MacOS/W"), "1000"),
                ("extension", bundle.appendingPathComponent("Contents/PlugIns/P.appex/Contents/MacOS/P"), "0"),
                ("other", dir.appendingPathComponent("Other.app/Contents/PlugIns/P.appex/Contents/MacOS/P"), "0")]
    var procs: [String: Process] = [:]
    for (name, exe, delay) in exes {
        try! FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        try! FileManager.default.copyItem(atPath: proc, toPath: exe.path)
        let p = Process()
        p.executableURL = exe
        p.arguments = [marker.path, name, delay]
        try! p.run()
        procs[name] = p
    }
    usleep(300_000)
    let quit = Process()
    quit.executableURL = URL(fileURLWithPath: "/bin/sh")
    quit.arguments = ["-c", #"eval "$(sed -n '/^path_regex()/p; /^quit_extensions() {/,/^}/p' scripts/install.sh)"; quit_extensions "$1""#, "sh", bundle.path]
    let t0 = Date()
    try! quit.run()
    quit.waitUntilExit()
    let took = Date().timeIntervalSince(t0)
    usleep(300_000)
    let ended = ((try? String(contentsOf: marker, encoding: .utf8)) ?? "").split(separator: "\n").reduce(into: [String: Int64]()) {
        let f = $1.split(separator: " "); if f.count == 2 { $0[String(f[0])] = Int64(f[1]) }
    }
    check("install.sh: quits the writer before the extension", (ended["writer"] ?? .max) <= (ended["extension"] ?? .min) && took >= 0.9 && took < 7)
    check("install.sh: leaves another app's extension running", ended["other"] == nil && procs["other"]!.isRunning)
    procs.values.forEach { if $0.isRunning { $0.terminate() } }

    // quit_viewer: the Space helper's viewer, its writer first; the helper itself (launchd's to restart) and the extensions stay.
    let helpers = bundle.appendingPathComponent("Contents/Helpers")
    let vmarker = dir.appendingPathComponent("viewer-quit-order.txt")
    let vexes = [("vwriter", helpers.appendingPathComponent("spacebar Viewer.app/Contents/XPCServices/md.spacebar.viewer.writer.xpc/Contents/MacOS/SpacebarWriter"), "1000"),
                 ("viewer", helpers.appendingPathComponent("spacebar Viewer.app/Contents/MacOS/SpacebarViewer"), "0"),
                 ("helper", helpers.appendingPathComponent("spacebar Helper.app/Contents/MacOS/SpacebarHelper"), "0"),
                 ("extension", bundle.appendingPathComponent("Contents/PlugIns/P.appex/Contents/MacOS/P"), "0")]
    var vprocs: [String: Process] = [:]
    for (name, exe, delay) in vexes {
        try? FileManager.default.createDirectory(at: exe.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: exe.path) { try! FileManager.default.copyItem(atPath: proc, toPath: exe.path) }
        let p = Process()
        p.executableURL = exe
        p.arguments = [vmarker.path, name, delay]
        try! p.run()
        vprocs[name] = p
    }
    usleep(300_000)
    let vquit = Process()
    vquit.executableURL = URL(fileURLWithPath: "/bin/sh")
    vquit.arguments = ["-c", #"eval "$(sed -n '/^path_regex()/p; /^quit_viewer() {/,/^}/p' scripts/install.sh)"; quit_viewer "$1""#, "sh", bundle.path]
    let v0 = Date()
    try! vquit.run()
    vquit.waitUntilExit()
    let vtook = Date().timeIntervalSince(v0)
    usleep(300_000)
    let vended = ((try? String(contentsOf: vmarker, encoding: .utf8)) ?? "").split(separator: "\n").reduce(into: [String: Int64]()) {
        let f = $1.split(separator: " "); if f.count == 2 { $0[String(f[0])] = Int64(f[1]) }
    }
    check("install.sh: quits the viewer's writer before the viewer, waiting for it", (vended["vwriter"] ?? .max) <= (vended["viewer"] ?? .min) && vtook >= 0.9 && vtook < 7)
    check("install.sh: quit_viewer leaves the helper and the extensions running", vended["helper"] == nil && vended["extension"] == nil
          && vprocs["helper"]!.isRunning && vprocs["extension"]!.isRunning)
    vprocs.values.forEach { if $0.isRunning { $0.terminate() } }
}

// install.sh's dry run through to registration, from a made-up release: with the helper's agent loaded (a launchctl stub in
// PATH answers for it) it would register the helper again in the background, and never otherwise; with a copy installed it
// would quit the viewer after the swap. A dry run changes nothing, and runs no real launchctl.
do {
    let fm = FileManager.default
    let rel = dir.appendingPathComponent("release", isDirectory: true)
    let staged = dir.appendingPathComponent("staged/spacebar.app/Contents/PlugIns/SpacebarPreview.appex/Contents", isDirectory: true)
    try! fm.createDirectory(at: staged, withIntermediateDirectories: true)
    try! fm.createDirectory(at: rel, withIntermediateDirectories: true)
    func sh(_ cmd: String, env: [String: String] = [:]) -> (Int32, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", cmd]
        p.environment = env.isEmpty ? ProcessInfo.processInfo.environment : env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        try! p.run()
        let said = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, said)
    }
    _ = sh("cd '\(dir.path)/staged' && ditto -c -k --keepParent spacebar.app '\(rel.path)/spacebar.zip' && cd '\(rel.path)' && shasum -a 256 spacebar.zip > spacebar.zip.sha256")
    let stubs = dir.appendingPathComponent("stubs", isDirectory: true)
    try! fm.createDirectory(at: stubs, withIntermediateDirectories: true)
    let calls = dir.appendingPathComponent("launchctl-calls.txt")
    try! "#!/bin/sh\necho \"$*\" >> '\(calls.path)'\n[ \"$1\" = print ] && [ \"${STUB_AGENT:-0}\" = 1 ]\n".write(to: stubs.appendingPathComponent("launchctl"), atomically: true, encoding: .utf8)
    chmod(stubs.appendingPathComponent("launchctl").path, 0o755)
    let home = dir.appendingPathComponent("dryhome", isDirectory: true)
    func dry(agent: Bool) -> (Int32, String) {
        sh("sh scripts/install.sh --dry-run --no-prompt", env: ["HOME": home.path, "PATH": "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": dir.path + "/",
                                                        "SPACEBAR_RELEASE_URL": "file://\(rel.path)", "STUB_AGENT": agent ? "1" : "0",
                                                        "SPACEBAR_SYSTEM_APPLICATIONS": dir.appendingPathComponent("none").path])
    }
    let dest = home.appendingPathComponent("Applications/spacebar.app")
    let fresh = dry(agent: true)
    check("install.sh dry run: a made-up release reaches registration", fresh.0 == 0 && fresh.1.contains("Dry run: nothing was changed."))
    check("install.sh dry run: with the agent loaded, registers the helper again in the background",
          fresh.1.contains("would run in the background: \(dest.path)/Contents/MacOS/Spacebar --reregister >>\(home.path)/Library/Logs/spacebar-helper.log"))
    let uid = String(getuid())
    let asked = ((try? String(contentsOf: calls, encoding: .utf8)) ?? "").split(separator: "\n")
    check("install.sh dry run: asks launchctl only to print the agent", !asked.isEmpty && asked.allSatisfy { $0 == "print gui/\(uid)/md.spacebar.helper" })
    check("install.sh dry run: no agent, no reregister", !dry(agent: false).1.contains("--reregister"))
    check("install.sh dry run: no copy installed, no viewer to quit", !fresh.1.contains("Space helper's viewer"))
    try! fm.createDirectory(at: dest.appendingPathComponent("Contents/PlugIns"), withIntermediateDirectories: true)
    let over = dry(agent: true)
    check("install.sh dry run: over a copy, would quit its viewer after the swap, then register the helper again",
          over.1.range(of: "after the swap, would quit the Space helper's viewer running from \(dest.path), its writer first")
            .map { over.1[$0.upperBound...].contains("--reregister") } == true)
    check("install.sh dry run: --no-register touches neither", {
        let r = sh("sh scripts/install.sh --dry-run --no-prompt --no-register", env: ["HOME": home.path, "PATH": "\(stubs.path):/usr/bin:/bin:/usr/sbin:/sbin",
                                                                               "TMPDIR": dir.path + "/", "SPACEBAR_RELEASE_URL": "file://\(rel.path)", "STUB_AGENT": "1"])
        return r.0 == 0 && !r.1.contains("--reregister") && !r.1.contains("viewer")
    }())
    check("install.sh dry run: nothing written to the scratch home", !fm.fileExists(atPath: home.appendingPathComponent("Library").path)
          && fm.fileExists(atPath: dest.path) && ((try? fm.contentsOfDirectory(atPath: home.appendingPathComponent("Applications").path)) ?? []) == ["spacebar.app"])
}
close(leaked)

// Every private copy goes once its shell is reaped, and a run that never started leaves none.
let copies = { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("spacebar-update-") && $0 != "spacebar-update-test" } }
for _ in 0..<40 where !copies().isEmpty { usleep(50_000) }
check("runDetached leaves no private copy behind", copies().isEmpty)

try? FileManager.default.removeItem(at: dir)
print(failures == 0 ? "all passed" : "\(failures) failed")
exit(failures == 0 ? 0 : 1)
