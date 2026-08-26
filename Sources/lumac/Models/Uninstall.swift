import Foundation

/// One installed app, enumerated natively from the Applications folders.
///
/// `mo uninstall --list` is not used: it exits early (only ~18 of 58 apps here)
/// and omits the closing `]`, and its per-app `--dry-run` preview takes ~45s.
/// Reading the bundles directly is complete, fast, and yields the last-used date
/// the sort needs.
struct InstalledApp: Identifiable, Hashable {
    var name: String
    var bundleId: String
    var path: String
    var bytes: Int64
    /// From Spotlight's `kMDItemLastUsedDate`; nil when never launched or unindexed.
    var lastUsed: Date?

    var id: String { path }

    var sizeText: String { Size.format(bytes) }

    /// "3 天前 / 2 个月前 / 从未打开" — the secondary sort's human form.
    var lastUsedText: String {
        guard let lastUsed else { return "从未打开" }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: Date()).day ?? 0
        if days <= 0 { return "今天用过" }
        if days == 1 { return "昨天用过" }
        if days < 30 { return "\(days) 天前用过" }
        if days < 365 { return "\(days / 30) 个月前用过" }
        return "超过一年没用"
    }
}

/// One file or directory that removing an app would delete.
struct UninstallLeftover: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var bytes: Int64
    /// True for `/Library` items that need elevated rights — lumac cannot trash
    /// these itself yet, so they are shown but excluded from the trash action.
    var reviewOnly: Bool
}

/// What removing one app would delete, split into what lumac can trash now and
/// what needs authorization.
struct UninstallPreview {
    var leftovers: [UninstallLeftover] = []

    var trashable: [UninstallLeftover] { leftovers.filter { !$0.reviewOnly } }
    var privileged: [UninstallLeftover] { leftovers.filter(\.reviewOnly) }

    var trashableBytes: Int64 { trashable.reduce(0) { $0 + $1.bytes } }
    var isEmpty: Bool { leftovers.isEmpty }
}
