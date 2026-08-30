import Foundation

/// The five list-style pages share one scan/confirm/execute state machine.
enum CleanupCommand: String, CaseIterable, Identifiable {
    case clean, uninstall, purge, installer, optimize

    var id: String { rawValue }

    /// How the shared cleanup state machine turns a dry run into tickable rows.
    ///
    /// * `.cleanDump` — `clean` writes `clean-list.txt`; that dump is the source
    ///   of paths, stdout only supplies grouping and risk.
    /// * `.unsupported` — no page of its own. `installer` drives an interactive
    ///   TUI and `purge` prints its whole answer to stdout; both are folded into
    ///   the `clean` scan as extra categories instead. `uninstall` and
    ///   `optimize` have their own dedicated screens.
    enum ScanStrategy { case cleanDump, unsupported }

    var scanStrategy: ScanStrategy {
        switch self {
        case .clean: return .cleanDump
        case .purge, .uninstall, .installer, .optimize: return .unsupported
        }
    }

    var dryRunArguments: [String] {
        switch self {
        case .clean:     return ["clean", "--dry-run"]
        case .uninstall: return ["uninstall", "--dry-run"]
        case .purge:     return ["purge", "--dry-run"]
        case .installer: return ["installer", "--dry-run"]
        case .optimize:  return ["optimize", "--dry-run"]
        }
    }
}

/// How dangerous an item is, which drives the row's tag colour and whether
/// executing needs a confirmation sheet.
enum RiskLevel: Int, Comparable {
    case safe = 0
    case review = 1
    case high = 2

    static func < (a: RiskLevel, b: RiskLevel) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .safe:   return "安全"
        case .review: return "需确认"
        case .high:   return "高风险"
        }
    }
}

/// One concrete path inside a category, individually tickable.
struct ScanEntry: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var bytes: Int64
    var selected: Bool = true
}

/// One category from the scan (`=== User essentials ===`), holding the concrete
/// paths under it. The category is expandable so the user can see and pick the
/// individual locations rather than accepting or rejecting the whole group.
struct ScanItem: Identifiable, Hashable {
    let id = UUID()
    var name: String
    /// Secondary line: what the category covers, or a sample path.
    var detail: String
    var risk: RiskLevel
    var entries: [ScanEntry]

    /// Total size of every path in the category, ticked or not.
    var bytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }
    /// Size of just the ticked paths — what this row contributes to the total.
    var selectedBytes: Int64 { entries.filter(\.selected).reduce(0) { $0 + $1.bytes } }
    var selectedCount: Int { entries.filter(\.selected).count }
    var pathCount: Int { entries.count }

    var anySelected: Bool { entries.contains { $0.selected } }
    var allSelected: Bool { !entries.isEmpty && entries.allSatisfy(\.selected) }
    /// The ticked paths, for the Trash step.
    var selectedPaths: [String] { entries.filter(\.selected).map(\.path) }

    // Equatable and Hashable are synthesized on purpose. SwiftUI compares row
    // values to decide whether to redraw, so an `==` that ignored per-entry
    // `selected` would leave a ticked box on screen after the user unticks it.
}

/// The outcome of a dry-run scan.
struct ScanResult {
    var items: [ScanItem] = []
    /// Entries the CLI could not evaluate — a missing tool, a locked directory.
    var skipped: [String] = []
    /// True when the scan reported that a full preview needs elevated rights.
    var needsPrivileges: Bool = false

    /// Sum of every ticked path across categories.
    var totalBytes: Int64 { items.reduce(0) { $0 + $1.selectedBytes } }
    /// Number of ticked paths across categories.
    var selectedCount: Int { items.reduce(0) { $0 + $1.selectedCount } }
    var isEmpty: Bool { items.isEmpty }
}
