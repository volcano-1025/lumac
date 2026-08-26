import Foundation

/// One row from `mo analyze -json`: a directory or file with its size on disk.
///
/// The overview run (`path == "/"`, `overview == true`) returns a curated mix of
/// big directories and space-saving "insights"; drilling into a path returns the
/// real children of that path. `insight` is only set on the overview.
struct AnalyzeEntry: Decodable, Identifiable, Hashable {
    var name: String
    var path: String
    var size: Int64
    var isDir: Bool
    /// Overview-only flag: a curated space-saving suggestion (old downloads, caches…).
    var insight: Bool?
    /// Files only, when the CLI could stat it. ISO-8601, e.g. "2026-06-19T06:11:28Z".
    var lastAccess: String?

    var id: String { path }
}

/// The decoded result of one `mo analyze -json [path]` invocation.
struct AnalyzeResult: Decodable {
    var path: String
    var overview: Bool
    var entries: [AnalyzeEntry]
    var totalSize: Int64?

    static let empty = AnalyzeResult(path: "/", overview: true, entries: [], totalSize: 0)
}
