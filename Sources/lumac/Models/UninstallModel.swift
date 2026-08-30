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

    /// Where the leftover list on screen came from.
    ///
    /// Ownership is knowledge, not data — mole carries ~3000 lines of it, so mo
    /// gets the final word. The native scan is the instant first draft (and the
    /// fallback), and this says which of the two the user is looking at.
    enum PreviewSource: Equatable {
        case native                 // AppScanner's draft, mo hasn't answered yet
        case verified               // replaced by mo's own list
        case unavailable(String)    // mo couldn't answer; the draft stands
    }

    // Preview
    var selected: InstalledApp?
    var preview: UninstallPreview?
    var previewLoading = false
    var previewSource: PreviewSource = .native
    /// True while `mo uninstall --dry-run` is re-deriving the list. The trash
    /// button stays disabled throughout: acting on the draft would be acting on
    /// the list lumac already knows is the less trustworthy of the two.
    var verifying = false
    /// Stage reported by mo's own output, and a 0...1 bar. mo prints markers at
    /// the start and the end of its leftover scan but nothing in between, so the
    /// middle is filled from elapsed time against `Self.expectedScanSeconds`.
    var verifyPhase: MoScanPhase?
    var verifyProgress: Double = 0
    /// Measured on this machine: banner 0.2s, match 2.5s, list 25.6s. The run
    /// used to continue to 46s; the preview now stops as soon as the list lands.
    static let expectedScanSeconds: Double = 28

    /// An uninstaller the app shipped with itself, when there is one.
    var vendorUninstaller: VendorUninstaller?

    private var ticker: Task<Void, Never>?
    /// Bumped by every `select`, so a superseded run can tell it is stale.
    private var generation = 0

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
        ticker?.cancel()
        selected = app
        preview = nil
        previewLoading = true
        previewSource = .native
        verifying = false
        verifyPhase = nil
        verifyProgress = 0
        vendorUninstaller = nil
        outcome = nil
        stage = .preview
        // A cancelled run's `defer` fires asynchronously — possibly after the
        // next app's run has already started — so it must not write state that
        // no longer belongs to it.
        generation &+= 1
        let generation = self.generation
        let model = self
        task = Task {
            // Native first so the page has something immediately — AppScanner
            // returns in milliseconds where mo rescans the disk for ~26s.
            let draft = await Task.detached { AppScanner.leftovers(for: app) }.value
            guard !Task.isCancelled else { return }
            self.preview = draft
            self.previewLoading = false
            self.vendorUninstaller = await Task.detached {
                VendorUninstallerScanner.find(for: app)
            }.value

            // Then let mo re-derive it. Its answer replaces the draft: the
            // native sweep matches on bundle id and display name, which is the
            // mis-attribution mole's protection rules exist to prevent.
            self.verifying = true
            self.startTicker()
            defer {
                if model.generation == generation {
                    model.verifying = false
                    model.ticker?.cancel()
                    model.verifyProgress = 1
                }
            }

            // mo matches on the on-disk bundle name, not a localized one.
            let name = (app.path as NSString).lastPathComponent
                .replacingOccurrences(of: ".app", with: "")
            do {
                let output = try await MoCLI.shared.uninstallPreview(named: name) { phase in
                    // A local reference, not `[weak self]`: the enclosing task
                    // already holds the model for the whole call, so weak buys
                    // nothing and only makes the two captures disagree.
                    Task { @MainActor in model.advance(to: phase) }
                }
                guard !Task.isCancelled else { return }
                if let verified = UninstallPreviewParser.parse(
                    output, expecting: app.path, bundleId: app.bundleId) {
                    self.preview = verified
                    self.previewSource = .verified
                } else {
                    // A fuzzy name can match several apps; rather than show one
                    // app's files under another's header, keep the draft.
                    self.previewSource = .unavailable("mo 没能唯一匹配到这个应用")
                }
            } catch is CancellationError {
                return  // the user moved on; nothing to report
            } catch CLIError.notInstalled {
                guard !Task.isCancelled else { return }
                self.previewSource = .unavailable("没有检测到 mo")
            } catch CLIError.timedOut {
                guard !Task.isCancelled else { return }
                self.previewSource = .unavailable("mo 复核超时")
            } catch {
                guard !Task.isCancelled else { return }
                self.previewSource = .unavailable("mo 复核失败")
            }
        }
    }

    /// Fills the silent stretch of mo's scan from elapsed time. mo emits no
    /// progress of its own between "Matched" and "Files to be removed", so the
    /// bar creeps toward 0.92 and the stage markers set the floor under it —
    /// never running past what has actually been observed.
    private func startTicker() {
        let started = Date()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !Task.isCancelled, let self, self.verifying else { return }
                let elapsed = Date().timeIntervalSince(started)
                let timed = min(0.92, elapsed / Self.expectedScanSeconds)
                self.verifyProgress = max(self.verifyPhase?.floor ?? 0, timed)
            }
        }
    }

    private func advance(to phase: MoScanPhase) {
        verifyPhase = phase
        verifyProgress = max(verifyProgress, phase.floor)
    }

    func backToList() {
        task?.cancel()
        ticker?.cancel()
        stage = .list
        selected = nil
        preview = nil
    }

    // MARK: - Selection

    /// Flips one row. Locked rows have no checkbox, so they are never reachable.
    func toggle(_ item: UninstallLeftover) {
        guard !item.locked,
              let i = preview?.leftovers.firstIndex(where: { $0.id == item.id }) else { return }
        preview?.leftovers[i].selected.toggle()
    }

    /// Ticks or unticks a whole section, skipping the rows that have no checkbox.
    func setTier(_ tier: LeftoverTier, _ on: Bool) {
        guard preview != nil else { return }
        for i in preview!.leftovers.indices where preview!.leftovers[i].tier == tier {
            preview!.leftovers[i].selected = on
        }
    }

    func allSelected(in tier: LeftoverTier) -> Bool {
        guard let rows = preview?.leftovers.filter({ $0.tier == tier }), !rows.isEmpty
        else { return false }
        return rows.allSatisfy(\.selected)
    }

    /// mo's list supersedes the draft, so acting before it lands would be
    /// acting on the list lumac itself considers less reliable.
    var canExecute: Bool { !verifying && !(preview?.selectedItems.isEmpty ?? true) }

    // MARK: - Execute

    /// Trashes exactly the ticked rows. Locked items — `/Library`, installer
    /// receipts, anything the Trash guard refuses — are never included.
    func execute() {
        guard let preview, !preview.selectedItems.isEmpty else { return }
        task?.cancel()
        stage = .running
        progress = 0

        let paths = preview.selectedItems.map(\.path)

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
                                        note: self.selected?.name,
                                        moves: outcome.moves)
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
        ticker?.cancel()
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

        // Ground truth is the bundle, not the wording. mo exits 0 whether it
        // removed the app, was declined at either confirmation, or was refused
        // admin rights, and it titles the summary "Uninstall complete" even when
        // `success_count == 0` — which the old substring check read as success.
        // So: the app is gone iff its bundle is gone. `MoUninstallReport` is
        // only consulted to say *why* it is still there.
        let report = MoUninstallReport.parse(output)
        guard !FileManager.default.fileExists(atPath: selected.path) else {
            let why = report.message ?? "mo 报告已删除，但应用仍在原处。"
            return why + "可改用「复制命令」在终端手动删除。"
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
        // Only the user-space leftovers lumac trashed itself are reversible;
        // the bundle went through mo, which does not report where it landed.
        HistoryStore.shared.add(command: "uninstall",
                                freedBytes: totalFreed,
                                itemCount: 1,
                                note: selected.name,
                                moves: outcome?.moves ?? [])
        apps.removeAll { $0.id == selected.id }
        return nil
    }
}
