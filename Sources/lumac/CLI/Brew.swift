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
    ///
    /// `force` is the 刷新 button: refresh the index no matter how fresh it is.
    /// The automatic load settles for an hour-old index, so re-opening the page
    /// doesn't re-fetch on every visit.
    static func outdated(force: Bool = false) async throws -> [BrewUpdate] {
        // Metadata plus (at most) an index refresh: the JSON index is ~15 MB,
        // so this gets a much wider budget than the ~2s a warm run takes.
        let output = try await run(["outdated", "--json=v2"], timeout: 180,
                                   refreshIndex: force ? .force : .hourly)
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

    /// The version homebrew-core's formula currently offers for `name` — i.e.
    /// what a `brew upgrade` could actually install right now — or nil if brew
    /// or the formula isn't there.
    ///
    /// Reads the same index 更新页 compares against, so the two can't disagree.
    /// Needed because a GitHub release lands hours before homebrew-core bumps
    /// (mole's formula is `autobump: false` / `bumped_by_upstream`, so upstream
    /// has to open the PR itself), and in that window "用 Homebrew 更新" is a
    /// button that does nothing.
    static func formulaVersion(_ name: String) async -> String? {
        guard let output = try? await run(["info", "--json=v2", name], timeout: 180,
                                          refreshIndex: .hourly),
              let data = output.data(using: .utf8) else { return nil }
        struct Versions: Decodable { var stable: String? }
        struct Formula: Decodable { var versions: Versions }
        struct Envelope: Decodable { var formulae: [Formula] }
        let envelope = try? JSONDecoder().decode(Envelope.self, from: data)
        return envelope?.formulae.first?.versions.stable
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
        // An upgrade downloads and installs a bottle/app, so it needs a much
        // larger budget than the metadata check — big casks can take a while.
        // No index refresh here: install from the same snapshot the list was
        // built on, so the version shown in the row is the version installed.
        return (try? await run(args, timeout: 1800)) != nil
    }

    /// A fast Homebrew mirror. A GUI app launched from Finder/menubar doesn't
    /// inherit the user's shell, so brew defaults to the official API domain
    /// (formulae.brew.sh) — whose 16 MB index download stalls for minutes on a
    /// throttled network and hangs the whole update flow. Routing through a
    /// mirror makes the same fetch ~2s. Only applied when the user hasn't set
    /// their own (e.g. via `launchctl setenv HOMEBREW_API_DOMAIN …`).
    private static let mirrorAPIDomain = "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles/api"
    private static let mirrorBottleDomain = "https://mirrors.tuna.tsinghua.edu.cn/homebrew-bottles"

    /// A curl config that aborts a transfer stuck below 1 KB/s for 30 seconds.
    ///
    /// brew's curl has `--retry` and `--continue-at` but no low-speed limit, so a
    /// connection that goes silent without closing — seen through a TUN proxy
    /// (Egern): ESTABLISHED, zero bytes for 15 minutes, while a fresh request
    /// for the same dmg finished in 6s — hangs until our 1800s timeout. With
    /// this, curl gives up on the dead connection and its own retry resumes the
    /// partial download on a new one. Passed via `HOMEBREW_CURLRC`, which brew
    /// hands to curl as `--config`.
    private static func stallAbortingCurlrc() -> String? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        let dir = support.appendingPathComponent("lumac", isDirectory: true)
        let file = dir.appendingPathComponent("brew.curlrc")
        let contents = "speed-limit = 1024\nspeed-time = 30\n"
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            if (try? String(contentsOf: file, encoding: .utf8)) != contents {
                try contents.write(to: file, atomically: true, encoding: .utf8)
            }
            return file.path
        } catch {
            return nil
        }
    }

    /// Thread-safe one-shot flag: set by the timeout killer, read after the
    /// process exits to distinguish a kill-on-timeout from an ordinary failure.
    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    /// How stale an index `run` will settle for.
    ///
    /// `brew outdated` compares against a cached formula index, never the
    /// network, so with `HOMEBREW_NO_AUTO_UPDATE=1` on every call the index
    /// froze at whatever the user's last terminal `brew` left behind — mole
    /// 1.55.0 shipped and the page kept listing the other seven packages,
    /// because to this brew 1.54.0 *was* the latest. `HOMEBREW_AUTO_UPDATE_SECS`
    /// buys the refresh back without the "check on every single command" cost.
    private enum RefreshIndex {
        /// Never refresh — for commands that should act on the index as-is.
        case off
        /// Refresh if the index is over an hour old.
        case hourly
        /// Refresh unconditionally (the 刷新 button).
        case force

        /// Applied over the inherited environment. The refreshing cases *clear*
        /// `HOMEBREW_NO_AUTO_UPDATE` rather than just setting the interval: a
        /// user who set it globally (`launchctl setenv`) would otherwise keep
        /// the frozen index this whole mechanism exists to thaw.
        func apply(to env: inout [String: String]) {
            switch self {
            case .off:
                env["HOMEBREW_NO_AUTO_UPDATE"] = "1"
            case .hourly, .force:
                env["HOMEBREW_NO_AUTO_UPDATE"] = nil
                env["HOMEBREW_AUTO_UPDATE_SECS"] = self == .force ? "1" : "3600"
            }
        }
    }

    /// Runs `brew` and returns stdout, throwing on a non-zero exit. `timeout`
    /// caps the wall-clock wait: on expiry the process and its curl children are
    /// killed so the pipe reads unblock and we throw `.timedOut` instead of
    /// spinning forever.
    @discardableResult
    private static func run(_ args: [String], timeout: TimeInterval,
                            refreshIndex: RefreshIndex = .off) async throws -> String {
        guard let path else { throw CLIError.notInstalled }
        return try await withCheckedThrowingContinuation { continuation in
            // Draining the pipes and waiting blocks the thread for the whole run
            // — up to the 1800s upgrade budget. On the Swift cooperative pool
            // that would pin one of a handful of threads for half an hour, so
            // the work goes to a background queue and the caller suspends here.
            DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.standardInput = FileHandle.nullDevice
            // A no-TTY sudo prompt then fails fast instead of hanging.
            var env = ProcessInfo.processInfo.environment
            refreshIndex.apply(to: &env)
            env["HOMEBREW_NO_COLOR"] = "1"
            // Auto-update's progress chatter goes to stderr, which we only read
            // on failure — but silence it anyway so a failure's message is brew's.
            env["HOMEBREW_NO_ENV_HINTS"] = "1"
            if env["HOMEBREW_API_DOMAIN"] == nil { env["HOMEBREW_API_DOMAIN"] = mirrorAPIDomain }
            if env["HOMEBREW_BOTTLE_DOMAIN"] == nil { env["HOMEBREW_BOTTLE_DOMAIN"] = mirrorBottleDomain }
            if env["HOMEBREW_CURLRC"] == nil, let curlrc = stallAbortingCurlrc() { env["HOMEBREW_CURLRC"] = curlrc }
            process.environment = env

            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            do { try process.run() } catch {
                continuation.resume(throwing: error); return
            }

            // Backstop against a wedged brew (e.g. a network fetch that slips
            // past the mirror). pkill the curl children *first* — while they're
            // still parented to brew — so killing brew doesn't reparent them to
            // launchd and leave a pipe writer open, keeping our read blocked.
            let didTimeout = Flag()
            let pid = process.processIdentifier
            let killer = DispatchWorkItem {
                didTimeout.set()
                let pk = Process()
                pk.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
                pk.arguments = ["-9", "-P", "\(pid)"]
                try? pk.run(); pk.waitUntilExit()
                kill(pid, SIGKILL)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

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
            killer.cancel()

            if didTimeout.isSet {
                continuation.resume(throwing: CLIError.timedOut(
                    command: "brew " + args.joined(separator: " ")))
            } else if process.terminationStatus != 0 {
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
}
