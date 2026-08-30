import Foundation

enum CLIError: LocalizedError {
    case notInstalled
    case failed(command: String, status: Int32, output: String)
    case badOutput(String)
    /// A child process was killed after exceeding its time budget (see Brew.run).
    case timedOut(command: String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "没有找到 mo 命令行工具"
        case .failed(let command, let status, let output):
            return "mo \(command) 执行失败（\(status)）\n\(output.prefix(400))"
        case .badOutput(let detail):
            return "无法解析 mo 的输出：\(detail)"
        case .timedOut(let command):
            return "\(command) 超时：网络太慢或无响应，请稍后重试"
        }
    }
}

/// Runs the `mo` binary and hands back parsed results.
///
/// `mo` prints JSON when stdout is not a TTY, which is exactly our situation, so
/// `status` and `history` need no flags. The scan commands still print ANSI text
/// and are parsed in `CleanParser`.
actor MoCLI {
    static let shared = MoCLI()

    /// A GUI app launched from Finder does not inherit the user's shell PATH, so
    /// the usual install locations are searched explicitly before falling back to it.
    private static let searchPaths = [
        "/opt/homebrew/bin/mo",
        "/usr/local/bin/mo",
        NSHomeDirectory() + "/.local/bin/mo",
        NSHomeDirectory() + "/.mole/bin/mo",
    ]

    private var cachedPath: String?

    func binaryPath() throws -> String {
        if let cachedPath { return cachedPath }
        let fm = FileManager.default
        for candidate in Self.searchPaths where fm.isExecutableFile(atPath: candidate) {
            cachedPath = candidate
            return candidate
        }
        if let env = ProcessInfo.processInfo.environment["PATH"] {
            for dir in env.split(separator: ":") {
                let candidate = String(dir) + "/mo"
                if fm.isExecutableFile(atPath: candidate) {
                    cachedPath = candidate
                    return candidate
                }
            }
        }
        throw CLIError.notInstalled
    }

    var isInstalled: Bool { (try? binaryPath()) != nil }

    /// The resolved `mo` path, or nil when it is not installed. For display only.
    func installedPath() -> String? { try? binaryPath() }

    /// The installed mole version, e.g. "1.52.0" from `mo --version`.
    func version() async -> String? {
        guard let output = try? await run(["--version"], allowFailure: true) else { return nil }
        let pattern = #"\d+\.\d+(?:\.\d+)?"#
        guard let range = output.range(of: pattern, options: .regularExpression) else { return nil }
        return String(output[range])
    }

    /// Runs `mo` with the given arguments and returns stdout.
    /// Non-zero exits throw, except where `allowFailure` is set — several `mo`
    /// subcommands report partial success that way when a directory is locked.
    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false) async throws -> String {
        let path = try binaryPath()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardInput = FileHandle.nullDevice

            var environment = ProcessInfo.processInfo.environment
            // Keep the CLI from emitting colour it thinks we can render.
            environment["NO_COLOR"] = "1"
            environment["TERM"] = "dumb"
            process.environment = environment

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // Drain stdout and stderr concurrently. Reading them one after the
            // other deadlocks when the child fills the *other* pipe's 64 KB buffer
            // (e.g. a large `--debug` stderr) and blocks before the first pipe
            // reaches EOF — so stderr is read on its own queue while we read stdout.
            let errQueue = DispatchQueue(label: "app.lumac.mo.stderr")
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

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus != 0 && !allowFailure {
                continuation.resume(throwing: CLIError.failed(
                    command: args.joined(separator: " "),
                    status: process.terminationStatus,
                    output: stderr.isEmpty ? stdout : stderr))
            } else {
                continuation.resume(returning: stdout)
            }
        }
    }

    /// Runs `mo uninstall <name>` to completion, feeding confirmations to its
    /// two prompts ("[y/N]" then "Enter confirm"). Used only for root-owned apps
    /// lumac can't trash as the logged-in user: mo removes them through its own
    /// Touch ID + passwordless sudoers rule, so this reuses that elevation
    /// instead of lumac installing one of its own. mo does its own ~40s leftover
    /// scan, so callers should show progress. Returns combined stdout+stderr;
    /// throws on a non-zero exit. mo trashes by default (recoverable) — no
    /// `--permanent`.
    func uninstallApp(named name: String) async throws -> String {
        let path = try binaryPath()
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["uninstall", name]

            var environment = ProcessInfo.processInfo.environment
            environment["NO_COLOR"] = "1"
            environment["TERM"] = "dumb"
            process.environment = environment

            let stdin = Pipe()
            let out = Pipe()
            let err = Pipe()
            process.standardInput = stdin
            process.standardOutput = out
            process.standardError = err

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
                return
            }

            // "y" clears the [y/N] prompt; the trailing newlines answer the
            // final "Enter confirm". Pre-writing then closing is fine — mo reads
            // each byte as it reaches the matching prompt. Touch ID (if mo asks)
            // is a separate GUI sheet, not stdin.
            if let data = "y\n\n\n".data(using: .utf8) {
                stdin.fileHandleForWriting.write(data)
            }
            try? stdin.fileHandleForWriting.close()

            let errQueue = DispatchQueue(label: "app.lumac.mo.uninstall.stderr")
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

            let stdout = String(data: outData, encoding: .utf8) ?? ""
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            let combined = stdout + (stderr.isEmpty ? "" : "\n" + stderr)

            if process.terminationStatus != 0 {
                continuation.resume(throwing: CLIError.failed(
                    command: "uninstall \(name)",
                    status: process.terminationStatus,
                    output: combined))
            } else {
                continuation.resume(returning: combined)
            }
        }
    }

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    /// `mo status` — the overview page and the menu bar HUD both poll this.
    func status() async throws -> StatusSnapshot {
        let output = try await run(["status"])
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw CLIError.badOutput("status 没有输出")
        }
        do {
            return try decoder.decode(StatusSnapshot.self, from: data)
        } catch {
            throw CLIError.badOutput("status: \(error)")
        }
    }

    /// `mo analyze -json [path]`. Nil path runs the curated overview of the whole
    /// disk; a path lists that directory's children. Sizes are bytes on disk.
    func analyze(path: String? = nil) async throws -> AnalyzeResult {
        var args = ["analyze", "-json"]
        if let path { args.append(path) }
        // A locked subdirectory makes analyze exit non-zero while still printing
        // the JSON it did manage to gather, so partial results are kept.
        let output = try await run(args, allowFailure: true)
        guard let data = output.data(using: .utf8), !data.isEmpty else {
            throw CLIError.badOutput("analyze: 没有输出")
        }
        do {
            return try decoder.decode(AnalyzeResult.self, from: data)
        } catch {
            throw CLIError.badOutput("analyze: \(error)")
        }
    }

    /// `mo optimize --dry-run` — the maintenance steps that would run. Safe.
    func optimizePreview() async throws -> OptimizeResult {
        let stdout = try await run(["optimize", "--dry-run"], allowFailure: true)
        return OptimizeParser.parse(stdout, dryRun: true)
    }

    /// `mo optimize` — actually refresh caches and services. Non-interactive and
    /// self-limiting: tasks that need rights it does not have are skipped, not
    /// prompted, so it never blocks on a password.
    func optimizeExecute() async throws -> OptimizeResult {
        let stdout = try await run(["optimize"], allowFailure: true)
        return OptimizeParser.parse(stdout, dryRun: false)
    }

    /// Dry-run scan for one of the five cleanup commands.
    /// Returns the rows the user then ticks off.
    func scan(_ command: CleanupCommand) async throws -> ScanResult {
        let output = try await run(command.dryRunArguments, allowFailure: true)
        return CleanParser.parse(stdout: output)
    }
}
