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

        // `reviewOnly` is no longer a caller decision: whether lumac can remove
        // a path is decided by the Trash guard, inside `UninstallLeftover.make`.
        func add(_ path: String) {
            let std = (path as NSString).standardizingPath
            guard seen.insert(std).inserted, fm.fileExists(atPath: std) else { return }
            preview.leftovers.append(UninstallLeftover.make(
                path: std, bytes: Trash.directorySize(std), bundleId: bid))
        }

        // The app bundle itself.
        add(app.path)

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
        userExact.forEach { add($0) }

        // Locations to scan by child name rather than by an exact path.
        //
        // An exact `<dir>/<bid>` lookup misses every sibling that extends the
        // bundle id: fuse-t installs both `Containers/org.fuset.fskit-srv` and
        // `Containers/org.fuset.fskit-srv.module`, and only the first was found
        // while Containers was on the exact list. Preferences holds the same
        // shape (`<bid>.plist`, `<bid>.ShipIt.<uuid>.plist` under ByHost), so
        // every one of these is walked with the boundary matcher instead.
        let userPrefixed = [
            "\(home)/Library/Containers",
            "\(home)/Library/Group Containers",
            "\(home)/Library/Application Scripts",
            "\(home)/Library/Application Support",
            "\(home)/Library/Caches",
            "\(home)/Library/HTTPStorages",
            "\(home)/Library/WebKit",
            "\(home)/Library/Preferences",
            "\(home)/Library/Preferences/ByHost",
            "\(home)/Library/Saved Application State",
            "\(home)/Library/Logs",
        ]
        for base in userPrefixed {
            for child in children(of: base, matching: bid) { add(child) }
        }

        // CrashReporter files are named after the *app*, not the bundle id
        // ("Claude_<uuid>.plist"), so they need their own rule.
        let crashReporter = "\(home)/Library/Application Support/CrashReporter"
        for child in children(of: crashReporter, prefixedBy: name + "_") {
            add(child)
        }

        // Privileged /Library items: shown for transparency, but flagged as
        // needing authorization — lumac does not trash these itself yet.
        let sysExact = [
            "/Library/Application Support/\(name)",
            "/Library/LaunchDaemons/\(bid).plist",
            "/Library/LaunchAgents/\(bid).plist",
            "/Library/PrivilegedHelperTools/\(bid)",
        ]
        sysExact.forEach { add($0) }
        for base in ["/Library/LaunchDaemons", "/Library/LaunchAgents", "/Library/PrivilegedHelperTools"] {
            for child in children(of: base, matching: bid) { add(child) }
        }

        // Biggest first (the bundle usually leads).
        preview.leftovers.sort { $0.bytes > $1.bytes }
        return preview
    }

    /// Children of `dir` whose name carries `bundleId` as a whole reverse-DNS
    /// component run — `com.foo`, `group.com.foo`, `group.com.foo.shared`,
    /// `com.foo.helper`. A plain `contains` also matched `group.com.foobar.*`,
    /// which belongs to a different app and would have been trashed with it.
    private static func children(of dir: String, matching bundleId: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries
            .filter { name in
                name == bundleId
                    || name.hasPrefix(bundleId + ".")
                    || name.hasSuffix("." + bundleId)
                    || name.contains("." + bundleId + ".")
            }
            .map { dir + "/" + $0 }
    }

    /// Children whose name starts with `prefix` — for the few locations that key
    /// off the app's name instead of its bundle id.
    private static func children(of dir: String, prefixedBy prefix: String) -> [String] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        return entries.filter { $0.hasPrefix(prefix) }.map { dir + "/" + $0 }
    }
}
