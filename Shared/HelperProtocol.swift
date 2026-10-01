import Foundation
import Security
import CommonCrypto

/// The Space helper (`spacebar Helper.app`), the viewer it drives (`spacebar Viewer.app`) and the settings app talk over one
/// Mach service. The helper holds the event tap and never touches a file; the viewer shows files and never sees a key it was
/// not sent.
enum HelperIDs {
    static let helper = "md.spacebar.helper"
    static let viewer = "md.spacebar.viewer"
    static let app = "md.spacebar"
    static let machService = "md.spacebar.helper"
    static let agentPlist = "md.spacebar.helper.plist"
    static let helperApp = "spacebar Helper.app"
    static let viewerApp = "spacebar Viewer.app"
}

/// What the viewer and the settings app may call. The listener tells the two apart by signature; each call checks the role.
@objc(SpacebarHelperProtocol) protocol SpacebarHelperProtocol {
    /// Viewer: it is up and takes `show`, `key` and `close` on this connection.
    func hello(reply: @escaping (Bool) -> Void)
    /// Viewer: its panel opened (showing `requestID`) or closed.
    func panelState(_ open: Bool, requestID: Int, windowNumber: Int)
    /// Viewer: it will not show request `requestID`; Apple's Quick Look gets the Space instead.
    func declined(_ requestID: Int)
    /// Viewer: an edit, the filter or the find field in its writer's key panel took the keyboard (`active`) or let it go. While
    /// one holds it the helper passes every key. Replies whether the helper holds what was said: a session starts only while the
    /// panel is open or on its way.
    func textSession(_ active: Bool, reply: @escaping (Bool) -> Void)
    /// Settings app: `HelperStatus` as JSON.
    func status(reply: @escaping (Data) -> Void)
    /// Settings app: asks macOS to show the Accessibility prompt; replies whether the helper is trusted now.
    func promptAccessibility(reply: @escaping (Bool) -> Void)
}

/// What the helper calls on the viewer, over the connection the viewer opened.
@objc(SpacebarViewerProtocol) protocol SpacebarViewerProtocol {
    /// Show `paths` (Finder's selection). The reply only acknowledges; a decline comes back through `declined`.
    func show(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void)
    /// A key the helper took from Finder while the panel is open, by its name in `HelperKeys`.
    func key(_ name: String, isRepeat: Bool)
    func close()
    /// Another app came forward: the panel is ordered out, keeping what it shows for `restore`.
    func suspend()
    /// Finder came back: the suspended panel shows again as request `requestID`. Replies false when nothing is suspended.
    func restore(_ requestID: Int, reply: @escaping (Bool) -> Void)
}

struct HelperStatus: Codable, Equatable {
    var pid: Int32
    var version: String
    var enabled: Bool
    var trusted: Bool
    var tap: Bool
    var viewer: Bool
    /// The helper's executable as it was when the helper started (`HelperBinary.stamp`). A helper still running after the app
    /// was replaced in place answers too, from code no longer on disk; the settings app tells the two apart by this.
    var binary: String
}

enum HelperBinary {
    /// The file's inode and modification time; empty when it cannot be read.
    static func stamp(_ path: String) -> String {
        var st = stat()
        guard stat(path, &st) == 0 else { return "" }
        return "\(st.st_ino)-\(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec)"
    }
}

/// What the settings window and the welcome sheet say about the helper.
enum HelperState: Equatable {
    case off, notRunning, starting, needsLoginItems, needsAccessibility, secureInput, on

    /// SMAppService's status of the agent, without importing ServiceManagement here.
    enum Agent { case enabled, requiresApproval, notRegistered, notFound }

    static func of(enabled: Bool, agent: Agent, helper: HelperStatus?, secureInput: Bool) -> HelperState {
        guard enabled else { return .off }
        switch agent {
        case .requiresApproval: return .needsLoginItems
        case .notRegistered, .notFound: return .notRunning
        case .enabled: break
        }
        guard let h = helper else { return .starting }
        if !h.trusted { return .needsAccessibility }
        // The tap starts within the helper's next 2 s check after Accessibility is granted.
        if !h.tap { return .starting }
        return secureInput ? .secureInput : .on
    }
}

extension HelperState {
    /// Polls in a row without an answer before the settings app restarts the helper itself.
    static let missesBeforeReregister = 3

    /// Whether the settings app should run `--reregister` itself: the helper should run and is registered, but has not
    /// answered for `misses` polls in a row, as after the app was replaced in place and launchd refuses the new helper.
    static func shouldReregister(enabled: Bool, agent: Agent, answering: Bool, misses: Int) -> Bool {
        enabled && agent == .enabled && !answering && misses >= missesBeforeReregister
    }

    /// Whether the settings app registers the agent at launch: the setting is on but the agent is not registered, as after a
    /// reinstall that kept the settings. One waiting for approval in Login Items is left to the user.
    static func registersAtLaunch(enabled: Bool, agent: Agent) -> Bool { enabled && agent == .notRegistered }
}

/// Names of the keys the helper routes to the viewer while its panel is open.
enum HelperKeys {
    static let list: Set<String> = ["up", "down", "left", "right", "home", "end", "pageup", "pagedown", "return", "back"]
    static let commands: Set<String> = ["open", "find", "filter", "copy", "zoomIn", "zoomOut", "zoomReset"]
    static let all = list.union(commands)
}

struct HelperMods: OptionSet {
    let rawValue: Int
    static let command = HelperMods(rawValue: 1)
    static let shift = HelperMods(rawValue: 2)
    static let option = HelperMods(rawValue: 4)
    static let control = HelperMods(rawValue: 8)
}

/// Both ends of the helper's link require the other to be signed by their own leaf certificate, read at run time.
enum HelperSigning {
    /// The SHA-1 of the leaf certificate this process is signed with; nil for an ad-hoc or unsigned build.
    static func ownLeafSHA1() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let certs = (info as? [String: Any])?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first else { return nil }
        let data = SecCertificateCopyData(leaf) as Data
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    /// Entitlements that would let a library into a hardened process; no peer may carry them.
    static let injectable = ["com.apple.security.cs.allow-dyld-environment-variables", "com.apple.security.cs.disable-library-validation"]

    static func requirement(identifiers: [String], leaf: String) -> String {
        "(" + identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ") and certificate leaf = H\"\(leaf)\""
            + injectable.map { " and !entitlement[\"\($0)\"] exists" }.joined()
    }

    /// What the viewer and the settings app require of the helper; nil when this build is unsigned.
    static func helperRequirement() -> String? { ownLeafSHA1().map { requirement(identifiers: [HelperIDs.helper], leaf: $0) } }
}
