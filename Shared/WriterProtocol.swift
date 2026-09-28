import Foundation

@objc(SpacebarWriterProtocol)
protocol SpacebarWriterProtocol {
    /// Writes only while the file still holds `base`; replies "conflict" when it changed on disk.
    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void)
    func open(_ url: URL, reply: @escaping (Bool) -> Void)
    /// Opens a file (under the same LinkPolicy) in `appBundleID`, which is honoured only when it is the editor chosen in the
    /// settings; otherwise, or when that app is gone, in the file's default app.
    func open(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void)
    /// The viewer's Open button for the file on screen: `open`'s policy, except that an archive may be opened (links never
    /// can open one: Archive Utility would extract it beside itself).
    func openFileOnScreen(_ url: URL, reply: @escaping (Bool) -> Void)
    /// Shows an existing file in Finder, selected. Opens and runs nothing, so it is what an app, a script or an executable gets.
    func reveal(_ url: URL, reply: @escaping (Bool) -> Void)
    /// The display name of the app `open` would use for a file, or nil when LinkPolicy refuses the file or no app claims it.
    func defaultApp(_ url: URL, reply: @escaping (String?) -> Void)
    /// The contents of an archive LinkPolicy allows, as ArchiveListing's JSON, or nil when it cannot be listed.
    func listArchive(_ path: String, reply: @escaping (Data?) -> Void)
    /// Creates the support folder, themes/ and a default settings.json if missing.
    func ensureSupportDir(reply: @escaping (Bool) -> Void)
    /// Merges a JSON object of settings into settings.json atomically. Only Settings.panelKeys are taken, each sanitized.
    func updateSettings(_ patch: Data, reply: @escaping (Bool) -> Void)
    /// Opens the host app's settings window on `tab` (one of SettingsTab.all).
    func openSettings(_ tab: String, reply: @escaping (Bool) -> Void)
    /// What to offer for the newest release (an Updates.Offer as JSON), or nil when the update check is off: the version is
    /// cached and asked of GitHub at most once a day.
    func updateOffer(reply: @escaping (Data?) -> Void)
    /// Puts the install command, which also updates, on the clipboard.
    func copyInstallCommand(reply: @escaping (Bool) -> Void)
    /// Starts the installer bundled in the app, detached, to update to `version`: only a release newer than this one, and only
    /// while the update check is on. Replies nil once it is running, or why it is not. It logs to ~/Library/Logs/spacebar-update.log.
    func installUpdate(_ version: String, reply: @escaping (String?) -> Void)
    /// Starts AppKit and builds the edit panel hidden (not key, not visible) so the first edit does not pay for either.
    func prepare()
    /// Shows the key-capturing panel over the clicked block. clickX/clickY locate the click inside the block, so the panel is
    /// placed from the current mouse location. Replies as soon as the panel is ordered front; if it then fails to become
    /// key the host gets editEnded(session, "not-key").
    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void)
    func setSelection(_ session: Int, start: Int, length: Int)
    /// Answers editMergeBackward and editSplit: replaces the buffer (nil keeps it), puts the caret at `caret` (negative keeps
    /// the selection) and releases the keys held since the request.
    func resetEdit(_ session: Int, text: String?, caret: Int)
    func endEdit(_ session: Int)
    /// Holds the keyboard for the sidebar's filter field in the same invisible panel an edit uses, placed over the field. Text
    /// comes back through filterChanged and the list keys through filterKey; nothing is ever written. Beginning a filter ends
    /// an edit, and beginning an edit ends a filter.
    func beginFilter(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void)
    func endFilter(_ session: Int)
}

/// Exported by the preview extension so the writer can stream the edit buffer back.
@objc(SpacebarEditHostProtocol)
protocol SpacebarEditHostProtocol {
    func editChanged(_ session: Int, text: String, selectionStart: Int, selectionLength: Int, keyTime: Double)
    /// Sent for every session end, after the session's last editChanged; nothing more arrives for `session`.
    func editEnded(_ session: Int, reason: String)
    /// Backspace at the start of the block: the host joins it to the previous block and answers with resetEdit.
    func editMergeBackward(_ session: Int)
    /// Enter that ends the block: it keeps `before`, `after` becomes a new block the edit moves into, and `tail` (may be
    /// empty) follows as a block of its own. The host answers with resetEdit.
    func editSplit(_ session: Int, before: String, after: String, tail: String)
    /// The filter field's text (FilterKeys.clean) after each change.
    func filterChanged(_ session: Int, text: String)
    /// A key the sidebar moves with, one of FilterKeys.names; `isRepeat` for a held key's auto-repeat.
    func filterKey(_ session: Int, key: String, isRepeat: Bool)
    /// Sent for every filter session end; nothing more arrives for `session`.
    func filterEnded(_ session: Int, reason: String)
}

/// The sidebar filter's keys and text, shared by the writer that captures them and the extension that checks them.
enum FilterKeys {
    static let names: Set<String> = ["up", "down", "home", "end", "return"]
    static let maxLength = 256
    private static let byCode: [UInt16: String] = [126: "up", 125: "down", 115: "home", 119: "end", 36: "return", 76: "return"]
    /// NSEvent.ModifierFlags shift, control, option and command: with any of them the key edits the field's text instead.
    private static let editing: UInt = 1 << 17 | 1 << 18 | 1 << 19 | 1 << 20

    /// The sidebar key for a key pressed in the field, or nil when the field keeps it.
    static func name(keyCode: UInt16, modifiers: UInt) -> String? {
        modifiers & editing == 0 ? byCode[keyCode] : nil
    }

    /// One line of at most maxLength Unicode scalars, without control characters.
    static func clean(_ s: String) -> String {
        String(String.UnicodeScalarView(s.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }.prefix(maxLength)))
    }

    /// Esc clears a field with text in it and ends the session on an empty one, like the page's own field.
    static func escapeEnds(text: String) -> Bool { text.isEmpty }
}

/// The writer is embedded in each preview extension under the extension's own bundle ID plus ".writer".
var writerServiceName: String { (Bundle.main.bundleIdentifier ?? "") + ".writer" }

let logSubsystem = "md.spacebar"

/// Milliseconds on the boot clock shared by every process (NSEvent timestamps use it too); latency logs are stamped with it.
func upMs() -> Double { ProcessInfo.processInfo.systemUptime * 1000 }
/// Converts a wall-clock epoch time in ms (JS `performance.timeOrigin + timeStamp`) to `upMs()`.
func upMs(epochMs: Double) -> Double { upMs() - (Date().timeIntervalSince1970 * 1000 - epochMs) }

enum SettingsTab {
    static let all: Set<String> = ["general", "appearance", "folders", "editing", "advanced"]
    static func url(_ tab: String) -> URL? { all.contains(tab) ? URL(string: "spacebar-md://settings/\(tab)") : nil }
}
