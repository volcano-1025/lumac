import SwiftUI
import Observation

/// The five list-style pages share this state machine:
/// 空闲 → 扫描中 → 待确认列表 → 执行中 → 完成.
enum CleanupPhase: Equatable {
    case idle
    case scanning
    case ready
    case running
    case done
    /// Scan completed and found nothing worth removing.
    case empty
    case failed(String)
    /// The page has no scanner yet — see `CleanupCommand.producesPathDump`.
    case unsupported
}

@MainActor
@Observable
final class CleanupModel {
    let command: CleanupCommand

    var phase: CleanupPhase = .idle
    var result = ScanResult()

    /// 0...1 during scanning and running.
    var progress: Double = 0
    /// The path currently being scanned or trashed.
    var currentPath: String = ""

    var outcome: Trash.Outcome?
    /// Set when the scan reported that some checks need elevated rights.
    var needsPrivileges = false

    private var task: Task<Void, Never>?

    init(command: CleanupCommand) {
        self.command = command
    }

    var canExecute: Bool { result.selectedCount > 0 }

    /// The plain-language line the bottom bar shows before executing.
    var summaryText: String {
        "已选 \(result.selectedCount) 项 · \(Size.format(result.totalBytes)) · 将移入废纸篓，可随时还原"
    }

    // MARK: - Scan

    func scan() {
        task?.cancel()
        phase = .scanning
        progress = 0
        currentPath = ""
        outcome = nil

        guard command.scanStrategy != .unsupported else {
            phase = .unsupported
            return
        }

        // Anything older than the run we are about to start is a leftover from
        // a previous scan and must not be presented as this scan's result.
        let startedAt = Date()

        task = Task { [command] in
            // The CLI does not stream progress for a dry run, so the bar shows
            // indeterminate motion rather than a fake percentage.
            do {
                let stdout = try await MoCLI.shared.run(command.dryRunArguments, allowFailure: true)
                guard !Task.isCancelled else { return }

                let parsed: ScanResult
                switch command.scanStrategy {
                case .cleanDump:
                    // The path dump is authoritative for clean; a stale one would
                    // offer paths this scan never actually found.
                    guard PathDump.isFresh(since: startedAt) else {
                        self.phase = .failed("这次检查没有生成文件清单，为安全起见不显示结果。")
                        return
                    }
                    var clean = CleanParser.parse(stdout: stdout)
                    // 安装包清理 rides along in the 清理 page as one unchecked row,
                    // rather than living behind its own navigation entry.
                    clean.items.append(contentsOf: InstallerScanner.scan())
                    parsed = clean
                case .purgeStdout:
                    parsed = PurgeParser.parse(stdout: stdout)
                case .unsupported:
                    return  // Already handled above.
                }

                self.result = parsed
                self.needsPrivileges = parsed.needsPrivileges
                self.phase = parsed.isEmpty ? .empty : .ready
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failed(error.localizedDescription)
            }
        }
    }

    // MARK: - Selection

    /// Toggles a whole category: if any path is unticked, tick them all;
    /// otherwise untick them all.
    func toggle(_ item: ScanItem) {
        guard let index = result.items.firstIndex(where: { $0.id == item.id }) else { return }
        let turnOn = !result.items[index].allSelected
        for e in result.items[index].entries.indices {
            result.items[index].entries[e].selected = turnOn
        }
    }

    /// Toggles a single path inside a category.
    func toggleEntry(_ item: ScanItem, _ entry: ScanEntry) {
        guard let i = result.items.firstIndex(where: { $0.id == item.id }),
              let j = result.items[i].entries.firstIndex(where: { $0.id == entry.id }) else { return }
        result.items[i].entries[j].selected.toggle()
    }

    func setAll(_ selected: Bool) {
        for i in result.items.indices {
            for j in result.items[i].entries.indices {
                result.items[i].entries[j].selected = selected
            }
        }
    }

    var allSelected: Bool { !result.items.isEmpty && result.items.allSatisfy(\.allSelected) }

    /// True when any ticked path belongs to a category that needs confirmation.
    var selectionIsRisky: Bool {
        result.items.contains { $0.risk > .safe && $0.anySelected }
    }

    // MARK: - Execute

    func execute() {
        let paths = result.items.flatMap(\.selectedPaths)
        guard !paths.isEmpty else { return }

        task?.cancel()
        phase = .running
        progress = 0

        task = Task {
            let outcome = await Trash.run(paths: paths) { fraction, path in
                self.progress = fraction
                self.currentPath = path
            }
            guard !Task.isCancelled else { return }
            self.outcome = outcome
            self.phase = .done
            // Record what was actually freed — not the dry-run's "would free".
            if !outcome.trashed.isEmpty {
                HistoryStore.shared.add(command: command.rawValue,
                                        freedBytes: outcome.freedBytes,
                                        itemCount: outcome.trashed.count)
            }
        }
    }

    /// Cancels the running scan or cleanup. Work already completed is not
    /// rolled back — files already in the Trash stay there.
    func cancel() {
        task?.cancel()
        task = nil
        switch phase {
        case .scanning: phase = .idle
        case .running:  phase = .done
        default:        break
        }
    }

    func reset() {
        task?.cancel()
        task = nil
        phase = .idle
        result = ScanResult()
        outcome = nil
        progress = 0
        currentPath = ""
    }
}

extension CleanupCommand {
    /// What the idle state promises this command will do.
    var idleHeadline: String {
        switch self {
        case .clean:     return "扫描缓存、日志和浏览器残留"
        case .uninstall: return "列出可以卸载的应用"
        case .purge:     return "查找项目里的构建产物"
        case .installer: return "查找下载过的安装包"
        case .optimize:  return "检查可以优化的系统项目"
        }
    }

    var idleDetail: String {
        switch self {
        case .clean:
            return "会检查应用缓存、系统与应用日志、浏览器缓存、已卸载应用的残留，以及下载文件夹里的安装包。\n安装包默认不勾选；扫描不会改动任何东西，你可以逐项确认之后再清理。"
        case .uninstall:
            return "会列出这台 Mac 上安装的应用，连同它们的启动项、偏好设置和隐藏残留一起移除。"
        case .purge:
            return "会在你指定的目录里查找 node_modules、target、dist、venv 等构建产物。"
        case .installer:
            return "会在下载文件夹、桌面、Homebrew 缓存和 iCloud 里查找用过的安装包。"
        case .optimize:
            return "会重建系统数据库、刷新服务与索引。不会删除你的个人文件。"
        }
    }

    var startButtonTitle: String {
        switch self {
        case .clean, .purge, .installer: return "开始检查"
        case .uninstall: return "列出应用"
        case .optimize:  return "开始检查"
        }
    }
}
