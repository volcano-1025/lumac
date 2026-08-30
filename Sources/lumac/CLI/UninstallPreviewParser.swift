import Foundation

/// Turns `mo uninstall --dry-run <name>` into the leftover list 卸载应用 shows.
///
/// Why the CLI and not `AppScanner`: deciding what belongs to an app is
/// knowledge, not data. mole carries ~3000 lines of it (`app_protection.sh`,
/// `app_protection_data.sh`, `bundle_resolver.sh`) accumulated from real
/// damage reports — issue #993, where uninstalling Claude.app wiped the
/// unrelated Claude Code CLI's `~/.claude`, is one line in that file. A
/// bundle-id and display-name sweep cannot reproduce it. Measured against this
/// machine, the native scan found 6 of the 9 items mo lists for one app,
/// missing `Preferences/ByHost`, `Application Support/CrashReporter` and
/// `/Library/Logs/DiagnosticReports`.
///
/// The block being parsed (mole 1.53.0, `batch.sh:_batch_preview_and_confirm`,
/// with NO_COLOR set):
///
///     Files to be removed:
///
///     ◎ Claude , 1.11GB
///       ✓ /Applications/Claude.app , 863.0MB
///       ✓ ~/Library/Application Support/Claude , 242.5MB
///       ⚠ System: /Library/LaunchDaemons/com.foo.plist
///       ◎ Review only: /Library/Logs/DiagnosticReports/Claude_….diag , 16KB
///
///     ➤ Remove 1 app, 1.11GB  Enter confirm, ESC cancel:
enum UninstallPreviewParser {

    /// Fails (returns nil) rather than guessing. A preview is only usable when
    /// mo matched exactly the app the user picked — a fuzzy name can match
    /// several, and showing another app's files under this one's header would
    /// be exactly the mis-attribution this whole change is meant to remove.
    static func parse(_ raw: String, expecting appPath: String, bundleId: String) -> UninstallPreview? {
        let lines = CleanParser.strip(raw)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        // "Matched 1 app(s):" — anything else and we don't know whose files these are.
        guard let matched = lines.compactMap(matchedCount).first, matched == 1 else { return nil }
        guard let blockStart = lines.firstIndex(where: { $0.contains("Files to be removed:") })
        else { return nil }

        var preview = UninstallPreview()
        var seen = Set<String>()

        for line in lines[(blockStart + 1)...] {
            // The confirmation note closes the block; the summary block follows it.
            if line.contains("Enter confirm") || line.hasPrefix("===") { break }
            guard let entry = leftover(from: line, bundleId: bundleId),
                  seen.insert(entry.path).inserted else { continue }
            preview.leftovers.append(entry)
        }

        // The app bundle itself must be in there, or mo matched something else.
        let std = (appPath as NSString).standardizingPath
        guard preview.leftovers.contains(where: { $0.path == std }) else { return nil }

        preview.leftovers.sort { $0.bytes > $1.bytes }
        return preview
    }

    private static func matchedCount(_ line: String) -> Int? {
        guard let range = line.range(of: #"Matched (\d+) app"#, options: .regularExpression),
              let digits = line[range].range(of: #"\d+"#, options: .regularExpression)
        else { return nil }
        return Int(line[range][digits])
    }

    /// One row of the block, or nil for the app header, warnings and blanks.
    private static func leftover(from line: String, bundleId: String) -> UninstallLeftover? {
        // Drop mo's leading status glyph (✓ / ⚠ / ◎ / →) and the space after it.
        var body = line
        while let first = body.first, !first.isASCII || first == " " {
            body.removeFirst()
            body = body.trimmingCharacters(in: .whitespaces)
        }

        // `/Library` items mo will not remove itself: shown, never trashed.
        var reviewOnly = false
        for marker in ["Review only:", "System:"] where body.hasPrefix(marker) {
            reviewOnly = true
            body = String(body.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
        }

        // Only path rows survive; the app header ("Claude , 1.11GB") does not.
        guard body.hasPrefix("/") || body.hasPrefix("~/") else { return nil }

        // mo appends " , <size>" — but a path may itself contain a comma, so the
        // separator is matched with its surrounding spaces, from the right.
        if let sep = body.range(of: " , ", options: .backwards) {
            body = String(body[..<sep.lowerBound])
        }

        let path = ((body.hasPrefix("~/") ? NSHomeDirectory() + body.dropFirst(1) : body)
            as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }

        // Sized locally rather than by parsing mo's display value: some rows
        // carry no size at all, and the app's own figures then stay consistent
        // with what the completion screen reports as freed.
        //
        // mo's own "Review only" / "System:" marker is folded in: whether lumac
        // can remove the path is decided by the Trash guard, and mo marking a
        // path as untouchable is another reason to lock it.
        var item = UninstallLeftover.make(path: path,
                                          bytes: Trash.directorySize(path),
                                          bundleId: bundleId)
        if reviewOnly && !item.locked {
            item.locked = true
            item.selected = false
        }
        return item
    }
}
