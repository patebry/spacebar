import AppKit

/// Uninstall from the settings window: the app's own copy of scripts/uninstall.sh, started detached like the one-click update,
/// then the app quits (the script quits it anyway). The script removes only ~/Applications/spacebar.app and
/// /Applications/spacebar.app, their Quick Look registrations and the Space helper's agent and permissions, and with --purge
/// the settings folder and the helper's log.
enum Uninstall {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    /// The copies the script would remove.
    static var installed: [String] { Updates.installPlaces(home: home.path).filter { FileManager.default.fileExists(atPath: $0) } }
    static func shown(_ path: String) -> String { path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path }
    static var log: URL { home.appendingPathComponent("Library/Logs/spacebar-uninstall.log") }
    static var updateLog: URL { home.appendingPathComponent("Library/Logs/spacebar-update.log") }

    /// Whether this app is a copy the script removes; from anywhere else (a development build) it would remove another copy.
    static var isInstalledCopy: Bool {
        let app = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return Updates.installPlaces(home: home.path).contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == app }
    }

    static func arguments(purge: Bool) -> [String] { purge ? ["--purge"] : [] }

    /// Starts the script and quits, or says why it did not start.
    static func run(purge: Bool) -> String? {
        guard isInstalledCopy else { return "This copy of spacebar isn't in ~/Applications or /Applications, so there is nothing to uninstall from here." }
        // The script would leave it and say so in its log, after the app had quit.
        let app = Bundle.main.bundleURL.path
        guard Updates.canReplace(app) else { return "This account can't delete \(app). An administrator can move it to the Trash." }
        guard let script = Bundle.main.url(forResource: "uninstall", withExtension: "sh") else { return "The uninstaller is missing from this copy of spacebar." }
        // The installer would put back what the uninstaller removes, or find its app gone mid-swap.
        guard !Updates.isRunning(log: updateLog) else { return "An update is running. Try again once it has finished." }
        // SPACEBAR_UNINSTALL_SELF: the script removes the private copy it runs from; this app has quit by then.
        let env = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(), "SPACEBAR_UNINSTALL_SELF": "1"]
        switch Updates.runDetached(script: script, arguments: arguments(purge: purge), log: log, environment: env, job: .uninstall) {
        case .success:
            // The script boots the helper out too, but only this app can remove it from Login Items.
            HelperAgent.unregister()
            NSApp.terminate(nil)
            return nil
        case .failure(let e):
            return e.message
        }
    }
}
