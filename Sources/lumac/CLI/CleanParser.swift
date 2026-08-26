import Foundation

/// Turns a `mo <command> --dry-run` run into the tickable list the UI shows.
///
/// Two sources are merged, because neither is sufficient alone:
///
/// * **stdout** gives the category order, the human names of what was found and
///   the markers that flag risk (`⊙ manual review`) or a skipped check (`◎`).
/// * **`~/.config/mole/clean-list.txt`** gives the absolute paths and their
///   sizes, grouped under the same category headings.
///
/// The app trashes the paths itself, so the path dump is authoritative for both
/// what gets deleted and how much it frees; stdout only supplies presentation.
enum CleanParser {

    static func parse(stdout: String) -> ScanResult {
        let text = strip(stdout)
        let meta = parseCategories(text)
        let dump = PathDump.load()

        var result = ScanResult()
        result.needsPrivileges = text.contains("need sudo") || text.contains("requires sudo")

        // Walk the categories in the order stdout reported them, so the list
        // reads the way the CLI grouped it.
        for category in meta.order {
            guard let entries = dump.paths(for: category), !entries.isEmpty else { continue }
            let info = meta.categories[category]

            let existing = entries.filter { FileManager.default.fileExists(atPath: $0.path) }
            guard !existing.isEmpty else { continue }

            result.items.append(ScanItem(
                name: Localized.category(category),
                detail: detailLine(info: info, entries: existing),
                risk: info?.risk ?? .safe,
                entries: existing.map { ScanEntry(path: $0.path, bytes: $0.bytes) }))
        }

        result.skipped = meta.skipped
        return result
    }

    private static func detailLine(info: CategoryInfo?, entries: [PathDump.Entry]) -> String {
        var parts: [String] = []
        if let names = info?.itemNames, !names.isEmpty {
            parts.append(names.prefix(3).joined(separator: " · "))
        }
        parts.append("\(entries.count) 个位置")
        return parts.joined(separator: " · ")
    }

    // MARK: - stdout

    struct CategoryInfo {
        var itemNames: [String] = []
        var risk: RiskLevel = .safe
    }

    private struct Meta {
        var order: [String] = []
        var categories: [String: CategoryInfo] = [:]
        var skipped: [String] = []
    }

    /// Reads the `➤ category` / `→ item` structure out of stdout.
    private static func parseCategories(_ text: String) -> Meta {
        var meta = Meta()
        var current: String?

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("➤") {
                let title = line.dropFirst().trimmingCharacters(in: .whitespaces)
                // A TUI selection screen also uses ➤ as its cursor; those lines
                // carry a ○/● bullet and are not category headings.
                guard !title.hasPrefix("○"), !title.hasPrefix("●") else { continue }
                current = title
                if meta.categories[title] == nil {
                    meta.order.append(title)
                    meta.categories[title] = CategoryInfo()
                }
                continue
            }

            guard let category = current else { continue }

            if line.hasPrefix("◎") {
                meta.skipped.append(line.dropFirst().trimmingCharacters(in: .whitespaces))
                continue
            }

            let isReview = line.hasPrefix("⊙")
            guard line.hasPrefix("→") || isReview else { continue }

            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            let name = body.components(separatedBy: "·")[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }

            var info = meta.categories[category] ?? CategoryInfo()
            info.itemNames.append(name)
            if isReview { info.risk = max(info.risk, .review) }
            meta.categories[category] = info
        }
        return meta
    }

    /// Removes ANSI escape sequences — SGR colour plus the cursor and erase
    /// codes the TUI-style commands emit.
    static func strip(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[a-zA-Z]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}[()][0-9A-B]", with: "", options: .regularExpression)
    }
}

/// Reads `~/.config/mole/clean-list.txt`, the path dump a dry run writes.
///
///     === User essentials ===
///     /Users/me/Library/Caches/Google  # 1.65GB
struct PathDump {
    struct Entry {
        var path: String
        var bytes: Int64
    }

    private var byCategory: [String: [Entry]] = [:]

    static var fileURL: URL {
        URL(fileURLWithPath: NSHomeDirectory() + "/.config/mole/clean-list.txt")
    }

    /// True when the dump was written by the scan that just ran, rather than
    /// left over from an earlier one. A stale dump would offer the user paths
    /// that a failed or unrelated scan never actually found.
    static func isFresh(since start: Date) -> Bool {
        guard let modified = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate else { return false }
        // Allow a small margin for clock granularity between the two processes.
        return modified >= start.addingTimeInterval(-2)
    }

    static func load() -> PathDump {
        var dump = PathDump()
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return dump }

        var category: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("===") {
                category = line.trimmingCharacters(in: CharacterSet(charactersIn: "= "))
                continue
            }
            guard let category, line.hasPrefix("/") else { continue }

            let parts = line.components(separatedBy: "#")
            let path = parts[0].trimmingCharacters(in: .whitespaces)
            let bytes = parts.count > 1 ? (Size.firstByteValue(in: parts[1]) ?? 0) : 0
            guard Trash.isDeletable(path) else { continue }
            dump.byCategory[category, default: []].append(Entry(path: path, bytes: bytes))
        }
        return dump
    }

    func paths(for category: String) -> [Entry]? { byCategory[category] }
}

/// Byte-size formatting and parsing.
enum Size {
    private static let units: [(String, Double)] = [
        ("TB", 1_099_511_627_776), ("GB", 1_073_741_824),
        ("MB", 1_048_576), ("KB", 1024), ("B", 1),
    ]

    /// Finds the first size literal in a string ("471.1MB", "0B", "1.63GB").
    static func firstByteValue(in text: String) -> Int64? {
        let pattern = #"([0-9]+(?:\.[0-9]+)?)\s*(TB|GB|MB|KB|B)\b"#
        guard let range = text.range(of: pattern, options: .regularExpression) else { return nil }
        let literal = text[range].trimmingCharacters(in: .whitespaces)
        for (suffix, scale) in units where literal.hasSuffix(suffix) {
            guard let value = Double(literal.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)) else {
                return nil
            }
            return Int64(value * scale)
        }
        return nil
    }

    /// Display form used across the UI.
    static func format(_ bytes: Int64) -> String {
        if bytes <= 0 { return "—" }
        let gb = Double(bytes) / 1_073_741_824
        if gb >= 1 { return String(format: "%.1f GB", gb) }
        let mb = Double(bytes) / 1_048_576
        if mb >= 1 { return "\(Int(mb.rounded())) MB" }
        return "\(max(1, Int((Double(bytes) / 1024).rounded()))) KB"
    }
}

/// The CLI's category headings are English; the interface is Chinese.
enum Localized {
    private static let categories: [String: String] = [
        "User essentials": "用户缓存与日志",
        "App caches": "应用缓存",
        "Browsers": "浏览器缓存",
        "Cloud & Office": "云盘与办公套件",
        "Developer tools": "开发工具缓存",
        "Apps & utilities": "应用与工具缓存",
        "Virtualization": "虚拟机残留",
        "Application Support": "应用支持文件",
        "App leftovers": "已卸载应用的残留",
        "System caches": "系统缓存",
        "Logs": "系统日志",
        "Trash": "废纸篓",
        "Downloads": "下载文件",
        "Large files": "大文件",
        "Project artifacts": "项目构建产物",
        "Device backups & firmware": "设备备份与固件",
        "Time Machine": "Time Machine 本地快照",
        "Apple Silicon updates": "系统更新缓存",
        "Mail": "邮件附件缓存",
        "Xcode": "Xcode 派生数据",
    ]

    static func category(_ raw: String) -> String { categories[raw] ?? raw }
}
