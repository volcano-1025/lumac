import Foundation
import AppKit

/// Moves selected paths to the Trash.
///
/// The app performs the deletion itself rather than handing the selection back
/// to the CLI: `mo` has no "clean only these" flag — only a whitelist of things
/// to protect — so per-row selection can only be honoured here. Everything goes
/// through `trashItem`, which keeps the design's promise that anything removed
/// can be put back from the Trash.
enum Trash {

    struct Outcome {
        var freedBytes: Int64 = 0
        var trashed: [String] = []
        var failed: [(path: String, reason: String)] = []
    }

    /// Paths that must never be trashed, whatever the scan reported.
    private static let forbiddenRoots: Set<String> = [
        "/", "/System", "/Library", "/bin", "/sbin", "/usr", "/etc", "/var",
        "/private", "/Applications", "/Users", "/Volumes", "/opt", "/cores", "/dev",
    ]

    /// Home directories whose *contents* may be cleaned but which must survive.
    private static var protectedDirectories: Set<String> {
        let home = NSHomeDirectory()
        return [
            home,
            home + "/Library",
            home + "/Documents", home + "/Desktop", home + "/Downloads",
            home + "/Pictures", home + "/Music", home + "/Movies",
            home + "/Library/Caches", home + "/Library/Application Support",
            home + "/Library/Preferences", home + "/Library/Containers",
            home + "/Library/Logs", home + "/Library/Mobile Documents",
        ]
    }

    /// Guards every path before it reaches `trashItem`. Applied when the path
    /// dump is read as well as immediately before deletion, so a file that
    /// changed underneath us between scan and execute is still caught.
    static func isDeletable(_ path: String) -> Bool {
        let clean = (path as NSString).standardizingPath
        guard clean.hasPrefix("/"), !clean.contains(".."), clean.count > 1 else { return false }
        guard !forbiddenRoots.contains(clean) else { return false }
        guard !protectedDirectories.contains(clean) else { return false }

        // Require at least three components, so "/Library" or "/Users/name"
        // can never slip through as a target. A top-level application bundle is
        // the one exception: uninstalling means trashing "/Applications/Foo.app",
        // which has only two — but "/Applications" itself is still blocked above
        // by `forbiddenRoots`, and nested paths must clear the usual bar.
        let components = clean.split(separator: "/")
        let isAppBundle = clean.hasPrefix("/Applications/")
            && clean.hasSuffix(".app")
            && components.count == 2
        guard components.count >= 3 || isAppBundle else { return false }

        // Only ever touch the user's own space and the system's scratch areas.
        let home = NSHomeDirectory()
        let allowedPrefixes = [
            home + "/",
            "/private/var/folders/", "/private/var/log/", "/private/tmp/",
            "/Library/Caches/", "/Library/Logs/", "/var/folders/", "/tmp/",
            "/Applications/",
        ]
        return allowedPrefixes.contains { clean.hasPrefix($0) }
    }

    /// Trashes each path in turn, reporting progress as a 0...1 fraction along
    /// with the path currently being handled.
    ///
    /// Failures are collected rather than thrown: a locked or already-gone file
    /// should not abort the rest of the run.
    static func run(
        paths: [String],
        progress: @MainActor @escaping (Double, String) -> Void
    ) async -> Outcome {
        var outcome = Outcome()
        guard !paths.isEmpty else { return outcome }

        let fileManager = FileManager.default

        for (index, path) in paths.enumerated() {
            if Task.isCancelled { break }

            let fraction = Double(index) / Double(paths.count)
            let display = abbreviate(path)
            await progress(fraction, display)

            guard isDeletable(path) else {
                outcome.failed.append((path, "路径不在允许清理的范围内"))
                continue
            }
            guard fileManager.fileExists(atPath: path) else { continue }

            // Measure before removal; the dump's per-path size is a scan-time
            // snapshot and the directory may have grown or shrunk since.
            let size = directorySize(path)

            do {
                var resulting: NSURL?
                try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resulting)
                outcome.freedBytes += size
                outcome.trashed.append(path)
            } catch {
                outcome.failed.append((path, error.localizedDescription))
            }
        }

        await progress(1, "")
        return outcome
    }

    /// Recursive size on disk. Falls back to the logical size when allocated
    /// size is unavailable.
    static func directorySize(_ path: String) -> Int64 {
        let url = URL(fileURLWithPath: path)
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

        guard let values = try? url.resourceValues(forKeys: keys) else { return 0 }
        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        var total: Int64 = 0
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        for case let child as URL in enumerator {
            guard let childValues = try? child.resourceValues(forKeys: keys),
                  childValues.isRegularFile == true else { continue }
            total += Int64(childValues.totalFileAllocatedSize ?? childValues.fileAllocatedSize ?? 0)
        }
        return total
    }

    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    static func openTrash() {
        NSWorkspace.shared.open(URL(fileURLWithPath: trashPath))
    }

    // MARK: - Emptying

    static var trashPath: String { NSHomeDirectory() + "/.Trash" }

    /// Bytes currently sitting in the Trash. Slow for a large Trash, so callers
    /// run it off the main actor.
    static func trashSize() -> Int64 { directorySize(trashPath) }

    struct EmptyResult {
        var removed = 0
        var freedBytes: Int64 = 0
        /// Full paths that couldn't be removed (in practice root-owned items).
        var failed: [String] = []
    }

    /// Permanently removes everything in the user's Trash — this is the one
    /// deletion in the app that cannot be undone, so callers gate it behind an
    /// explicit confirmation. Root-owned items (e.g. something moved in with
    /// `sudo mv`) can't be removed without elevation and are reported by name
    /// rather than silently skipped. Progress is a 0...1 fraction over the
    /// top-level items, mirroring `run(paths:)`.
    static func emptyTrash(
        progress: @MainActor @escaping (Double) -> Void = { _ in }
    ) async -> EmptyResult {
        var result = EmptyResult()
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: trashPath)
        guard let items = try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil
        ) else {
            await progress(1)
            return result
        }

        for (index, item) in items.enumerated() {
            await progress(Double(index) / Double(items.count))
            let size = directorySize(item.path)
            do {
                try fileManager.removeItem(at: item)
                result.removed += 1
                result.freedBytes += size
            } catch {
                result.failed.append(item.path)
            }
        }
        await progress(1)
        return result
    }
}
