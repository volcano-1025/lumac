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

/// Holds the running child so a cancelled Swift task can actually stop it.
///
/// Without this, cancelling the preview (the user goes back to the list, or
/// picks another app) only cancelled the `Task` — mo kept scanning the whole
/// disk to completion, so clicking through a few apps left several full scans
/// running at once.
final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var wasCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    /// Registers a freshly launched process, killing it immediately if the task
    /// was already cancelled during launch.
    func adopt(_ process: Process) {
        lock.lock()
        if cancelled { lock.unlock(); Self.terminate(process); return }
        self.process = process
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p { Self.terminate(p) }
    }

    /// Kills without marking the run as cancelled — used by the timeout and by
    /// the early stop, which both want the output collected so far.
    func kill() {
        lock.lock(); let p = process; lock.unlock()
        if let p { Self.terminate(p) }
    }

    /// mo is a bash script that spawns children; killing only the script would
    /// leave them holding the pipe open and our read blocked, so the process
    /// group goes first.
    private static func terminate(_ process: Process) {
        guard process.isRunning else { return }
        let pid = process.processIdentifier
        let pk = Process()
        pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pk.arguments = ["-9", "-P", "\(pid)"]
        try? pk.run(); pk.waitUntilExit()
        Darwin.kill(pid, SIGKILL)
    }
}

/// The stages of a `mo uninstall --dry-run` that are actually observable in its
/// output. Measured on this machine for one app: banner at 0.2s, match at 2.5s,
/// the leftover list at 25.6s — so the scan is one long silent stretch and the
/// bar has to be driven by elapsed time between these markers, not invented
/// percentages between them.
enum MoScanPhase: Equatable {
    case starting     // "DRY RUN MODE" banner
    case matching     // matched the app, leftover scan begins
    case listing      // "Files to be removed:" — the scan is done

    init?(line: String) {
        if line.contains("DRY RUN MODE") { self = .starting; return }
        if line.contains("Matched") && line.contains("app(s)") { self = .matching; return }
        if line.contains("Files to be removed") { self = .listing; return }
        return nil
    }

    /// Shown on the progress control. Nil while mo is merely starting up —
    /// there is nothing to tell the user in the first fraction of a second, and
    /// a label that appears only to be replaced reads as a stutter.
    var label: String? {
        switch self {
        case .starting: return nil
        case .matching: return "正在扫描残留…"
        case .listing:  return "正在整理清单…"
        }
    }

    /// Where the bar sits when the stage begins. The gap between `.matching`
    /// and `.listing` is filled by elapsed time, since mo says nothing in it.
    var floor: Double {
        switch self {
        case .starting: return 0.02
        case .matching: return 0.10
        case .listing:  return 0.94
        }
    }
}

/// One-shot thread-safe flag: set by a timeout killer, read after the process
/// exits to tell a kill-on-timeout from an ordinary failure.
final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// What a `mo uninstall <name>` run reported, read out of its summary block.
///
/// The exit status carries almost nothing: `uninstall.sh` ends the direct-name
/// path with a bare `return 0`, so a declined confirmation, a denied admin
/// prompt and a completed removal all exit 0 — only "no matching application"
/// exits non-zero (and `uninstallApp` already throws on that). The wording is
/// equally treacherous: mo titles the block "Uninstall complete" even when
/// `success_count == 0`, which is why the caller decides success by looking at
/// the bundle on disk and uses this only to word the failure.
///
/// Strings verified against mole 1.53.0 (`libexec/bin/uninstall.sh`,
/// `libexec/lib/uninstall/batch.sh`).
enum MoUninstallReport: Equatable {
    /// "Removed 1 app, freed 6.9MB: Shottr" — printed only when at least one
    /// app really came off.
    case removed
    /// "Uninstall incomplete" + "Failed: <names> <reason>", reason carried along.
    case failed(String)
    /// "No applications were uninstalled." — under an "Uninstall complete" title.
    case nothingRemoved
    /// "Aborted." at the first prompt, or ESC at the second: no summary at all.
    case cancelled
    /// mo asked for admin rights and was refused.
    case adminDenied
    /// "Uninstall dry run complete" — lumac never passes --dry-run, so this
    /// means mo picked the flag up from the environment.
    case dryRun
    case unrecognized

    static func parse(_ raw: String) -> MoUninstallReport {
        // mo honours NO_COLOR, but still emits cursor/erase codes (\u{1B}[2J\u{1B}[H).
        let lines = CleanParser.strip(raw)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        func any(_ needle: String) -> Bool { lines.contains { $0.contains(needle) } }

        if lines.contains("Aborted.") { return .cancelled }
        if any("Admin access denied") { return .adminDenied }
        if any("Uninstall dry run complete") { return .dryRun }

        if any("Uninstall incomplete") {
            let reason = lines.first { $0.contains("Failed:") }.map { line -> String in
                guard let mark = line.range(of: "Failed:") else { return line }
                return String(line[mark.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
            return .failed(reason ?? "")
        }
        if any("No applications were uninstalled.") { return .nothingRemoved }

        // The summary's success line, and the only trustworthy positive marker
        // in the text — the title is printed for a zero-removal run too.
        if lines.contains(where: {
            $0.range(of: #"^Removed \d+ apps?\b"#, options: .regularExpression) != nil
        }) { return .removed }

        return .unrecognized
    }

    /// User-facing explanation, or nil when mo reported a real removal.
    var message: String? {
        switch self {
        case .removed:        return nil
        case .failed(let reason):
            return reason.isEmpty ? "mo 没能删掉这个应用。" : "mo 没能删掉这个应用：\(reason)"
        case .nothingRemoved: return "mo 没有删除任何应用（可能名称没对上）。"
        case .cancelled:      return "提权删除被取消了，没有任何改动。"
        case .adminDenied:    return "管理员授权被拒绝，应用没有删除。"
        case .dryRun:         return "mo 以预演模式运行，没有真正删除（检查 MOLE_DRY_RUN 环境变量）。"
        case .unrecognized:   return "mo 没有报告删除结果，应用可能仍在原处。"
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
            // Spawning, draining and waiting all block the calling thread for as
            // long as the command runs — tens of seconds for a clean scan. Doing
            // that on the actor's executor would pin a cooperative-pool thread
            // and queue every other MoCLI call behind it (the 2s status poll
            // included), so the work is handed to a background queue and the
            // actor suspends here instead.
            DispatchQueue.global(qos: .userInitiated).async {
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
    }

    /// Runs a `mo uninstall` invocation, feeding both of its confirmation
    /// prompts and streaming stdout back as it arrives.
    ///
    /// The prompts, verified against mole 1.53.0: `uninstall.sh:1628` reads a
    /// whole line ("Proceed with uninstallation? [y/N] "), then
    /// `batch.sh:1795` reads a single character ("Enter confirm, ESC cancel"),
    /// where an empty read also counts as confirm. So "y\n\n\n" clears both.
    ///
    /// `onLine` sees each complete stdout line as it is printed — mo emits real
    /// phase markers, which is the only progress signal available. `stopWhen`
    /// ends the run early: a dry run has printed everything worth reading by
    /// the time it reaches the second prompt, and measured on this machine it
    /// then spends another 20s of a 46s run doing nothing observable.
    ///
    /// Returns stdout and stderr combined; throws on a non-zero exit (in
    /// practice "no matching application") or on the timeout. Cancelling the
    /// calling task kills the process instead of leaving it to finish.
    private func runUninstall(
        _ args: [String],
        timeout: TimeInterval,
        onLine: (@Sendable (String) -> Void)? = nil,
        stopWhen: (@Sendable (String) -> Bool)? = nil
    ) async throws -> String {
        let path = try binaryPath()
        let label = args.joined(separator: " ")
        let box = ProcessBox()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Off the actor's executor: mo rescans the disk for leftovers on
                // every invocation, far too long to hold either the actor or a
                // cooperative-pool thread.
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: path)
                    process.arguments = args

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
                    // Registering after launch; if the task was cancelled while
                    // we were starting, `adopt` kills it straight away.
                    box.adopt(process)

                    if let data = "y\n\n\n".data(using: .utf8) {
                        stdin.fileHandleForWriting.write(data)
                    }
                    try? stdin.fileHandleForWriting.close()

                    let didTimeout = TimeoutFlag()
                    let killer = DispatchWorkItem {
                        didTimeout.set()
                        box.kill()
                    }
                    DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

                    let errQueue = DispatchQueue(label: "app.lumac.mo.uninstall.stderr")
                    let group = DispatchGroup()
                    var errData = Data()
                    group.enter()
                    errQueue.async {
                        errData = err.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    // Read stdout incrementally rather than to EOF, so lines can
                    // be reported while mo is still working.
                    var outData = Data()
                    var pending = Data()   // bytes not yet forming a whole line
                    var stoppedEarly = false
                    let handle = out.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }          // EOF
                        outData.append(chunk)
                        pending.append(chunk)

                        while let nl = pending.firstIndex(of: 0x0A) {
                            let lineData = pending[pending.startIndex..<nl]
                            pending = pending[pending.index(after: nl)...]
                            if let line = String(data: lineData, encoding: .utf8) {
                                onLine?(line)
                            }
                        }
                        // The final prompt is written without a newline, so the
                        // stop check runs against the raw buffer too.
                        if let stopWhen,
                           let tail = String(data: outData, encoding: .utf8),
                           stopWhen(tail) {
                            stoppedEarly = true
                            box.kill()
                            break
                        }
                    }

                    group.wait()
                    process.waitUntilExit()
                    killer.cancel()

                    let stdout = String(data: outData, encoding: .utf8) ?? ""
                    let stderr = String(data: errData, encoding: .utf8) ?? ""
                    let combined = stdout + (stderr.isEmpty ? "" : "\n" + stderr)

                    if box.wasCancelled {
                        continuation.resume(throwing: CancellationError())
                    } else if didTimeout.isSet {
                        continuation.resume(throwing: CLIError.timedOut(command: "mo " + label))
                    } else if !stoppedEarly && process.terminationStatus != 0 {
                        continuation.resume(throwing: CLIError.failed(
                            command: label,
                            status: process.terminationStatus,
                            output: combined))
                    } else {
                        continuation.resume(returning: combined)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// `mo uninstall <name>` — the real thing. Used only for root-owned apps
    /// lumac can't trash as the logged-in user: mo removes them through its own
    /// Touch ID + passwordless sudoers rule, so this reuses that elevation
    /// instead of lumac installing one of its own. mo trashes by default
    /// (recoverable) — no `--permanent`. Never stops early: everything that
    /// matters happens *after* the confirmation.
    func uninstallApp(named name: String) async throws -> String {
        try await runUninstall(["uninstall", name], timeout: 300)
    }

    /// `mo uninstall --dry-run <name>` — the leftover list, with nothing
    /// removed. This is the authoritative answer to "what belongs to this app":
    /// mole carries ~3000 lines of ownership and protection rules
    /// (`app_protection*.sh`, `bundle_resolver.sh`) that a bundle-id and
    /// display-name sweep cannot reproduce. lumac's native `AppScanner` stays
    /// as the instant first draft and the fallback when this is unavailable.
    ///
    /// `onPhase` receives the run's observable stages, for the progress bar.
    func uninstallPreview(
        named name: String,
        onPhase: (@Sendable (MoScanPhase) -> Void)? = nil
    ) async throws -> String {
        try await runUninstall(
            ["uninstall", "--dry-run", name],
            timeout: 180,
            onLine: { line in
                if let phase = MoScanPhase(line: line) { onPhase?(phase) }
            },
            // Everything the parser needs is printed before this prompt; the
            // rest of the run is a dry-run no-op that costs ~20 more seconds.
            stopWhen: { $0.contains("Enter confirm") })
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
}
