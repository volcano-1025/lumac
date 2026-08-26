import SwiftUI
import Observation
import AppKit

/// Every destination the app can show. The horizontal bar and the brand menu
/// route to these; grouping lives in `TopTab` and `BrandMenu`, not here.
///
/// 安装包清理 is not its own screen — it is folded into 深度清理 as one
/// unchecked row, so it lives in `CleanupModel`, not here.
enum Screen: String, CaseIterable, Identifiable {
    case status, clean, uninstall, updates, login, purge, optimize, analyze, history, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:    return "概览"
        case .clean:     return "深度清理"
        case .uninstall: return "卸载应用"
        case .updates:   return "应用更新"
        case .login:     return "启动项"
        case .purge:     return "项目产物"
        case .optimize:  return "系统优化"
        case .analyze:   return "磁盘分析"
        case .history:   return "操作记录"
        case .settings:  return "设置"
        }
    }

    var subtitle: String {
        switch self {
        case .status:    return "这台 Mac 现在的状态 · 每 2 秒自动刷新"
        case .clean:     return "缓存、日志、浏览器残留、下载的安装包与已卸载应用的遗留文件"
        case .uninstall: return "连同启动项、偏好设置与隐藏残留一起移除"
        case .updates:   return "检查这台 Mac 上的应用有没有新版本，可直接在 lumac 内更新"
        case .login:     return "开机自动启动的应用与后台服务"
        case .purge:     return "清理项目里的 node_modules、target、dist 等构建产物"
        case .optimize:  return "重建系统数据库、刷新服务与索引，不删除个人文件"
        case .analyze:   return "看看空间都去哪了，删除的内容会移入废纸篓"
        case .history:   return "每一次清理都有记录，可以查看和还原"
        case .settings:  return "白名单、扫描范围、授权与更新"
        }
    }

    /// SF Symbols, per the handoff's icon mapping table.
    var symbol: String {
        switch self {
        case .status:    return "gauge.medium"
        case .clean:     return "trash"
        case .uninstall: return "square.grid.2x2"
        case .updates:   return "arrow.down.circle"
        case .login:     return "power"
        case .purge:     return "folder.badge.gearshape"
        case .optimize:  return "slider.horizontal.3"
        case .analyze:   return "chart.pie"
        case .history:   return "clock.arrow.circlepath"
        case .settings:  return "gearshape"
        }
    }

    var cleanupCommand: CleanupCommand? { CleanupCommand(rawValue: rawValue) }
}

/// A segment in the horizontal navigation bar. Every segment navigates directly
/// on click — none drops a menu. 软件 lands on a section whose own in-page
/// switcher moves between its child screens; `children` drives that switcher and
/// tells the bar which segment to light.
enum TopTab: String, CaseIterable, Identifiable {
    case status, clean, software, optimize, analyze

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status:   return "状态"
        case .clean:    return "清理"
        case .software: return "软件"
        case .optimize: return "优化"
        case .analyze:  return "分析"
        }
    }

    /// Screens this segment owns, primary first. Only 软件 has more than one.
    var children: [Screen] {
        switch self {
        case .status:   return [.status]
        case .clean:    return [.clean]
        case .software: return [.uninstall, .updates, .login, .purge]
        case .optimize: return [.optimize]
        case .analyze:  return [.analyze]
        }
    }

    var primary: Screen { children[0] }

    /// The segment owning a given screen, so the bar can light the right one
    /// even when the screen was reached from the 软件 switcher.
    static func owning(_ screen: Screen) -> TopTab? {
        allCases.first { $0.children.contains(screen) }
    }
}

enum ThemeMode: String, CaseIterable {
    case auto, light, dark

    var label: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

@MainActor
@Observable
final class AppState {
    /// The menu bar item lives outside the SwiftUI scene graph and needs the
    /// same state the window uses, so there is one shared instance.
    static let shared = AppState()

    var screen: Screen = .status

    /// Drives the "检查更新" alert raised from the brand menu. There is no real
    /// update feed yet, so this only reports the running version.
    var showingUpdateCheck = false

    /// 设置 opens as a centered sheet rather than a left-aligned content page.
    var showingSettings = false

    // Window lifecycle. Closing the window drops lumac to a menu-bar-only
    // accessory (no Dock icon); reopening from the menu bar brings it back.
    weak var mainWindow: NSWindow?
    /// Set by the window scene so the menu bar can reopen a closed window.
    var reopenWindow: (() -> Void)?

    /// Reopens the main window and restores the Dock icon.
    func openMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else {
            reopenWindow?()
        }
    }

    /// A mole update found on launch, and whether its alert is showing.
    var moleUpdate: UpdateChecker.Update?
    var showingMoleUpdate = false
    private var didCheckUpdates = false

    /// Checks for a mole update once per launch (after onboarding), popping an
    /// alert if one is found. Network failures are silent.
    func checkForUpdatesOnce() {
        guard !didCheckUpdates, didOnboard else { return }
        didCheckUpdates = true
        Task {
            if let update = await UpdateChecker.mole() {
                self.moleUpdate = update
                self.showingMoleUpdate = true
            }
        }
    }

    /// Upgrades mole via Homebrew, then re-checks so the alert reflects reality.
    func updateMole() {
        guard let update = moleUpdate else { return }
        Task {
            let item = BrewUpdate(name: "mole", kind: .formula,
                                  current: update.current, latest: update.latest)
            _ = await Brew.upgrade(item)
            self.moleUpdate = await UpdateChecker.mole()
        }
    }

    // Live metrics, refreshed on a 2 second cadence while a window is open.
    var status: StatusSnapshot?
    /// Read from IOKit rather than the CLI, which reports -1 on Apple Silicon.
    var gpu = GPUSample()
    var statusError: String?
    var cliMissing = false

    /// Network rate history, accumulated locally — `mo status` only reports the
    /// current sample, and the overview's bar chart needs a rolling window.
    var rxHistory: [Double] = []
    var txHistory: [Double] = []
    private let historyLength = 40

    /// Full process table. `mo status` caps `top_processes` at five, so the
    /// table is sourced from `ps` directly.
    var processes: [ProcessRow] = []

    // Preferences, persisted in UserDefaults.
    var theme: ThemeMode {
        didSet { UserDefaults.standard.set(theme.rawValue, forKey: "theme") }
    }
    var requireConfirm: Bool {
        didSet { UserDefaults.standard.set(requireConfirm, forKey: "requireConfirm") }
    }
    var showSummaryBar: Bool {
        didSet { UserDefaults.standard.set(showSummaryBar, forKey: "showSummaryBar") }
    }
    /// When on, destructive actions (clean / purge / uninstall) ask for Touch ID
    /// or the login password first. Only offered when the device supports it.
    var requireBiometric: Bool {
        didSet { UserDefaults.standard.set(requireBiometric, forKey: "requireBiometric") }
    }

    /// Whether the first-run guide has been completed. Drives the onboarding sheet.
    var didOnboard: Bool {
        didSet { UserDefaults.standard.set(didOnboard, forKey: "didOnboard") }
    }
    /// Live Full Disk Access state, refreshed on the slow poll and when the
    /// onboarding / settings ask. Not persisted — it can change out from under us.
    var fdaGranted = FullDiskAccess.granted

    /// Runs the Touch ID gate when the pref is on; otherwise passes straight
    /// through. Returns whether the caller may proceed.
    func confirmBiometric(_ reason: String) async -> Bool {
        guard requireBiometric else { return true }
        return await Biometric.confirm(reason: reason)
    }

    /// One state machine per cleanup page, kept alive across navigation so a
    /// scan survives switching away and back.
    ///
    /// Built once in `init` rather than on demand: creating one lazily from a
    /// view's body would mutate observed state while that body is being
    /// evaluated, which makes the resulting update order undefined.
    private let cleanupModels: [CleanupCommand: CleanupModel]

    func cleanup(for command: CleanupCommand) -> CleanupModel {
        // Every case is populated in `init`, so this is total.
        cleanupModels[command]!
    }

    /// 磁盘分析 state, kept alive across navigation so a drilled-in location
    /// survives leaving the tab and coming back.
    let analyzeModel = AnalyzeModel()

    /// 卸载应用 state, kept alive so the installed-app list survives navigation.
    let uninstallModel = UninstallModel()

    /// 系统优化 state, kept alive so the preview/result survives navigation.
    let optimizeModel = OptimizeModel()

    /// 启动项 state, kept alive so the launchd list survives navigation.
    let loginModel = LoginModel()

    /// 应用更新 state (Homebrew), kept alive so a check survives navigation.
    let updatesModel = UpdatesModel()

    /// 扫描路径 / 白名单 config, backed by the mole config files.
    let configModel = ConfigModel()

    private var pollTask: Task<Void, Never>?

    /// Previous native network sample, for computing throughput across polls.
    private var prevNet: [String: NetworkStats.Counters] = [:]
    private var prevNetTime: Date?
    /// Previous CPU tick sample, for computing load across polls.
    private var prevCPUTicks: SystemStats.CPUTicks?
    /// Last `mo status` result. Supplies the fields only the CLI provides
    /// (health score, hardware, uptime, battery, bluetooth, thermal); the live
    /// metrics on top of it are measured natively every second.
    private var cliSnapshot: StatusSnapshot?

    init() {
        cleanupModels = Dictionary(uniqueKeysWithValues:
            CleanupCommand.allCases.map { ($0, CleanupModel(command: $0)) })

        let defaults = UserDefaults.standard
        theme = ThemeMode(rawValue: defaults.string(forKey: "theme") ?? "auto") ?? .auto
        requireConfirm = defaults.object(forKey: "requireConfirm") as? Bool ?? true
        showSummaryBar = defaults.object(forKey: "showSummaryBar") as? Bool ?? true
        requireBiometric = defaults.object(forKey: "requireBiometric") as? Bool ?? false
        didOnboard = defaults.object(forKey: "didOnboard") as? Bool ?? false
    }

    /// Re-reads Full Disk Access. Cheap, and the answer changes only when the
    /// user flips it in System Settings, so callers poll it rather than observe.
    func refreshFDA() { fdaGranted = FullDiskAccess.granted }

    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                // The CLI-only fields change slowly, so `mo status` and the full
                // process list run every other tick; the native metrics refresh
                // every second.
                if tick % 2 == 0 { await self?.slowRefresh() }
                self?.fastRefresh()
                tick &+= 1
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    /// `mo status` for the fields only it provides, plus the process list.
    private func slowRefresh() async {
        do {
            cliSnapshot = try await MoCLI.shared.status()
            statusError = nil
            cliMissing = false
        } catch CLIError.notInstalled {
            cliMissing = true
            statusError = nil
        } catch {
            statusError = error.localizedDescription
        }
        processes = await ProcessLister.list()
        fdaGranted = FullDiskAccess.granted
    }

    /// Native CPU / memory / disk / network / GPU, merged onto the last CLI
    /// snapshot and published. Cheap syscalls, run every second.
    private func fastRefresh() {
        var snap = cliSnapshot ?? StatusSnapshot()

        if let ticks = SystemStats.cpuTicks() {
            if let prev = prevCPUTicks, let usage = SystemStats.cpuUsage(from: prev, to: ticks) {
                var cpu = snap.cpu ?? StatusSnapshot.CPU()
                cpu.usage = usage
                snap.cpu = cpu
            }
            prevCPUTicks = ticks
        }

        if let mem = SystemStats.memory() {
            var m = snap.memory ?? StatusSnapshot.Memory()
            m.used = mem.used; m.total = mem.total; m.usedPercent = mem.percent
            snap.memory = m
        }

        if let d = SystemStats.disk() {
            var boot = snap.primaryDisk ?? StatusSnapshot.Disk()
            boot.mount = "/"; boot.used = d.used; boot.total = d.total; boot.usedPercent = d.percent
            var disks = snap.disks ?? []
            if let idx = disks.firstIndex(where: { $0.mount == "/" }) { disks[idx] = boot }
            else { disks.insert(boot, at: 0) }
            snap.disks = disks
        }

        if let native = nativeInterfaces() { snap.network = native }

        gpu = GPUStats.sample()
        status = snap

        if let interface = snap.primaryInterface {
            append(&rxHistory, interface.rxRateMbs ?? 0)
            append(&txHistory, interface.txRateMbs ?? 0)
        }
    }

    private func append(_ series: inout [Double], _ value: Double) {
        series.append(value)
        if series.count > historyLength { series.removeFirst(series.count - historyLength) }
    }

    /// Interface throughput measured from the kernel's byte counters between two
    /// polls, in MiB/s to match the rest of the UI. Nil on the first sample,
    /// when there is no baseline to diff against yet.
    private func nativeInterfaces() -> [StatusSnapshot.Interface]? {
        let now = Date()
        let sample = NetworkStats.sample()
        defer { prevNet = sample; prevNetTime = now }

        guard let prevTime = prevNetTime, !prevNet.isEmpty else { return nil }
        let elapsed = now.timeIntervalSince(prevTime)
        guard elapsed > 0.1 else { return nil }

        var interfaces: [StatusSnapshot.Interface] = []
        for (name, cur) in sample {
            guard let prev = prevNet[name] else { continue }
            // `&-` so a single 32-bit counter wrap still yields a correct delta.
            let rxBytes = Double(cur.rx &- prev.rx)
            let txBytes = Double(cur.tx &- prev.tx)
            interfaces.append(StatusSnapshot.Interface(
                name: name,
                rxRateMbs: rxBytes / elapsed / 1_048_576,
                txRateMbs: txBytes / elapsed / 1_048_576,
                ip: nil))
        }
        return interfaces.isEmpty ? nil : interfaces
    }

    /// Processes rolled up per application, largest memory footprint first.
    /// Backs the menu bar HUD.
    var appsByMemory: [AppUsage] {
        ProcessLister.merge(processes)
            .filter { ProcessLister.isListed($0) }
            .sorted { $0.memoryBytes > $1.memoryBytes }
    }

}
