import Foundation

/// A launchd startup entry — the background agents and daemons that run at login
/// or boot. There is no `mo` command for these, so they are read natively from
/// the LaunchAgents / LaunchDaemons folders.
struct LoginItem: Identifiable, Hashable {
    var label: String
    var name: String
    /// The executable it launches, for the secondary line.
    var program: String
    var domain: Domain
    /// Persisted disabled state, from `launchctl print-disabled`.
    var disabled: Bool
    var plistPath: String
    /// The bundle to draw an icon from, when the program lives inside an .app.
    var iconPath: String?

    var id: String { plistPath }

    enum Domain {
        case userAgent      // ~/Library/LaunchAgents — togglable without rights
        case systemAgent    // /Library/LaunchAgents  — needs authorization
        case systemDaemon   // /Library/LaunchDaemons — needs authorization

        var label: String {
            switch self {
            case .userAgent:    return "用户"
            case .systemAgent:  return "系统"
            case .systemDaemon: return "系统服务"
            }
        }
        /// Only user agents can be toggled without elevated rights.
        var togglable: Bool { self == .userAgent }
    }
}

enum LoginScanner {
    private static let launchctl = "/bin/launchctl"

    private static var sources: [(dir: String, domain: LoginItem.Domain)] {
        [(NSHomeDirectory() + "/Library/LaunchAgents", .userAgent),
         ("/Library/LaunchAgents", .systemAgent),
         ("/Library/LaunchDaemons", .systemDaemon)]
    }

    static func scan() -> [LoginItem] {
        let fm = FileManager.default
        let disabled = disabledLabels()
        var items: [LoginItem] = []

        for source in sources {
            guard let files = try? fm.contentsOfDirectory(atPath: source.dir) else { continue }
            for file in files where file.hasSuffix(".plist") {
                let path = source.dir + "/" + file
                guard let plist = NSDictionary(contentsOfFile: path),
                      let label = plist["Label"] as? String else { continue }

                let program = programPath(from: plist)
                items.append(LoginItem(
                    label: label,
                    name: friendlyName(label: label, program: program),
                    program: program,
                    domain: source.domain,
                    disabled: disabled.contains(label),
                    plistPath: path,
                    iconPath: appBundle(containing: program)))
            }
        }
        // User items first (the ones the user can act on), then by name.
        return items.sorted {
            if $0.domain.togglable != $1.domain.togglable { return $0.domain.togglable }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Persists a new enabled/disabled state for a user agent. Takes effect at
    /// the next login; returns false if launchctl reported a failure.
    @discardableResult
    static func setDisabled(_ item: LoginItem, _ disabled: Bool) -> Bool {
        guard item.domain.togglable else { return false }
        let target = "gui/\(getuid())/\(item.label)"
        return run(launchctl, [disabled ? "disable" : "enable", target]) != nil
    }

    // MARK: - Helpers

    /// Labels launchd currently has disabled, from `print-disabled gui/<uid>`.
    private static func disabledLabels() -> Set<String> {
        guard let output = run(launchctl, ["print-disabled", "gui/\(getuid())"]) else { return [] }
        var set = Set<String>()
        for line in output.components(separatedBy: .newlines) {
            // 	"com.foo.bar" => disabled
            guard line.contains("=> disabled") else { continue }
            if let first = line.firstIndex(of: "\""),
               let last = line[line.index(after: first)...].firstIndex(of: "\"") {
                set.insert(String(line[line.index(after: first)..<last]))
            }
        }
        return set
    }

    private static func programPath(from plist: NSDictionary) -> String {
        if let program = plist["Program"] as? String { return program }
        if let args = plist["ProgramArguments"] as? [String], let first = args.first { return first }
        return ""
    }

    /// The .app bundle a program lives inside, for an icon and a nicer name.
    private static func appBundle(containing program: String) -> String? {
        guard let range = program.range(of: ".app/") else {
            return program.hasSuffix(".app") ? program : nil
        }
        return String(program[..<range.upperBound].dropLast())  // ".app/" → ".app"
    }

    /// A readable name: the containing app's, else the last path component of the
    /// program, else the reverse-DNS label's tail.
    private static func friendlyName(label: String, program: String) -> String {
        if let app = appBundle(containing: program) {
            return FileManager.default.displayName(atPath: app)
                .replacingOccurrences(of: ".app", with: "")
        }
        if !program.isEmpty {
            let leaf = (program as NSString).lastPathComponent
            if !leaf.isEmpty { return leaf }
        }
        return label
    }

    /// Runs a tool and returns stdout, or nil on a non-zero exit / launch error.
    private static func run(_ path: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        process.standardOutput = out
        // Discard stderr rather than leaving an unread pipe that could fill its
        // buffer and block launchctl before it finishes writing stdout.
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
