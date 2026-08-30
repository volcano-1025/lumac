import Foundation

/// Turns `mo purge --dry-run` into tickable rows.
///
/// Unlike `clean`, purge writes no path dump — its dry run prints the whole
/// answer to stdout, one line per build-artifact directory:
///
///     ✓ [DRY RUN] ~/project/node_modules, 120.7MB
///     ✓ [DRY RUN] ~/project/dist, 762KB
///
/// so stdout is authoritative here. The app trashes the directories itself,
/// keeping the "can be restored" promise.
///
/// These now ride along inside 深度清理 rather than living on their own page:
/// `purge` is the same operation as `clean` — scan, tick, trash — and shared
/// the same model and view all along, while the 软件 tab it used to sit in is
/// about installed applications. `mo purge --dry-run` measures ~2.8s against
/// `mo clean --dry-run`'s ~32s, and the two run concurrently, so folding it in
/// costs no measurable time.
///
/// Rows are split by `Cost`: rebuildable artifacts are ticked by default,
/// anything that has to be downloaded again is shown but left unticked.
enum PurgeParser {

    /// Rows for the 深度清理 list — one category per recovery cost, each holding
    /// the individual project directories as tickable entries.
    ///
    /// Grouped rather than one row per directory because this list now shares a
    /// page with the cache categories; a dozen loose `node_modules` rows would
    /// bury them. The category is expandable, so per-directory ticking survives.
    static func categories(stdout: String) -> (items: [ScanItem], skipped: [String]) {
        let text = CleanParser.strip(stdout)
        var found: [(path: String, bytes: Int64, cost: Cost)] = []
        var skipped: [String] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Only the artifact lines carry the dry-run marker; summary and
            // header lines do not.
            guard line.contains("[DRY RUN]"), let marker = line.range(of: "[DRY RUN]")
            else { continue }
            let body = line[marker.upperBound...].trimmingCharacters(in: .whitespaces)

            // The size is the last comma-separated field; the path may itself
            // contain commas, so split on the last one only.
            guard let comma = body.range(of: ",", options: .backwards) else { continue }
            let path = expand(body[..<comma.lowerBound].trimmingCharacters(in: .whitespaces))

            // `isDeletable` only allows the user's own space and the system
            // scratch areas, so a project on an external volume or under /opt is
            // refused. Say so rather than dropping the row — an empty result read
            // as "nothing to clean" when purge had in fact found plenty.
            guard Trash.isDeletable(path) else {
                skipped.append(Protected.covers(path)
                    ? "\(Protected.reason)：\(path)"
                    : "超出允许清理的范围：\(path)")
                continue
            }
            guard FileManager.default.fileExists(atPath: path) else { continue }

            found.append((path,
                          Size.firstByteValue(in: String(body[comma.upperBound...])) ?? 0,
                          Cost.of(path)))
        }

        // Regenerable first, and biggest first inside each group.
        var items: [ScanItem] = []
        for cost in [Cost.regenerable, .redownload] {
            let group = found.filter { $0.cost == cost }.sorted { $0.bytes > $1.bytes }
            guard !group.isEmpty else { continue }

            var parts = group.prefix(3).map { projectName(for: $0.path) }
            parts.append("\(group.count) 个目录")
            items.append(ScanItem(
                name: cost.categoryName,
                detail: cost.note + " · " + parts.joined(separator: " · "),
                risk: cost.risk,
                // Anything that has to come back over the network starts
                // unticked — the user opts in, the way 安装包清理 does.
                entries: group.map {
                    ScanEntry(path: $0.path, bytes: $0.bytes, selected: cost == .regenerable)
                }))
        }
        return (items, skipped)
    }

    /// Expands a leading `~` to the home directory; leaves absolute paths alone.
    private static func expand(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        return path
    }

    /// "node_modules" alone is ambiguous across projects, so an entry is named
    /// "<project>/<artifact>" — the last two path components.
    private static func projectName(for path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return String(parts.last ?? "") }
        return parts.suffix(2).joined(separator: "/")
    }

    /// What it costs to get an artifact back. `mo purge` puts both classes in
    /// one `MOLE_PURGE_TARGETS` list, but they are not the same thing: `target`
    /// and `dist` cost a rebuild — some CPU minutes, offline — while
    /// `node_modules` and `Pods` cost a network round trip, which on a plane or
    /// a train means the project simply cannot be run. Treating them alike is
    /// what makes a purge feel unsafe, so they are split here and the download
    /// class is left unticked.
    enum Cost: Equatable {
        /// Rebuildable offline: a few minutes of CPU.
        case regenerable
        /// Must be fetched again over the network.
        case redownload

        /// Directory names whose contents come back only from the network.
        /// From `MOLE_PURGE_TARGETS` (mole 1.53.0, `lib/clean/purge_shared.sh`).
        private static let networkBound: Set<String> = [
            "node_modules",         // npm / pnpm / yarn
            "Pods",                 // CocoaPods
            "vendor",               // PHP Composer
            "venv", ".venv",        // Python virtualenvs
            ".tox", ".nox",         // Python test virtualenvs
            ".gradle",              // Gradle's downloaded dependency cache
            ".terragrunt-cache",    // Terragrunt modules and providers
        ]

        static func of(_ path: String) -> Cost {
            let name = (path as NSString).lastPathComponent
            return networkBound.contains(name) ? .redownload : .regenerable
        }

        var risk: RiskLevel { self == .redownload ? .review : .safe }

        var note: String {
            switch self {
            case .regenerable: return "重新编译即可恢复"
            case .redownload:  return "删除后需要重新联网下载"
            }
        }

        var categoryName: String {
            switch self {
            case .regenerable: return "项目构建产物"
            case .redownload:  return "项目依赖包"
            }
        }
    }

}
