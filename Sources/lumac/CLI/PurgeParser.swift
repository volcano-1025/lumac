import Foundation

/// Turns `mo purge --dry-run` into tickable rows.
///
/// Unlike `clean`, purge writes no path dump — its dry run prints the whole
/// answer to stdout, one line per build-artifact directory:
///
///     ✓ [DRY RUN] ~/project/node_modules, 120.7MB
///     ✓ [DRY RUN] ~/project/dist, 762KB
///
/// so stdout is authoritative here. Each line becomes one row; the app trashes
/// the directory itself, keeping the "can be restored" promise.
enum PurgeParser {

    static func parse(stdout: String) -> ScanResult {
        let text = CleanParser.strip(stdout)
        var result = ScanResult()

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Only the artifact lines carry the dry-run marker; summary and
            // header lines do not.
            guard line.contains("[DRY RUN]") else { continue }

            // Everything after the marker is "<path>, <size>".
            guard let markerRange = line.range(of: "[DRY RUN]") else { continue }
            let body = line[markerRange.upperBound...].trimmingCharacters(in: .whitespaces)

            // The size is the last comma-separated field; the path may itself
            // contain commas, so split on the last one only.
            guard let comma = body.range(of: ",", options: .backwards) else { continue }
            let rawPath = body[..<comma.lowerBound].trimmingCharacters(in: .whitespaces)
            let sizeText = body[comma.upperBound...]

            let path = expand(rawPath)
            guard Trash.isDeletable(path),
                  FileManager.default.fileExists(atPath: path) else { continue }

            let bytes = Size.firstByteValue(in: String(sizeText)) ?? 0
            result.items.append(ScanItem(
                name: displayName(for: path),
                detail: Trash.abbreviate(path),
                risk: .safe,
                entries: [ScanEntry(path: path, bytes: bytes)]))
        }

        // Biggest artifacts first, so the heavy hitters are on top.
        result.items.sort { $0.bytes > $1.bytes }
        return result
    }

    /// Expands a leading `~` to the home directory; leaves absolute paths alone.
    private static func expand(_ path: String) -> String {
        if path == "~" { return NSHomeDirectory() }
        if path.hasPrefix("~/") { return NSHomeDirectory() + path.dropFirst(1) }
        return path
    }

    /// "node_modules" alone is ambiguous across projects, so the row is named
    /// "<project>/<artifact>" — the last two path components.
    private static func displayName(for path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count >= 2 else { return String(parts.last ?? "") }
        return parts.suffix(2).joined(separator: "/")
    }
}
