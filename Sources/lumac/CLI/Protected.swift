import Foundation

/// Locations lumac must never delete, whatever produced the path.
///
/// `Trash.isDeletable` only ever checked a path's *shape* — how many components
/// it has, which prefix it sits under. That is enough while every path comes
/// from `mo`, which carries ~3000 lines of its own protection rules and simply
/// never lists these. But lumac has delete paths that bypass mo entirely: the
/// trash button in 磁盘分析 (the user can drill straight into `~/.claude/projects`
/// and click it), `InstallerScanner`, and `AppScanner`. Those inherit none of
/// mo's knowledge, so the semantic guard has to live here.
///
/// Deliberately short. This is not an attempt to re-derive mole's rules — it is
/// the backstop for the holes lumac opened itself, covering the classes that are
/// *irreplaceable* (no rebuild, no re-download) or that are actively dangerous
/// to delete from the outside.
enum Protected {

    /// Everything at or under one of these is refused, and so is any directory
    /// that *contains* one — trashing `~/.claude` would take `projects` with it.
    private static var roots: [String] {
        let home = NSHomeDirectory()
        return [
            // AI session records. Months of conversation: the reasoning, the
            // approaches that were rejected, why each change was made. Nothing
            // regenerates these.
            home + "/.claude/projects",
            home + "/.claude/memories",
            home + "/.claude/plans",
            home + "/.claude/skills",
            home + "/.claude/todos",
            home + "/.claude/history.jsonl",
            home + "/.codex/sessions",
            home + "/.codex/history.jsonl",
            home + "/.codex/auth.json",
            home + "/.grok/sessions",
            home + "/.gemini/sessions",

            // Model weights. Tens of gigabytes to re-download, and Ollama stores
            // them as hash-named blocks shared between models — removing one
            // "large" block from the outside silently corrupts another model.
            // Only the tool that owns the reference graph can free these.
            home + "/.ollama/models",
            home + "/.cache/huggingface",
            home + "/.cache/lm-studio",
            home + "/.lmstudio/models",

            // Irreplaceable personal stores.
            home + "/Library/Mail",
            home + "/Library/Messages",
        ]
    }

    /// Refused wherever it appears in the tree. `com.apple.e5rt.e5bundlecache`
    /// sits in a Caches directory and has "cache" in its name, but holds models
    /// the Neural Engine already compiled — deleting it breaks every app using
    /// recognition features until a reboot.
    private static let namedAnywhere: Set<String> = [
        "com.apple.e5rt.e5bundlecache",
    ]

    /// Bundle suffixes that stand for a whole personal library.
    private static let bundleSuffixes = [
        ".photoslibrary", ".musiclibrary", ".tvlibrary",
        ".imovielibrary", ".theatre", ".aplibrary",
    ]

    /// True when `path` must not be deleted. `path` is expected standardized.
    static func covers(_ path: String) -> Bool {
        let clean = (path as NSString).standardizingPath

        if namedAnywhere.contains((clean as NSString).lastPathComponent) { return true }
        if bundleSuffixes.contains(where: { clean.lowercased().hasSuffix($0) }) { return true }

        for root in roots {
            // Inside a protected area, or the protected item itself.
            if clean == root || clean.hasPrefix(root + "/") { return true }
            // An ancestor of one: deleting it would take the protected item too.
            if root.hasPrefix(clean + "/") { return true }
        }
        return false
    }

    /// Why a path was refused, for the row the user sees.
    static let reason = "这个位置受保护（AI 会话记录 / 模型权重 / 个人资料库），lumac 不会删除"
}
