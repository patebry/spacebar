import AppKit

/// Uninstall from the settings window: the app's own copy of scripts/uninstall.sh, started detached like the one-click update,
/// then the app quits (the script quits it anyway). The script removes only ~/Applications/spacebar.app, its Quick Look
/// registrations and the Space helper's agent and permissions, and with --purge the settings folder and the viewer's container.
enum Uninstall {
    static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }
    static var installed: URL { home.appendingPathComponent("Applications/spacebar.app") }
    static var log: URL { home.appendingPathComponent("Library/Logs/spacebar-uninstall.log") }
    static var updateLog: URL { home.appendingPathComponent("Library/Logs/spacebar-update.log") }

    /// Whether this app is the copy the script removes; from anywhere else (a development build) it would remove another copy.
    static var isInstalledCopy: Bool {
        Bundle.main.bundleURL.resolvingSymlinksInPath().path == installed.resolvingSymlinksInPath().path
    }

    static func arguments(purge: Bool) -> [String] { purge ? ["--purge"] : [] }

    /// Starts the script and quits, or says why it did not start.
    static func run(purge: Bool) -> String? {
        guard isInstalledCopy else { return "This copy of spacebar isn't the one in ~/Applications, so there is nothing to uninstall from here." }
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
