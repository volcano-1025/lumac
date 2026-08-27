import Foundation

/// Reads and writes mole's plaintext config files directly.
///
/// `mo purge --paths` and `mo clean --whitelist` are interactive TUI editors that
/// block without a terminal, so lumac edits the underlying files instead. Both
/// are simple: `#` comment lines, then one entry per line (paths may use `~`).
enum MoleConfig {
    static var dir: String { NSHomeDirectory() + "/.config/mole" }
    static var purgePathsFile: String { dir + "/purge_paths" }
    static var whitelistFile: String { dir + "/whitelist" }

    private static let purgeHeader = [
        "Mole Purge Paths - Auto-discovered project directories",
        "Edit this file to customize, or run: mo purge --paths",
        "Add one path per line (supports ~ for home directory)",
    ]
    private static let whitelistHeader = [
        "Mole Whitelist - paths to protect from cleaning",
        "One entry per line (supports ~ for home directory)",
    ]

    /// Entry lines only — comments and blanks stripped.
    static func entries(of file: String) -> [String] {
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else { return [] }
        return text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    static func readPurgePaths() -> [String] { entries(of: purgePathsFile) }
    static func readWhitelist() -> [String] { entries(of: whitelistFile) }

    /// Adds `~/.Trash` to mole's whitelist so `mo clean` stops scanning it.
    /// lumac surfaces the Trash through its own "empty trash" action, and having
    /// mo re-scan the Trash on every cleanup was pure waste. Idempotent: writes
    /// only when the entry is missing, preserving the user's other entries.
    /// Returns true when it actually wrote.
    @discardableResult
    static func ensureTrashWhitelisted() -> Bool {
        let entry = "~/.Trash"
        var current = readWhitelist()
        guard !current.contains(entry) else { return false }
        current.append(entry)
        return writeWhitelist(current)
    }

    @discardableResult
    static func writePurgePaths(_ lines: [String]) -> Bool {
        write(purgePathsFile, lines: lines, header: purgeHeader)
    }

    @discardableResult
    static func writeWhitelist(_ lines: [String]) -> Bool {
        write(whitelistFile, lines: lines, header: whitelistHeader)
    }

    /// Writes the header comment, a blank line, then the entries. Deduplicated,
    /// order preserved.
    private static func write(_ file: String, lines: [String], header: [String]) -> Bool {
        var seen = Set<String>()
        let unique = lines
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }

        let text = (header.map { "# \($0)" } + [""] + unique).joined(separator: "\n") + "\n"

        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        do {
            try text.write(toFile: file, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false
        }
    }

    /// Turns an absolute path under the home directory into a `~`-relative one,
    /// matching how mole writes these files.
    static func tildify(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
