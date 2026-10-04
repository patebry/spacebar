import AppKit
import IOKit

/// Which app has secure keyboard entry on (a password field, Terminal's Secure Keyboard Entry), read from the window server's
/// console-user record in the I/O Registry. While one does, no event tap sees keys, so the Space helper is paused.
enum SecureInput {
    /// The process holding secure input for the console session; nil when none does or it cannot be read.
    static func ownerPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != 0 else { return nil }
        defer { IOObjectRelease(root) }
        guard let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]] else { return nil }
        let me = getuid()
        for u in users {
            if let uid = u["kCGSSessionUserIDKey"] as? Int, uid != Int(me) { continue }
            if let pid = u["kCGSSessionSecureInputPID"] as? Int, pid > 0 { return pid_t(pid) }
        }
        return nil
    }

    /// The name of the app holding secure input, as the user knows it (its app name, else its process name).
    static func ownerName() -> String? {
        guard let pid = ownerPID() else { return nil }
        if let name = NSRunningApplication(processIdentifier: pid)?.localizedName, !name.isEmpty { return name }
        var buf = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let name = String(cString: buf)
        return name.isEmpty ? nil : name
    }
}
