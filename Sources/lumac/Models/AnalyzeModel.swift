import SwiftUI
import Observation

/// Backs 磁盘分析: browse the disk by size, drilling into directories. Kept alive
/// across navigation (like the cleanup models) so a drilled-in location survives
/// switching tabs and back.
@MainActor
@Observable
final class AnalyzeModel {
    enum Phase: Equatable {
        case idle
        case scanning
        case loaded
        case failed(String)
    }

    /// The two views the segmented control switches between.
    enum Mode { case directories, files }

    var phase: Phase = .idle
    var mode: Mode = .directories

    /// Current listing and the trail of paths taken to reach it. The first entry
    /// is the overview root; each drill pushes the directory entered.
    var result: AnalyzeResult = .empty
    private(set) var trail: [Crumb] = []

    struct Crumb: Equatable {
        var name: String
        /// Nil for the overview root, which `analyze` produces with no path arg.
        var path: String?
    }

    private var task: Task<Void, Never>?

    /// Rows to show for the current mode, largest first. 大文件 filters the loaded
    /// listing to plain files; 按目录 keeps everything so directories stay drillable.
    var rows: [AnalyzeEntry] {
        let items = mode == .files ? result.entries.filter { !$0.isDir } : result.entries
        return items.sorted { $0.size > $1.size }
    }

    /// The biggest row's size, so each bar can be drawn relative to it.
    var maxSize: Int64 { rows.map(\.size).max() ?? 0 }

    var atRoot: Bool { trail.count <= 1 }

    // MARK: - Load

    /// Loads the overview if nothing has been scanned yet; a no-op afterwards so
    /// returning to the tab keeps the user where they were.
    func loadIfNeeded() {
        guard phase == .idle else { return }
        reload(into: [Crumb(name: "这台 Mac", path: nil)])
    }

    /// Re-runs the overview from scratch.
    func rescan() {
        reload(into: [Crumb(name: "这台 Mac", path: nil)])
    }

    /// Drills into a directory row, pushing it onto the trail.
    func open(_ entry: AnalyzeEntry) {
        guard entry.isDir else { return }
        reload(into: trail + [Crumb(name: entry.name, path: entry.path)])
    }

    /// Jumps back to a crumb in the trail.
    func jump(to index: Int) {
        guard index < trail.count else { return }
        reload(into: Array(trail.prefix(index + 1)))
    }

    private func reload(into newTrail: [Crumb]) {
        task?.cancel()
        phase = .scanning
        let target = newTrail.last?.path
        task = Task {
            do {
                let result = try await MoCLI.shared.analyze(path: target)
                guard !Task.isCancelled else { return }
                self.result = result
                self.trail = newTrail
                self.phase = .loaded
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }
}
