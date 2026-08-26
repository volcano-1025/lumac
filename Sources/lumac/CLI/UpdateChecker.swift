import Foundation

/// Checks whether a newer version is available, by comparing the installed
/// version against the latest GitHub release. Only mole is checked — lumac has
/// no release channel yet.
enum UpdateChecker {
    struct Update: Equatable {
        var current: String
        var latest: String
    }

    /// Returns the version pair when mole has an update, or nil when it is
    /// current, not installed, or the network check failed.
    static func mole() async -> Update? {
        guard let current = await MoCLI.shared.version(),
              let latest = await githubLatestTag(owner: "tw93", repo: "Mole") else { return nil }
        return isNewer(latest, than: current) ? Update(current: current, latest: latest) : nil
    }

    // MARK: - GitHub

    /// The latest release tag, normalized (a leading "v"/"V" stripped).
    private static func githubLatestTag(owner: String, repo: String) async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest")
            else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { return nil }

        return tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
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
