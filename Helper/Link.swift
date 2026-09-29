import Foundation
import Security

/// Who may talk to the helper: the viewer and the settings app, signed by the same certificate as the helper itself. Built at
/// run time from the helper's own signature, so a build signed with any identity trusts only its own siblings.
enum Link {
    enum Role { case viewer, app }

    /// The listener's requirement: the viewer or the settings app, same leaf certificate. Nil (refuse everyone) when unsigned.
    static func clientRequirement(leaf: String? = HelperSigning.ownLeafSHA1()) -> String? {
        leaf.map { HelperSigning.requirement(identifiers: [HelperIDs.viewer, HelperIDs.app], leaf: $0) }
    }

    /// Which of the two the peer is. The listener's requirement has already admitted it as one of them; this picks the role by
    /// the running code's identifier, and refuses a peer without the hardened runtime, into which a library could be injected.
    static func role(of conn: NSXPCConnection) -> Role? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: conn.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code, let leaf = HelperSigning.ownLeafSHA1(),
              hardened(code) else { return nil }
        for (role, id) in [(Role.viewer, HelperIDs.viewer), (.app, HelperIDs.app)] {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(HelperSigning.requirement(identifiers: [id], leaf: leaf) as CFString, [], &req) == errSecSuccess,
                  let req else { continue }
            if SecCodeCheckValidity(code, [], req) == errSecSuccess { return role }
        }
        return nil
    }

    static func hardened(_ code: SecCode) -> Bool {
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let flags = (info as? [String: Any])?[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
    }

    /// Gates `listener`; false when this build is unsigned, and then every connection is refused in `accept`.
    @discardableResult
    static func gate(_ listener: NSXPCListener) -> Bool {
        guard let req = clientRequirement() else { return false }
        listener.setConnectionCodeSigningRequirement(req)
        return true
    }

    /// Sets up a connection the gated listener let through, exporting what `exported` makes for its role.
    static func accept(_ conn: NSXPCConnection, exported: (Role, NSXPCConnection) -> SpacebarHelperProtocol) -> Role? {
        guard let leaf = HelperSigning.ownLeafSHA1(), let role = role(of: conn) else { return nil }
        // The role was found by pid; from here every message is checked against that one identity by the kernel's audit token.
        conn.setCodeSigningRequirement(HelperSigning.requirement(identifiers: [role == .viewer ? HelperIDs.viewer : HelperIDs.app], leaf: leaf))
        conn.exportedInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
        conn.exportedObject = exported(role, conn)
        if role == .viewer { conn.remoteObjectInterface = NSXPCInterface(with: SpacebarViewerProtocol.self) }
        return role
    }
}
