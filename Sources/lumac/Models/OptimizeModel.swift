import SwiftUI
import Observation

/// Backs 系统优化. Unlike the cleanup pages this deletes nothing — it runs a set
/// of maintenance steps (flush caches, rebuild indexes, repair configs), so it
/// has its own small state machine rather than the trash-list flow.
@MainActor
@Observable
final class OptimizeModel {
    enum Phase: Equatable {
        case loading    // fetching the dry-run preview
        case ready      // showing the steps that would run
        case running    // optimizing
        case done       // finished, showing results
        case failed(String)
    }

    var phase: Phase = .loading
    var result = OptimizeResult()

    private var task: Task<Void, Never>?

    /// Loads the dry-run preview once; a no-op afterwards so returning to the tab
    /// keeps the current state.
    func loadIfNeeded() {
        guard phase == .loading, result.isEmpty else { return }
        preview()
    }

    func preview() {
        task?.cancel()
        phase = .loading
        task = Task {
            do {
                let result = try await MoCLI.shared.optimizePreview()
                guard !Task.isCancelled else { return }
                self.result = result
                self.phase = .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    func optimize() {
        task?.cancel()
        phase = .running
        task = Task {
            do {
                let result = try await MoCLI.shared.optimizeExecute()
                guard !Task.isCancelled else { return }
                self.result = result
                self.phase = .done
                // Optimize frees nothing measurable; the summary is the record.
                HistoryStore.shared.add(command: "optimize", freedBytes: 0,
                                        itemCount: 0, note: result.summary)
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}
