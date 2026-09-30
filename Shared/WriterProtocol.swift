import Foundation

@objc(SpacebarWriterProtocol)
protocol SpacebarWriterProtocol {
    /// Writes only while the file still holds `base`; replies "conflict" when it changed on disk. A file other than Markdown takes
    /// only a text one of this connection's edits of it sent (beginTextEdit), in the file's own encoding.
    func write(_ data: Data, toPath path: String, expecting base: Data, reply: @escaping (String?) -> Void)
    func open(_ url: URL, reply: @escaping (Bool) -> Void)
    /// Opens a file (under the same LinkPolicy) in `appBundleID`, which is honoured only when it is the editor chosen in the
    /// settings; otherwise, or when that app is gone, in the file's default app.
    func open(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void)
    /// The viewer's Open button for the file on screen: `open`'s policy, except that an archive may be opened (links never
    /// can open one: Archive Utility would extract it beside itself).
    func openFileOnScreen(_ url: URL, reply: @escaping (Bool) -> Void)
    /// The viewer's Open button for a file shown as text (code, JSON, CSV, text), under LinkPolicy.textOpener: in `appBundleID`
    /// when it is the editor chosen in the settings and a text editor, else in the file's default app when `open` would use it,
    /// else in the default plain-text editor. A script opens as text in an editor, never in its default app.
    func openText(_ url: URL, appBundleID: String?, reply: @escaping (Bool) -> Void)
    /// The name of the app openText would use, and whether it opens the file as an editor; nil when nothing may open it.
    func textOpener(_ url: URL, appBundleID: String?, reply: @escaping (String?, Bool) -> Void)
    /// Shows an existing file in Finder, selected. Opens and runs nothing, so it is what an app, a script or an executable gets.
    func reveal(_ url: URL, reply: @escaping (Bool) -> Void)
    /// The display name of the app `open` would use for a file, or nil when LinkPolicy refuses the file or no app claims it.
    func defaultApp(_ url: URL, reply: @escaping (String?) -> Void)
    /// The contents of an archive LinkPolicy allows, as ArchiveListing's JSON, or nil when it cannot be listed.
    func listArchive(_ path: String, reply: @escaping (Data?) -> Void)
    /// One file of an archive listArchive allows, read without extracting it (ArchiveEntry): its bytes, at most
    /// ArchiveEntryView.cap(for: entry), or nil and why (ArchiveEntryView.notes' keys). Never written anywhere.
    func readArchiveEntry(_ path: String, entry: String, reply: @escaping (Data?, String?) -> Void)
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
    /// Whether the Space helper is on in the settings but not taking Space (not running, or without Accessibility), so Space
    /// falls back to Apple's Quick Look.
    func spaceHelperPaused(reply: @escaping (Bool) -> Void)
    /// Puts `text` on the clipboard as plain text: the file on screen, or the page's selection. The extension is never asked to
    /// touch the pasteboard; only the Space panel's ⌘C with nothing selected is written by the viewer itself (FinderCopy).
    func copyText(_ text: String, reply: @escaping (Bool) -> Void)
    /// Starts the installer bundled in the app, detached, to update to `version`: only a release newer than this one, and only
    /// while the update check is on. Replies nil once it is running, or why it is not. It logs to ~/Library/Logs/spacebar-update.log.
    func installUpdate(_ version: String, reply: @escaping (String?) -> Void)
    /// Starts AppKit and builds the edit panel hidden (not key, not visible) so the first edit does not pay for either.
    func prepare()
    /// Shows the key-capturing panel over the clicked block. clickX/clickY locate the click inside the block, so the panel is
    /// placed from the current mouse location. Replies as soon as the panel is ordered front; if it then fails to become
    /// key the host gets editEnded(session, "not-key").
    func beginEdit(_ session: Int, text: String, caret: Int, clickX: Double, clickY: Double, blockWidth: Double, blockHeight: Double, reply: @escaping (Bool) -> Void)
    /// The same panel over the whole text file at `path` (code, JSON, CSV, text): Enter and Backspace edit the text as they are
    /// (no split or merge), Enter keeps the line's indentation, Tab types a tab, and lines do not wrap, so ↑ and ↓ keep the
    /// column. `text` must be the file as the writer reads it, or a text this connection's edits of it sent; only what is then
    /// typed may be written to it (write).
    func beginTextEdit(_ session: Int, path: String, text: String, caret: Int, clickX: Double, clickY: Double, width: Double, height: Double,
                       reply: @escaping (Bool) -> Void)
    func setSelection(_ session: Int, start: Int, length: Int)
    /// Answers editMergeBackward and editSplit: replaces the buffer (nil keeps it), puts the caret at `caret` (negative keeps
    /// the selection) and releases the keys held since the request.
    func resetEdit(_ session: Int, text: String?, caret: Int)
    func endEdit(_ session: Int)
    /// Holds the keyboard for the sidebar's filter field in the same invisible panel an edit uses, placed over the field. Text
    /// comes back through filterChanged and the list keys through filterKey; nothing is ever written. Beginning a filter ends
    /// an edit, and beginning an edit ends a filter.
    func beginFilter(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void)
    /// The same session with no text, after a click on a row of the sidebar: the list keys (FilterKeys.listNames, ← and → too)
    /// come back through filterKey and nothing is typed. Esc or Space ends it (FilterKeys.listEnds), and so does whatever ends a
    /// filter. Ended by endFilter.
    func beginListKeys(_ session: Int, clickX: Double, clickY: Double, rowWidth: Double, rowHeight: Double, reply: @escaping (Bool) -> Void)
    /// The same session over the find field: text through filterChanged, and ↵ and ⇧↵ (⌘G and ⇧⌘G too) as FilterKeys.findNames
    /// through filterKey. Esc ends it whatever the field holds. Ended by endFilter.
    func beginFind(_ session: Int, text: String, clickX: Double, clickY: Double, fieldWidth: Double, fieldHeight: Double, reply: @escaping (Bool) -> Void)
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
    /// A key the sidebar moves with, one of FilterKeys.names (a list session: listNames and listCommands; the find field:
    /// findNames); `isRepeat` for a held key's auto-repeat.
    func filterKey(_ session: Int, key: String, isRepeat: Bool)
    /// Sent for every filter session end; nothing more arrives for `session`.
    func filterEnded(_ session: Int, reason: String)
}

/// The sidebar filter's keys and text, shared by the writer that captures them and the extension that checks them. A list session
/// (a click on a row) has no field: ← and → move through the tree too, and Esc or Space hand the keyboard back.
enum FilterKeys {
    static let names: Set<String> = ["up", "down", "home", "end", "return"]
    static let listNames: Set<String> = names.union(["left", "right"])
    /// ⌘F, ⌥⌘F and ⌘C while a list session holds the keys: the page finds in the file, filters the sidebar or copies.
    static let listCommands: Set<String> = ["find", "filter", "copy"]
    /// The find field's keys: the next and the previous match.
    static let findNames: Set<String> = ["next", "prev"]
    static let maxLength = 256
    private static let byCode: [UInt16: String] = [126: "up", 125: "down", 115: "home", 119: "end", 36: "return", 76: "return"]
    private static let listByCode: [UInt16: String] = [123: "left", 124: "right"]
    /// NSEvent.ModifierFlags shift, control, option and command: with any of them the key edits the field's text instead.
    private static let editing: UInt = 1 << 17 | 1 << 18 | 1 << 19 | 1 << 20
    private static let shiftFlag: UInt = 1 << 17, optionFlag: UInt = 1 << 19, commandFlag: UInt = 1 << 20

    /// The sidebar key for a key pressed in the field (or, `list`, over the list), or nil when the field keeps it.
    static func name(keyCode: UInt16, modifiers: UInt, list: Bool = false) -> String? {
        guard modifiers & editing == 0 else { return nil }
        return byCode[keyCode] ?? (list ? listByCode[keyCode] : nil)
    }

    /// The find field's key for a key pressed in it: Return is the next match and Shift+Return the previous one; nil when the
    /// field keeps it.
    static func findName(keyCode: UInt16, modifiers: UInt) -> String? {
        guard keyCode == 36 || keyCode == 76, modifiers & (editing & ~shiftFlag) == 0 else { return nil }
        return modifiers & shiftFlag == 0 ? "next" : "prev"
    }

    /// A Command shortcut by its character without modifiers: in a list session one of listCommands, in the find field ⌘G and
    /// ⇧⌘G; nil for any other.
    static func command(_ chars: String, modifiers: UInt, find: Bool) -> String? {
        let mods = modifiers & editing
        if find { return chars == "g" && mods & ~shiftFlag == commandFlag ? (mods & shiftFlag == 0 ? "next" : "prev") : nil }
        switch (chars, mods) {
        case ("f", commandFlag): return "find"
        case ("f", commandFlag | optionFlag): return "filter"
        case ("c", commandFlag): return "copy"
        default: return nil
        }
    }

    /// Whether a key ends a list session: Esc, and Space, which Quick Look closes the preview on. The extension cannot close
    /// Quick Look, so Space only hands the keyboard back; the next Space closes the preview.
    static func listEnds(keyCode: UInt16, modifiers: UInt) -> Bool {
        keyCode == 53 || (keyCode == 49 && modifiers & editing == 0)
    }

    /// Whether the sidebar takes the keys again after a session ends: only after Esc leaves an edit or the filter field. Esc or
    /// Space in a list session hands them to Quick Look; any other end (a click elsewhere, another app, the preview closing)
    /// means the keyboard went somewhere else.
    static func relists(afterEnding reason: String, list: Bool) -> Bool { reason == "escape" && !list }

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
