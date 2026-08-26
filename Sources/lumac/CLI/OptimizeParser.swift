import Foundation

/// One maintenance step from `mo optimize`. In a dry run every step is a `.plan`
/// of what would happen; after a real run each carries its outcome.
struct OptimizeTask: Identifiable, Hashable {
    let id = UUID()
    var title: String
    var detail: String
    var outcome: Outcome

    enum Outcome {
        case plan   // dry run: this would run
        case ok     // done, or already healthy
        case warn   // failed / skipped / unavailable
    }
}

/// The parsed result of an optimize run: the per-step list plus the summary line.
struct OptimizeResult {
    var tasks: [OptimizeTask] = []
    /// e.g. "已应用 2 项 · 13 项无需处理 · 4 跳过 · 1 失败", or nil for a dry run.
    var summary: String?
    var isEmpty: Bool { tasks.isEmpty }
}

/// Parses the `➤ Category` / `✓ → ◎ action` structure `mo optimize` prints.
///
///     ➤ DNS & Spotlight Check
///       → DNS cache flushed              (dry run: would happen)
///       ✓ Spotlight index verified       (real run: done / healthy)
///       ◎ Failed to scan shared lists    (real run: failed / skipped)
enum OptimizeParser {

    static func parse(_ stdout: String, dryRun: Bool) -> OptimizeResult {
        let text = CleanParser.strip(stdout)
        var result = OptimizeResult()

        var title: String?
        var detail: String?
        var outcome: OptimizeTask.Outcome = .plan
        var summaryParts: [String] = []

        func flush() {
            guard let title else { return }
            result.tasks.append(OptimizeTask(
                title: OptimizeText.title(title),
                detail: detail.map(OptimizeText.detail) ?? "",
                outcome: outcome))
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("➤") {
                flush()
                title = line.dropFirst().trimmingCharacters(in: .whitespaces)
                // Reset per category — otherwise a line seen before the first
                // category (the "DRY RUN MODE" banner) leaks in as its detail.
                detail = nil
                outcome = dryRun ? .plan : .ok
                continue
            }

            // The summary block closes the list.
            if line.hasPrefix("=") { continue }
            if let parsed = summaryLine(line) { summaryParts.append(parsed); continue }

            // Action lines under the current category; ignore anything printed
            // before the first ➤ heading (banner, diagnosis section).
            guard title != nil else { continue }
            let marker = line.first
            guard marker == "→" || marker == "✓" || marker == "◎" else { continue }
            let body = line.dropFirst().trimmingCharacters(in: .whitespaces)
            // The first action line stands in as the category's detail.
            if detail == nil { detail = body }
            // A failure marker downgrades the category — but only for a real run.
            // In a dry run every line is a prediction, so nothing is a warning yet.
            if marker == "◎" && !dryRun { outcome = .warn }
        }
        flush()
        result.summary = summaryParts.isEmpty ? nil : summaryParts.joined(separator: " · ")
        return result
    }

    /// Turns the CLI's English summary into the interface's wording.
    private static func summaryLine(_ line: String) -> String? {
        if line.hasPrefix("Applied ") {
            let n = line.replacingOccurrences(of: "Applied ", with: "")
                .replacingOccurrences(of: " optimizations", with: "")
                .replacingOccurrences(of: " optimization", with: "")
            return "已应用 \(n) 项优化"
        }
        // "13 unchanged | 4 skipped | 1 unavailable | 1 failed"
        if line.contains("unchanged") || line.contains("skipped") || line.contains("failed") {
            return line
                .replacingOccurrences(of: "unchanged", with: "项无需处理")
                .replacingOccurrences(of: "skipped", with: "跳过")
                .replacingOccurrences(of: "unavailable", with: "不适用")
                .replacingOccurrences(of: "failed", with: "失败")
                .replacingOccurrences(of: " | ", with: " · ")
        }
        return nil
    }
}
