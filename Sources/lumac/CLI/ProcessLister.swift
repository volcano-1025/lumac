import Foundation
import AppKit
import Darwin

struct ProcessRow: Identifiable, Hashable {
    var pid: Int32
    var name: String
    /// Full executable path, kept so processes can be traced back to the
    /// application bundle that owns them.
    var path: String
    var cpu: Double
    var memoryPercent: Double
    var memoryBytes: Int64

    var id: Int32 { pid }
}

/// Several processes rolled up into the application a user recognises.
///
/// Browsers and Electron apps run a main process plus one helper per tab or
/// window, all of which live inside the same bundle. Listing them separately
/// fills the HUD with repeated names, so they are merged on their bundle.
struct AppUsage: Identifiable, Hashable {
    /// Bundle path when the processes belong to an app, otherwise the
    /// executable path.
    var id: String
    var name: String
    var cpu: Double
    var memoryBytes: Int64
    var processCount: Int
    /// Nil for daemons and other executables outside an app bundle.
    var bundlePath: String?
    /// SF Symbol name for a friendly service group that has no app icon.
    var symbol: String?
}

/// Lists running processes for the overview's table and the menu bar HUD.
///
/// `mo status` returns only the top five processes, and the overview needs a
/// full scrollable table, so this reads `ps` directly.
///
/// Note: there is no energy-impact column here. Activity Monitor's "Energy"
/// figure comes from a private API; `ps` and `mo` both stop at CPU and memory.
enum ProcessLister {

    /// Returns every process. Merging by application needs the full list —
    /// truncating to the top CPU consumers would understate the memory of an
    /// app whose helpers are individually idle but collectively large.
    static func list(limit: Int = .max) async -> [ProcessRow] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: run(limit: limit))
            }
        }
    }

    private static func run(limit: Int) -> [ProcessRow] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        // rss is in kilobytes; comm gives the executable name without arguments.
        process.arguments = ["-Aro", "pid=,pcpu=,pmem=,rss=,comm="]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard let text = String(data: data, encoding: .utf8) else { return [] }

        var rows: [ProcessRow] = []
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            // Split off the four leading numeric fields; whatever remains is the
            // command path, which may itself contain spaces.
            let fields = trimmed.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
            guard fields.count == 5,
                  let pid = Int32(fields[0]),
                  let cpu = Double(fields[1]),
                  let mem = Double(fields[2]),
                  let rssKB = Int64(fields[3]) else { continue }

            let path = String(fields[4])
            // Prefer the phys_footprint (what Activity Monitor shows) over `ps`'s
            // RSS, which double-counts shared framework pages and overstates every
            // app's memory. Falls back to RSS for processes we cannot query.
            let bytes = physFootprint(pid) ?? rssKB * 1024
            rows.append(ProcessRow(
                pid: pid,
                name: displayName(for: path),
                path: path,
                cpu: cpu,
                memoryPercent: mem,
                memoryBytes: bytes))

            if rows.count >= limit { break }
        }
        return rows
    }

    /// Per-process physical footprint via `proc_pid_rusage`. Nil for processes
    /// owned by other users (root daemons), where it is not permitted.
    private static func physFootprint(_ pid: Int32) -> Int64? {
        var usage = rusage_info_current()
        let rc = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0)
            }
        }
        guard rc == 0, usage.ri_phys_footprint > 0 else { return nil }
        return Int64(usage.ri_phys_footprint)
    }

    /// The list is titled "内存占用最高的应用", so it shows applications. Background
    /// daemons and helpers (mdworker, WebContent, storeaccountd …) are not apps
    /// and are left out — Stats and Activity Monitor's app view do the same.
    /// A few single, large, recognisable system processes are still worth
    /// surfacing, so they are allowed through by name.
    private static let listedSystemProcesses: [String: String] = [
        "WindowServer": "display",       // name : SF Symbol
    ]

    /// Whether a merged entry belongs in the applications list: a real app (not
    /// a background agent), or one of the allow-listed system processes.
    @MainActor
    static func isListed(_ usage: AppUsage) -> Bool {
        if let bundle = usage.bundlePath { return !isSystemAgent(bundle: bundle) }
        return listedSystemProcesses[usage.name] != nil
    }

    private static var agentCache: [String: Bool] = [:]

    /// A background agent or system menu-extra rather than a user application —
    /// WindowManager, PowerChime, Notification Center and the like. Read from the
    /// bundle's own Info.plist: `LSBackgroundOnly` marks a pure background app;
    /// `LSUIElement` marks an agent, which for a user's own menu-bar app (Stats,
    /// Shottr) is fine to show, so that only hides the ones shipped inside
    /// `/System`.
    @MainActor
    private static func isSystemAgent(bundle path: String) -> Bool {
        if let cached = agentCache[path] { return cached }
        var agent = false
        if let info = Bundle(path: path)?.infoDictionary {
            func flag(_ key: String) -> Bool {
                if let b = info[key] as? Bool { return b }
                if let s = info[key] as? String { return s == "1" || s.lowercased() == "true" }
                return false
            }
            agent = flag("LSBackgroundOnly") || (flag("LSUIElement") && path.hasPrefix("/System/"))
        }
        agentCache[path] = agent
        return agent
    }

    /// Turns "/Applications/Foo.app/Contents/MacOS/Foo" into "Foo".
    private static func displayName(for command: String) -> String {
        let last = command.components(separatedBy: "/").last ?? command
        return last.isEmpty ? command : last
    }

    /// Ends a process the way the ✕ button in the table promises: ask politely
    /// first. No escalation to SIGKILL — a stuck process is the user's call.
    static func terminate(pid: Int32) {
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.terminate()
        } else {
            kill(pid, SIGTERM)
        }
    }

    /// Ends a merged application. The row stands for every process rolled into
    /// the bundle, so quitting the running app (which takes its helpers with it)
    /// is preferred; a non-bundled executable falls back to SIGTERM on each pid
    /// that rolled into it.
    @MainActor
    static func terminate(_ usage: AppUsage, in rows: [ProcessRow]) {
        if let bundlePath = usage.bundlePath {
            let target = URL(fileURLWithPath: bundlePath).standardizedFileURL
            let running = NSWorkspace.shared.runningApplications.filter {
                $0.bundleURL?.standardizedFileURL == target
            }
            if !running.isEmpty {
                running.forEach { $0.terminate() }
                return
            }
        }
        for row in rows where (appBundle(for: row.path) ?? row.path) == usage.id {
            terminate(pid: row.pid)
        }
    }
}

extension ProcessLister {

    /// The outermost `.app` a path sits inside.
    ///
    /// Chrome's renderers live in a nested helper bundle inside the browser's
    /// own bundle, so the first `.app` component from the left is taken — that
    /// is the application the user thinks of, and the one whose icon to show.
    static func appBundle(for path: String) -> String? {
        if let range = path.range(of: ".app/") {
            return String(path[path.startIndex..<range.lowerBound]) + ".app"
        }
        return path.hasSuffix(".app") ? path : nil
    }

    /// Rolls a process list up into per-application totals.
    ///
    /// Main-actor isolated because it consults the bundle-name cache.
    @MainActor
    static func merge(_ rows: [ProcessRow]) -> [AppUsage] {
        var byKey: [String: AppUsage] = [:]

        for row in rows {
            let bundle = appBundle(for: row.path)
            let key = bundle ?? row.path
            if var existing = byKey[key] {
                existing.cpu += row.cpu
                existing.memoryBytes += row.memoryBytes
                existing.processCount += 1
                byKey[key] = existing
            } else {
                byKey[key] = AppUsage(
                    id: key,
                    name: bundle.map(displayName(forBundle:)) ?? row.name,
                    cpu: row.cpu,
                    memoryBytes: row.memoryBytes,
                    processCount: 1,
                    bundlePath: bundle,
                    symbol: bundle == nil ? listedSystemProcesses[row.name] : nil)
            }
        }
        return Array(byKey.values)
    }

    private static var nameCache: [String: String] = [:]

    /// The localized name the user sees in Finder — 访达, 备忘录, Safari浏览器 —
    /// which is exactly what Activity Monitor and Stats display. Falls back to
    /// the bundle's own name only when Finder gives nothing.
    @MainActor
    private static func displayName(forBundle path: String) -> String {
        if let cached = nameCache[path] { return cached }

        var name = FileManager.default.displayName(atPath: path)
        if name.hasSuffix(".app") { name = String(name.dropLast(4)) }
        if name.isEmpty {
            name = (Bundle(path: path)?.infoDictionary?["CFBundleName"] as? String) ?? path
        }

        nameCache[path] = name
        return name
    }
}
