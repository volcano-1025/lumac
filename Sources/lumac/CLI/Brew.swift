import Foundation

/// One outdated Homebrew package.
struct BrewUpdate: Identifiable, Hashable {
    var name: String
    var kind: Kind
    var current: String
    var latest: String
    /// For casks, the installed `.app` bundle, so the row can show its icon.
    var appPath: String?

    var id: String { kind.rawValue + "/" + name }

    enum Kind: String {
        case cask, formula
        /// Casks are GUI apps; formulae are command-line tools.
        var label: String { self == .cask ? "应用 · Homebrew" : "命令行 · Homebrew" }
    }
}

/// Thin wrapper over the `brew` binary. Homebrew is the one update source this
/// machine has (no `mas`, no Sparkle integration), so 应用更新 covers only what
/// brew manages.
enum Brew {
    private static let searchPaths = [
        "/opt/homebrew/bin/brew",
        "/usr/local/bin/brew",
    ]

    static var path: String? {
        searchPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isInstalled: Bool { path != nil }

    /// `brew outdated --json=v2` → casks first (the apps), then formulae.
    static func outdated() async throws -> [BrewUpdate] {
        let output = try await run(["outdated", "--json=v2"])
        guard let data = output.data(using: .utf8), !data.isEmpty else { return [] }

        struct Entry: Decodable {
            var name: String
            var installed_versions: [String]
            var current_version: String
        }
        struct Envelope: Decodable {
            var formulae: [Entry]
            var casks: [Entry]
        }

        let env = try JSONDecoder().decode(Envelope.self, from: data)
        let apps = appIndex()
        func map(_ entries: [Entry], _ kind: BrewUpdate.Kind) -> [BrewUpdate] {
            entries.map {
                BrewUpdate(name: $0.name, kind: kind,
                           current: $0.installed_versions.first ?? "—",
                           latest: $0.current_version,
                           appPath: kind == .cask ? apps[normalize($0.name)] : nil)
            }
        }
        return map(env.casks, .cask) + map(env.formulae, .formula)
    }

    /// Maps a normalized app name to its bundle path, so a cask token like
    /// `linearmouse` can find `LinearMouse.app` for its icon.
    private static func appIndex() -> [String: String] {
        var map: [String: String] = [:]
        let dirs = ["/Applications", "/Applications/Utilities", NSHomeDirectory() + "/Applications"]
        for dir in dirs {
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                map[normalize(String(entry.dropLast(4)))] = dir + "/" + entry
            }
        }
        return map
    }

    /// Lowercased, letters and digits only — collapses hyphens and spaces so a
    /// cask token and its app's display name compare equal.
    private static func normalize(_ s: String) -> String {
        s.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// `brew upgrade [--cask] <name>`. Returns false on failure — including the
    /// clean, immediate failure when a cask needs a password brew cannot get in
    /// this non-interactive context.
    @discardableResult
    static func upgrade(_ item: BrewUpdate) async -> Bool {
        var args = ["upgrade"]
        if item.kind == .cask { args.append("--cask") }
        args.append(item.name)
        return (try? await run(args)) != nil
    }

    /// Runs `brew` and returns stdout, throwing on a non-zero exit.
    @discardableResult
    private static func run(_ args: [String]) async throws -> String {
        guard let path else { throw CLIError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            // A no-TTY sudo prompt then fails fast instead of hanging.
            var env = ProcessInfo.processInfo.environment
            env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            env["HOMEBREW_NO_COLOR"] = "1"
            process.environment = env

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                continuation.resume(throwing: error); return
            }
            // Drain both pipes concurrently — `brew upgrade` is verbose on both,
            // and reading them one at a time deadlocks when the unread pipe's
            // 64 KB buffer fills before the one being read reaches EOF.
            let errQueue = DispatchQueue(label: "app.lumac.brew.stderr")
            let group = DispatchGroup()
            var errData = Data()
            group.enter()
            errQueue.async {
                errData = err.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            let outData = out.fileHandleForReading.readDataToEndOfFile()
            group.wait()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let msg = String(data: errData, encoding: .utf8) ?? ""
                continuation.resume(throwing: CLIError.failed(
                    command: "brew " + args.joined(separator: " "),
                    status: process.terminationStatus, output: msg))
            } else {
                continuation.resume(returning: String(data: outData, encoding: .utf8) ?? "")
            }
        }
    }
}
