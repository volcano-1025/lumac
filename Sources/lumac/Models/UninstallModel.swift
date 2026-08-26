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
            self.stage = .done
            if !outcome.trashed.isEmpty {
                HistoryStore.shared.add(command: "uninstall",
                                        freedBytes: outcome.freedBytes,
                                        itemCount: outcome.trashed.count,
                                        note: self.selected?.name)
            }
            // The app is gone from disk; drop it from the list so returning to
            // the grid reflects reality without a full rescan.
            if let selected = self.selected {
                self.apps.removeAll { $0.id == selected.id }
            }
        }
    }

    func reset() {
        task?.cancel()
        stage = .list
        selected = nil
        preview = nil
        outcome = nil
        progress = 0
    }
}
