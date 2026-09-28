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
    /// Viewer: its panel opened or closed.
    func panelState(_ open: Bool, windowNumber: Int)
    /// Viewer: it will not show request `requestID`; Apple's Quick Look gets the Space instead.
    func declined(_ requestID: Int)
    /// Settings app: `HelperStatus` as JSON.
    func status(reply: @escaping (Data) -> Void)
    /// Settings app: asks macOS to show the Accessibility prompt; replies whether the helper is trusted now.
    func promptAccessibility(reply: @escaping (Bool) -> Void)
}

/// What the helper calls on the viewer, over the connection the viewer opened.
@objc(SpacebarViewerProtocol) protocol SpacebarViewerProtocol {
    /// Show `paths` (Finder's selection). The reply only acknowledges; a decline comes back through `declined`.
    func show(_ paths: [String], requestID: Int, reply: @escaping (Bool) -> Void)
    /// A key the helper took from Finder while the panel is open (`HelperKeys`), with `HelperMods` bits.
    func key(_ name: String, isRepeat: Bool, mods: Int)
    func close()
}

struct HelperStatus: Codable, Equatable {
    var pid: Int32
    var version: String
    var enabled: Bool
    var trusted: Bool
    var tap: Bool
    var viewer: Bool
}

/// Names of the keys the helper routes to the viewer while its panel is open.
enum HelperKeys {
    static let list: Set<String> = ["up", "down", "left", "right", "home", "end", "pageup", "pagedown", "return"]
    static let commands: Set<String> = ["open", "find", "zoomIn", "zoomOut", "zoomReset"]
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

    static func requirement(identifiers: [String], leaf: String) -> String {
        "(" + identifiers.map { "identifier \"\($0)\"" }.joined(separator: " or ") + ") and certificate leaf = H\"\(leaf)\""
    }

    /// What the viewer and the settings app require of the helper; nil when this build is unsigned.
    static func helperRequirement() -> String? { ownLeafSHA1().map { requirement(identifiers: [HelperIDs.helper], leaf: $0) } }
}
