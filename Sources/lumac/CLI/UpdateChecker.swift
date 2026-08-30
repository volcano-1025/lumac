import Foundation

/// Checks whether a newer version is available, by comparing the installed
/// version against the latest GitHub release. Covers both lumac (this app, repo
/// `volcano-1025/lumac`) and the mole CLI (`tw93/Mole`).
enum UpdateChecker {
    struct Update: Equatable {
        var current: String
        var latest: String
    }

    /// The result for one component. Distinguishes "already latest" from "not
    /// installed" / "no releases yet" / "network failed", so the UI can say what
    /// actually happened rather than silently showing nothing.
    enum Outcome: Equatable {
        case upToDate(current: String)
        case updatable(Update)
        case notInstalled     // mole binary not found
        case noReleases       // repo has no published release to compare against
        case failed           // network / parse error
    }

    /// One component's check, paired with its display name so a single line can
    /// be rendered for lumac and for mole from the same code.
    struct Check: Equatable, Identifiable {
        var name: String
        var outcome: Outcome
        var id: String { name }

        /// One-line, user-facing summary (no trailing period).
        var line: String {
            switch outcome {
            case .upToDate(let v):  return "\(name) 已是最新版本（v\(v)）"
            case .updatable(let u): return "\(name) 有新版本：\(u.current) → \(u.latest)"
            case .notInstalled:     return "没有检测到 \(name)"
            case .noReleases:       return "\(name) 暂无发布版本"
            case .failed:           return "\(name) 检查失败，请检查网络"
            }
        }

        var isUpdatable: Bool { if case .updatable = outcome { return true }; return false }
        var update: Update? { if case .updatable(let u) = outcome { return u }; return nil }
    }

    /// The GitHub releases page for lumac — offered as the "download" target when
    /// lumac itself has an update, since it isn't distributed through Homebrew.
    static let lumacReleasesURL = "https://github.com/volcano-1025/lumac/releases"

    /// Both checks, run concurrently. Order is stable: lumac first, then mole.
    static func all() async -> [Check] {
        async let lumac = lumacOutcome()
        async let mole = moleOutcome()
        return [Check(name: "lumac", outcome: await lumac),
                Check(name: "mole", outcome: await mole)]
    }

    /// lumac vs its own GitHub releases. 404 (no releases) is reported as
    /// `.noReleases` rather than a failure, since none exist yet.
    static func lumacOutcome() async -> Outcome {
        let current = LumacVersion.number
        switch await latestTag(owner: "volcano-1025", repo: "lumac") {
        case .tag(let latest):
            return isNewer(latest, than: current)
                ? .updatable(Update(current: current, latest: latest))
                : .upToDate(current: current)
        case .noReleases: return .noReleases
        case .error:      return .failed
        }
    }

    /// mole vs its GitHub releases. Reports `.notInstalled` when `mo` is absent.
    static func moleOutcome() async -> Outcome {
        guard let current = await MoCLI.shared.version() else { return .notInstalled }
        switch await latestTag(owner: "tw93", repo: "Mole") {
        case .tag(let latest):
            return isNewer(latest, than: current)
                ? .updatable(Update(current: current, latest: latest))
                : .upToDate(current: current)
        case .noReleases, .error: return .failed
        }
    }

    /// Returns the mole version pair when an update exists, else nil. Used by the
    /// silent launch check; `all()` backs the manual, message-bearing check.
    static func mole() async -> Update? {
        if case .updatable(let u) = await moleOutcome() { return u }
        return nil
    }

    // MARK: - GitHub

    private enum TagFetch { case tag(String), noReleases, error }

    /// The latest release tag, normalized (a leading "v"/"V" stripped). A 404
    /// means the repo simply has no releases yet — kept distinct from a network
    /// error so callers can word it accurately.
    private static func latestTag(owner: String, repo: String) async -> TagFetch {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
            else { return .error }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request) else { return .error }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { return .noReleases }
        guard code == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return .error }

        return .tag(tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV ")))
    }

    // MARK: - Version compare

    /// Numeric, component-wise semver comparison. "1.53.0" > "1.52.0".
    static func isNewer(_ a: String, than b: String) -> Bool {
        let lhs = components(a)
        let rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    private static func components(_ version: String) -> [Int] {
        version.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }
}
