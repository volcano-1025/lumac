import SwiftUI
import Observation

/// Backs 卸载应用: browse installed apps, preview what removing one would delete,
/// then move the user-space parts to the Trash. The list and previews come from
/// `AppScanner` (native), not the CLI. Kept alive across navigation so the loaded
/// list survives leaving the tab.
@MainActor
@Observable
final class UninstallModel {
    enum Stage: Equatable {
        case list       // browsing the installed-app grid
        case preview    // one app selected, showing what would be removed
        case running    // trashing
        case done       // finished
    }

    enum SortKey: String, CaseIterable {
        case size, lastUsed, name
        var label: String {
            switch self {
            case .size:     return "大小"
            case .lastUsed: return "最近使用"
            case .name:     return "名称"
            }
        }
    }

    var stage: Stage = .list

    // List
    var apps: [InstalledApp] = []
    var listLoading = false
    var query = ""
    var sort: SortKey = .size

    // Preview
    var selected: InstalledApp?
    var preview: UninstallPreview?
    var previewLoading = false

    // Run
    var progress: Double = 0
    var outcome: Trash.Outcome?
    /// True while the native admin prompt is up for a privileged removal.
    var elevating = false

    private var task: Task<Void, Never>?

    /// Apps matching the search box, ordered by the chosen sort.
    var filteredApps: [InstalledApp] {
        let base = query.trimmingCharacters(in: .whitespaces).lowercased()
        let matched = base.isEmpty ? apps : apps.filter {
            $0.name.lowercased().contains(base) || $0.bundleId.lowercased().contains(base)
        }
        switch sort {
        case .size:
            return matched.sorted { $0.bytes > $1.bytes }
        case .lastUsed:
            // Most recently used first; never-used (nil) sink to the bottom.
            return matched.sorted {
                ($0.lastUsed ?? .distantPast) > ($1.lastUsed ?? .distantPast)
            }
        case .name:
            return matched.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    // MARK: - List

    func loadListIfNeeded() {
        guard apps.isEmpty, !listLoading else { return }
        reloadList()
    }

    func reloadList() {
        task?.cancel()
        listLoading = true
        task = Task {
            // Sizing every bundle touches the disk, so it runs off the main actor.
            let apps = await Task.detached { AppScanner.installedApps() }.value
            guard !Task.isCancelled else { return }
            self.apps = apps
            self.listLoading = false
        }
    }

    // MARK: - Preview

    func select(_ app: InstalledApp) {
        task?.cancel()
        selected = app
        preview = nil
        previewLoading = true
        outcome = nil
        stage = .preview
        task = Task {
            let preview = await Task.detached { AppScanner.leftovers(for: app) }.value
            guard !Task.isCancelled else { return }
            self.preview = preview
            self.previewLoading = false
        }
    }

    func backToList() {
        task?.cancel()
        stage = .list
        selected = nil
        preview = nil
    }

    // MARK: - Execute

    /// Moves the app bundle and its user-space leftovers to the Trash. Privileged
    /// `/Library` items are left for a future authorized flow.
    func execute() {
        guard let preview, !preview.trashable.isEmpty else { return }
        task?.cancel()
        stage = .running
        progress = 0

        let paths = preview.trashable.map(\.path)

        task = Task {
            let outcome = await Trash.run(paths: paths) { fraction, _ in
                self.progress = fraction
            }
            guard !Task.isCancelled else { return }
            self.outcome = outcome

            // The app bundle is root-owned and the native trash couldn't touch
            // it — don't stop at a failure screen. Hand it straight to mo, which
            // elevates, staying on the progress view. uninstallViaMo folds the
            // app into the outcome and records history; only if mo *also* fails
            // does the done screen surface the manual fallback.
            if let selected = self.selected,
               self.isRootOwnedAppFailure(outcome, appPath: selected.path) {
                _ = await self.uninstallViaMo()
                guard !Task.isCancelled else { return }
                self.stage = .done
                return
            }

            self.stage = .done
            // Only count this as an uninstall if the app *bundle* actually left.
            // Trashing a few user-owned leftovers while the app itself failed is
            // not a completed uninstall and must not be logged or drop the app
            // from the list — that's what produced the bogus repeated entries.
            let appRemoved = self.selected.map { outcome.trashed.contains($0.path) } ?? false
            if appRemoved {
                HistoryStore.shared.add(command: "uninstall",
                                        freedBytes: outcome.freedBytes,
                                        itemCount: outcome.trashed.count,
                                        note: self.selected?.name)
                // The app is gone from disk; drop it from the list so returning
                // to the grid reflects reality without a full rescan.
                if let selected = self.selected {
                    self.apps.removeAll { $0.id == selected.id }
                }
            }
        }
    }

    /// True when the app bundle itself is in the failure list because it's owned
    /// by another user (root) — the one case worth auto-delegating to mo.
    private func isRootOwnedAppFailure(_ outcome: Trash.Outcome, appPath: String) -> Bool {
        guard outcome.failed.contains(where: { $0.path == appPath }) else { return false }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: appPath),
              let owner = attrs[.ownerAccountID] as? NSNumber else { return false }
        return owner.uint32Value != getuid()
    }

    func reset() {
        task?.cancel()
        stage = .list
        selected = nil
        preview = nil
        outcome = nil
        progress = 0
    }

    /// Removes a root-owned app that lumac couldn't trash itself by delegating to
    /// `mo uninstall <name>` — mo already carries a Touch ID + passwordless
    /// sudoers rule, so this reuses that elevation rather than lumac installing
    /// one. Only used for the rare root-owned case; normal apps stay on the fast
    /// native path. On success the done screen flips to a real removal and the
    /// app drops out of the list. Returns nil on success, or a message to show.
    func uninstallViaMo() async -> String? {
        guard let selected else { return "没有选中的应用" }
        // mo matches on the app's on-disk name; the bundle filename is closer to
        // that than a localized display name.
        let name = (selected.path as NSString).lastPathComponent
            .replacingOccurrences(of: ".app", with: "")

        elevating = true
        defer { elevating = false }

        let output: String
        do {
            output = try await MoCLI.shared.uninstallApp(named: name)
        } catch {
            return error.localizedDescription
        }

        // mo returns 0 even when it matched nothing, so confirm from the text.
        let removed = output.localizedCaseInsensitiveContains("Uninstall complete")
            || output.localizedCaseInsensitiveContains("Removed 1 app")
            || output.localizedCaseInsensitiveContains("Removed")
        let matchedNone = output.localizedCaseInsensitiveContains("No matching")
            || output.localizedCaseInsensitiveContains("No application found")
        guard removed, !matchedNone else {
            return "mo 未能完成卸载。可改用「复制命令」在终端手动删除。"
        }

        var totalFreed = selected.bytes
        if var updated = outcome {
            updated.failed.removeAll { $0.path == selected.path }
            if !updated.trashed.contains(selected.path) {
                updated.trashed.append(selected.path)
            }
            updated.freedBytes += selected.bytes  // native leftovers + the app
            totalFreed = updated.freedBytes
            outcome = updated
        }
        HistoryStore.shared.add(command: "uninstall",
                                freedBytes: totalFreed,
                                itemCount: 1,
                                note: selected.name)
        apps.removeAll { $0.id == selected.id }
        return nil
    }
}
