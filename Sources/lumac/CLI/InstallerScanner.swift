import Foundation

/// Finds downloaded installer packages so 安装包清理 can ride along inside the
/// 清理 page instead of being its own destination.
///
/// Deliberately narrow: only unmistakable installer files (`.dmg` / `.pkg`) in
/// the two folders they pile up in. These are user-visible downloads, not
/// caches, so the resulting row is returned **unselected** — the user opts in.
enum InstallerScanner {
    private static let extensions: Set<String> = ["dmg", "pkg"]

    private static var roots: [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return [home.appendingPathComponent("Downloads"),
                home.appendingPathComponent("Desktop")]
    }

    /// Zero rows when nothing is lying around, otherwise a single 安装包清理
    /// category whose paths feed the same Trash flow the other rows use.
    static func scan() -> [ScanItem] {
        let fm = FileManager.default
        var files: [(path: String, bytes: Int64)] = []
        var names: [String] = []

        for root in roots {
            guard let entries = try? fm.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }

            for url in entries where extensions.contains(url.pathExtension.lowercased()) {
                guard Trash.isDeletable(url.path) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                files.append((url.path, Int64(size)))
                names.append(url.deletingPathExtension().lastPathComponent)
            }
        }

        guard !files.isEmpty else { return [] }

        var parts = names.prefix(3).map { $0 as String }
        parts.append("共 \(files.count) 个安装包")

        return [ScanItem(
            name: "安装包清理",
            detail: parts.joined(separator: " · "),
            risk: .review,
            // Installers are user downloads, not caches, so they start unticked.
            entries: files.map { ScanEntry(path: $0.path, bytes: $0.bytes, selected: false) })]
    }
}
