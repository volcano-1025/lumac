import Foundation
import AppKit
import LocalAuthentication

/// Whether lumac has Full Disk Access. Without it, `mo clean` / `mo analyze`
/// silently miss TCC-protected areas (Mail, Safari, other apps' containers), so
/// the app surfaces the state and points the user at the right settings pane.
enum FullDiskAccess {
    /// The system TCC database exists on every Mac and can only be opened with
    /// Full Disk Access. Actually opening it is the reliable test — `access(2)`,
    /// `isReadableFile`, and directory listings do not reflect TCC denial, and
    /// the per-user `com.apple.TCC` folder is not present on every machine.
    static var granted: Bool {
        let tccDB = "/Library/Application Support/com.apple.TCC/TCC.db"
        if let handle = FileHandle(forReadingAtPath: tccDB) {
            try? handle.close()
            return true
        }
        // Fallback probe, for the rare Mac without a readable system TCC.db.
        let safari = NSHomeDirectory() + "/Library/Safari"
        return (try? FileManager.default.contentsOfDirectory(atPath: safari)) != nil
    }

    /// Opens System Settings ▸ Privacy & Security ▸ Full Disk Access.
    static func openSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}

/// Touch ID (or the login password as fallback) as a confirmation gate before
/// destructive actions. This does not grant elevated rights — it only asks the
/// device owner to prove presence, matching the handoff's Settings "Touch ID".
enum Biometric {
    /// Whether the device can evaluate owner authentication at all.
    static var available: Bool {
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    /// Prompts for Touch ID / password. Returns true on success, false on cancel
    /// or failure. When the device cannot authenticate at all, returns true so
    /// the action is not blocked on hardware that has no biometrics or password.
    static func confirm(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return true
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}
