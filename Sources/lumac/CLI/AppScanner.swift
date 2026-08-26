import Foundation
import CoreServices

/// Native replacement for `mo uninstall --list` / `--dry-run`.
///
/// The CLI is avoided here on purpose: `--list` stops after ~18 of 58 apps and
/// emits a truncated array, and each `--dry-run` preview takes ~45s. Reading the
/// bundles and the standard Library locations directly is complete and instant,
/// and gives the last-used date the sort needs.
enum AppScanner {

    /// Folders that hold user-facing apps. `/System/Applications` is excluded —
    /// those are macOS built-ins and are not uninstallable.
    private static var appDirs: [String] {
        ["/Applications",
         "/Applications/Utilities",
         NSHomeDirectory() + "/Applications"]
    }

    static func installedApps() -> [InstalledApp] {
        let fm = FileManager.default
        var apps: [InstalledApp] = []
        var seen = Set<String>()

        for dir in appDirs {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let path = dir + "/" + entry
                guard seen.insert(path).inserted,
                      let bundleId = Bundle(path: path)?.bundleIdentifier else { continue }

                let name = fm.displayName(atPath: path)
                    .replacingOccurrences(of: ".app", with: "")
                apps.append(InstalledApp(
                    name: name,
                    bundleId: bundleId,
                    path: path,
                    bytes: Trash.directorySize(path),
                    lastUsed: lastUsed(path)))
            }
        }
        return apps
    }

    /// Spotlight's last-used date, when the item is indexed.
    private static func lastUsed(_ path: String) -> Date? {
        guard let item = MDItemCreate(nil, path as CFString) else { return nil }
        return MDItemCopyAttribute(item, kMDItemLastUsedDate) as? Date
    }

    /// Everything removing this app would delete: the bundle plus its caches,
    /// preferences, containers and support files, keyed off the bundle id.
    static func leftovers(for app: InstalledApp) -> UninstallPreview {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        let bid = app.bundleId
        let name = app.name

        var preview = UninstallPreview()
        var seen = Set<String>()

        func add(_ path: String, reviewOnly: Bool) {
            let std = (path as NSString).standardizingPath
            guard seen.insert(std).inserted, fm.fileExists(atPath: std) else { return }
            preview.leftovers.append(UninstallLeftover(
                path: std,
                bytes: Trash.directorySize(std),
                reviewOnly: reviewOnly))
        }

        // The app bundle itself.
        add(app.path, reviewOnly: false)

        // User-space locations addressed exactly by bundle id or app name.
        let userExact = [
            "\(home)/Library/Application Support/\(bid)",
            "\(home)/Library/Application Support/\(name)",
            "\(home)/Library/Caches/\(bid)",
            "\(home)/Library/Preferences/\(bid).plist",
            "\(home)/Library/HTTPStorages/\(bid)",
            "\(home)/Library/HTTPStorages/\(bid).binarycookies",
            "\(home)/Library/WebKit/\(bid)",
            "\(home)/Library/Containers/\(bid)",
            "\(home)/Library/Saved Application State/\(bid).savedState",
            "\(home)/Library/Cookies/\(bid).binarycookies",
            "\(home)/Library/Logs/\(bid)",
            "\(home)/Library/Logs/\(name)",
        ]
        userExact.forEach { add($0, reviewOnly: false) }

        // Locations that embed the bundle id in their child names.
        let userPrefixed = [
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Scripts",
        ]
        for base in userPrefixed {
            for child in children(of: base, containing: bid) { add(child, reviewOnly: false) }
        }

        // Privileged /Library items: shown for transparency, but flagged as
        // needing authorization — lumac does not trash these itself yet.
        let sysExact = [
            "/Library/Application Support/\(name)",
            "/Library/LaunchDaemons/\(bid).plist",
            "/Library/LaunchAgents/\(bid).plist",
            "/Library/PrivilegedHelperTools/\(bid)",
        ]
        sysExact.forEach { add($0, reviewOnly: true) }
        for base in ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools"] {
            for child in children(of: base, containing: bid) { add(child, reviewOnly: true) }
        }

        // Biggest first (the bundle usually leads).
        preview.leftovers.sort { $0.bytes > $1.bytes }
        return preview
    }

    private static func children(of dir: String, containing needle: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { $0.contains(needle) }.map { dir + "/" + $0 }
    }
}
