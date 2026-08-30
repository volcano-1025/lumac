import Foundation

/// An uninstaller the application shipped with itself.
///
/// Worth surfacing because it is the most authoritative answer available, and
/// it disagrees with every generic scan in both directions. fuse-t's
/// `/Library/Application Support/fuse-t/uninstall.sh` removes
/// `/usr/local/bin/go-nfsv4`, `/usr/local/include/fuse`, `/usr/local/lib/libfuse-t*`
/// and `/usr/local/lib/pkgconfig/fuse-t.pc` — none of which any bundle-id sweep
/// finds — while deliberately leaving `/Library/Frameworks/fuse_t.framework`
/// alone, because other software links against it.
///
/// lumac does not run these. They are arbitrary vendor code and the ones that
/// matter demand root, which lumac has no way to grant. The user is shown that
/// it exists and handed the command.
struct VendorUninstaller: Hashable {
    var path: String
    /// True when the script checks for root and refuses without it.
    var needsRoot: Bool

    /// The command to run it, for the copy button.
    var command: String {
        let quoted = "\"\(path)\""
        if path.hasSuffix(".app") { return "open \(quoted)" }
        return needsRoot ? "sudo bash \(quoted)" : "bash \(quoted)"
    }

    var displayName: String { (path as NSString).lastPathComponent }
}

enum VendorUninstallerScanner {

    /// Names that mean "this removes the app", in the forms vendors ship them.
    private static func looksLikeUninstaller(_ name: String) -> Bool {
        let lower = name.lowercased()
        guard lower.contains("uninstall") else { return false }
        // Guard against data files that merely mention it (uninstall.log,
        // uninstall_manifest.json) — only runnable things qualify.
        let runnable = ["", ".sh", ".command", ".tool", ".app", ".pkg"]
        let ext = "." + (name as NSString).pathExtension
        return runnable.contains((name as NSString).pathExtension.isEmpty ? "" : ext)
    }

    /// Looks one level inside the places a pkg-installed app keeps its payload.
    /// Deliberately shallow: a deep walk would turn up bundled uninstallers
    /// belonging to some vendored dependency rather than to this app.
    static func find(for app: InstalledApp) -> VendorUninstaller? {
        let home = NSHomeDirectory()
        let roots = [
            "/Library/Application Support/\(app.name)",
            "\(home)/Library/Application Support/\(app.name)",
            "/usr/local/share/\(app.name)",
            app.path + "/Contents/Resources",
        ]

        let fm = FileManager.default
        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(atPath: root) else { continue }
            for entry in entries where looksLikeUninstaller(entry) {
                let full = root + "/" + entry
                if entry.hasSuffix(".app") || fm.isExecutableFile(atPath: full) {
                    return VendorUninstaller(path: full, needsRoot: requiresRoot(full))
                }
            }
        }
        return nil
    }

    /// Reads the head of the script for the usual root guard. Only the first few
    /// KB — these scripts check up front or not at all.
    private static func requiresRoot(_ path: String) -> Bool {
        guard !path.hasSuffix(".app"),
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("EUID")
            || text.contains("id -u")
            || text.localizedCaseInsensitiveContains("run as root")
    }
}
