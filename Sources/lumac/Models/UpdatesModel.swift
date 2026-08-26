import SwiftUI
import Observation

/// Backs 应用更新. Homebrew is the only update source available, so this checks
/// `brew outdated` and upgrades on demand, tracking per-item and overall progress.
@MainActor
@Observable
final class UpdatesModel {
    enum Phase: Equatable {
        case loading
        case loaded
        case empty          // brew present, nothing outdated
        case noBrew         // Homebrew not installed
        case failed(String)
    }

    /// Where one package is in the upgrade flow.
    enum ItemState: Equatable { case idle, updating, done, failed }

    var phase: Phase = .loading
    var items: [BrewUpdate] = []

    private var states: [String: ItemState] = [:]

    // 全部更新 progress.
    var allRunning = false
    var allTotal = 0
    var allDone = 0
    var current = ""
    /// Set when a run (single "全部更新" pass) finishes, for the completion banner.
    var summary: String?

    private var task: Task<Void, Never>?

    func state(_ item: BrewUpdate) -> ItemState { states[item.id] ?? .idle }

    /// Progress fraction for the overall bar, 0...1.
    var allProgress: Double { allTotal > 0 ? Double(allDone) / Double(allTotal) : 0 }

    // MARK: - Load

    func loadIfNeeded() {
        guard phase == .loading, items.isEmpty else { return }
        reload()
    }

    func reload() {
        task?.cancel()
        guard Brew.isInstalled else { phase = .noBrew; return }
        phase = .loading
        states = [:]
        summary = nil
        task = Task {
            do {
                let items = try await Brew.outdated()
                guard !Task.isCancelled else { return }
                self.items = items
                self.phase = items.isEmpty ? .empty : .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Upgrade

    func upgrade(_ item: BrewUpdate) {
        guard state(item) != .updating, !allRunning else { return }
        states[item.id] = .updating
        summary = nil
        Task {
            let ok = await Brew.upgrade(item)
            self.states[item.id] = ok ? .done : .failed
        }
    }

    /// Upgrades every not-yet-done package in turn, reporting progress as it goes.
    func upgradeAll() {
        guard !allRunning else { return }
        let pending = items.filter { state($0) != .done }
        guard !pending.isEmpty else { return }

        allRunning = true
        summary = nil
        allTotal = pending.count
        allDone = 0

        task = Task {
            var failed = 0
            for item in pending {
                self.current = item.name
                self.states[item.id] = .updating
                let ok = await Brew.upgrade(item)
                self.states[item.id] = ok ? .done : .failed
                if !ok { failed += 1 }
                self.allDone += 1
            }
            self.current = ""
            self.allRunning = false
            let succeeded = self.allTotal - failed
            self.summary = failed == 0
                ? "全部完成 · 已更新 \(succeeded) 个"
                : "已更新 \(succeeded) 个 · \(failed) 个未成功（可能需要授权，请在终端用 brew 完成）"
        }
    }
}
