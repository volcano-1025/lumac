import Foundation

/// One installed app, enumerated natively from the Applications folders.
///
/// `mo uninstall --list` is not used: it exits early (only ~18 of 58 apps here)
/// and omits the closing `]`, and its per-app `--dry-run` preview takes ~45s.
/// Reading the bundles directly is complete, fast, and yields the last-used date
/// the sort needs.
struct InstalledApp: Identifiable, Hashable {
    var name: String
    var bundleId: String
    var path: String
    var bytes: Int64
    /// From Spotlight's `kMDItemLastUsedDate`; nil when never launched or unindexed.
    var lastUsed: Date?

    var id: String { path }

    var sizeText: String { Size.format(bytes) }

    /// "3 天前 / 2 个月前 / 从未打开" — the secondary sort's human form.
    var lastUsedText: String {
        guard let lastUsed else { return "从未打开" }
        let days = Calendar.current.dateComponents([.day], from: lastUsed, to: Date()).day ?? 0
        if days <= 0 { return "今天用过" }
        if days == 1 { return "昨天用过" }
        if days < 30 { return "\(days) 天前用过" }
        if days < 365 { return "\(days / 30) 个月前用过" }
        return "超过一年没用"
    }
}

/// What a leftover *is*, so each row can say so in the interface instead of
/// showing a bare path.
///
/// This is not decoration. The uninstall page's one job is letting the user
/// judge each item before it goes, and "46.8 MB 需要确认" hides the fact that
/// the items underneath pull in opposite directions: the app's real payload
/// (delete it or the app isn't actually uninstalled), a framework other
/// software may still link against, and the installer's own ledger — which is
/// the very thing that made the rest of the list findable.
enum LeftoverKind: String, Hashable {
    case app              // /Applications/Foo.app
    case container        // ~/Library/Containers/<bid>
    case groupContainer   // ~/Library/Group Containers/group.<bid>
    case appScripts       // ~/Library/Application Scripts/<bid>
    case appSupport       // ~/Library/Application Support/<bid>
    case namedSupport     // ~/Library/Application Support/<显示名> — matched by name
    case cache            // ~/Library/Caches/<bid>
    case preferences      // ~/Library/Preferences/<bid>.plist (+ ByHost)
    case savedState       // ~/Library/Saved Application State
    case webData          // HTTPStorages / WebKit / Cookies
    case logs             // ~/Library/Logs
    case crashReports     // ~/Library/Application Support/CrashReporter
    case systemSupport    // /Library/Application Support/<name>
    case framework        // /Library/Frameworks
    case launchService    // /Library/LaunchDaemons | LaunchAgents | PrivilegedHelperTools
    case receipt          // /private/var/db/receipts
    case other

    /// The short label shown at the head of the row.
    var label: String {
        switch self {
        case .app:            return "应用"
        case .container:      return "容器"
        case .groupContainer: return "群组容器"
        case .appScripts:     return "App 脚本"
        case .appSupport:     return "支持文件"
        case .namedSupport:   return "支持文件"
        case .cache:          return "缓存"
        case .preferences:    return "偏好设置"
        case .savedState:     return "窗口状态"
        case .webData:        return "网站数据"
        case .logs:           return "日志"
        case .crashReports:   return "崩溃报告"
        case .systemSupport:  return "系统级支持文件"
        case .framework:      return "框架"
        case .launchService:  return "后台服务"
        case .receipt:        return "安装记录"
        case .other:          return "其他"
        }
    }

    /// Why this row is where it is. Shown on the 需要确认 rows, where the user
    /// actually has a decision to make.
    var caution: String? {
        switch self {
        case .groupContainer:
            return "同厂商的其他应用可能共用这个目录"
        case .namedSupport:
            return "按应用名匹配到的，请确认不是共用目录"
        case .systemSupport:
            return "常常是应用的主体程序，删掉才算卸干净，但需要管理员权限"
        case .framework:
            return "别的软件可能还链接着它，删除前先确认没有依赖"
        case .launchService:
            return "开机自启的服务，需要管理员权限"
        case .receipt:
            return "macOS 的安装账本，删掉只省几百 KB，却会失去追查残留的依据"
        default:
            return nil
        }
    }

    /// Classified from the path. `bundleId` separates a support folder addressed
    /// by bundle id from one matched only on the app's display name — the
    /// looser of the two, and the one worth a second look.
    static func of(_ path: String, bundleId: String) -> LeftoverKind {
        let home = NSHomeDirectory()
        let leaf = (path as NSString).lastPathComponent

        if path.hasSuffix(".app") { return .app }
        if path.hasPrefix("/private/var/db/receipts/") { return .receipt }
        if path.hasPrefix("/Library/Frameworks/") { return .framework }
        if path.hasPrefix("/Library/LaunchDaemons/")
            || path.hasPrefix("/Library/LaunchAgents/")
            || path.hasPrefix("/Library/PrivilegedHelperTools/") { return .launchService }
        if path.hasPrefix("/Library/Application Support/") { return .systemSupport }
        // Crash / diagnostic reports live under both the user's Library and
        // /Library/Logs/DiagnosticReports.
        if path.contains("/DiagnosticReports/") { return .crashReports }

        func under(_ tail: String) -> Bool { path.hasPrefix(home + "/Library/" + tail) }

        if under("Containers/") { return .container }
        if under("Group Containers/") { return .groupContainer }
        if under("Application Scripts/") { return .appScripts }
        if under("Application Support/CrashReporter/") { return .crashReports }
        if under("Application Support/") {
            // `<bid>` and `<bid>.something` are the app's own; anything else got
            // here through the display name.
            return (leaf == bundleId || leaf.hasPrefix(bundleId + ".")) ? .appSupport : .namedSupport
        }
        if under("Caches/") { return .cache }
        if under("Preferences/") { return .preferences }
        if under("Saved Application State/") { return .savedState }
        if under("HTTPStorages/") || under("WebKit/") || under("Cookies/") { return .webData }
        if under("Logs/") { return .logs }
        return .other
    }
}

/// Which of the two lists a row belongs to.
enum LeftoverTier: Hashable {
    /// Ticked on arrival: unambiguously this app's, and lumac can trash it.
    case auto
    /// Shown unticked: lumac can trash it, but the user should look first.
    case confirm
    /// Shown with a lock: outside what lumac is able to remove at all.
    case locked
}

/// One file or directory that removing an app would delete.
struct UninstallLeftover: Identifiable, Hashable {
    let id = UUID()
    var path: String
    var bytes: Int64
    var kind: LeftoverKind = .other
    /// Ticked rows are the ones that will actually be trashed.
    var selected: Bool = true

    /// Never trashable by lumac: `/Library`, receipts, anything the Trash guard
    /// refuses. Shown for transparency, with the reason, and never ticked.
    var locked: Bool = false

    /// The one place a leftover is built, so the native draft and mo's list are
    /// classified by exactly the same rules.
    static func make(path: String, bytes: Int64, bundleId: String) -> UninstallLeftover {
        var item = UninstallLeftover(
            path: path,
            bytes: bytes,
            kind: LeftoverKind.of(path, bundleId: bundleId),
            selected: false,
            locked: !Trash.isDeletable(path))
        item.selected = item.tier == .auto
        return item
    }

    /// The line under the path. Falls back to the reason it is locked, so a
    /// padlock is never shown without saying why.
    var caution: String? {
        if let reason = kind.caution { return reason }
        return locked ? "lumac 无法删除这一项，需要管理员权限" : nil
    }

    var tier: LeftoverTier {
        if locked { return .locked }
        switch kind {
        // Group containers are shared by a vendor's apps, and a support folder
        // found only by display name may not be this app's at all. Both are
        // removable — they just should not be removed without a glance.
        case .groupContainer, .namedSupport: return .confirm
        default: return .auto
        }
    }
}

/// What removing one app would delete, split into the list that is ticked on
/// arrival and the list the user has to decide about.
struct UninstallPreview {
    var leftovers: [UninstallLeftover] = []

    var auto: [UninstallLeftover] { leftovers.filter { $0.tier == .auto } }
    /// Everything the user has to rule on: the removable-but-check-first rows
    /// and the locked ones, in that order.
    var needsReview: [UninstallLeftover] {
        leftovers.filter { $0.tier == .confirm } + leftovers.filter { $0.tier == .locked }
    }

    /// What pressing the button will actually trash.
    var selectedItems: [UninstallLeftover] { leftovers.filter { $0.selected && !$0.locked } }
    var selectedBytes: Int64 { selectedItems.reduce(0) { $0 + $1.bytes } }

    var isEmpty: Bool { leftovers.isEmpty }

    static func bytes(of items: [UninstallLeftover]) -> Int64 {
        items.reduce(0) { $0 + $1.bytes }
    }
}
