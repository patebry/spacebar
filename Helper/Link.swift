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

    /// Which of the two the peer is. The listener's requirement has already admitted it as one of them; this only picks the
    /// role, by the running code's identifier.
    static func role(of conn: NSXPCConnection) -> Role? {
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: conn.processIdentifier] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code, let leaf = HelperSigning.ownLeafSHA1() else { return nil }
        for (role, id) in [(Role.viewer, HelperIDs.viewer), (.app, HelperIDs.app)] {
            var req: SecRequirement?
            guard SecRequirementCreateWithString(HelperSigning.requirement(identifiers: [id], leaf: leaf) as CFString, [], &req) == errSecSuccess,
                  let req else { continue }
            if SecCodeCheckValidity(code, [], req) == errSecSuccess { return role }
        }
        return nil
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
        guard clientRequirement() != nil, let role = role(of: conn) else { return nil }
        conn.exportedInterface = NSXPCInterface(with: SpacebarHelperProtocol.self)
        conn.exportedObject = exported(role, conn)
        if role == .viewer { conn.remoteObjectInterface = NSXPCInterface(with: SpacebarViewerProtocol.self) }
        return role
    }
}
