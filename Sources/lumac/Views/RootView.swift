import SwiftUI
import AppKit

struct RootView: View {
    @Environment(AppState.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            NavBar()
            ContentArea()
        }
        .frame(minWidth: 940, minHeight: 620)
        .background(Palette.content)
        .background(WindowConfigurator())
        .preferredColorScheme(app.theme.colorScheme)
        .onAppear {
            // Whenever the window is (re)shown, restore the Dock icon and give
            // the menu bar a way to reopen a closed window.
            app.reopenWindow = { openWindow(id: "main") }
            NSApp.setActivationPolicy(.regular)
        }
        .task {
            app.startPolling()
            app.checkForUpdatesOnce()
        }
        .alert("检查更新", isPresented: $app.showingManualCheck) {
            if app.manualChecks.contains(where: { $0.name == "mole" && $0.isUpdatable }), Brew.isInstalled {
                Button("用 Homebrew 更新 mole") { app.updateMole() }
            }
            if app.manualChecks.contains(where: { $0.name == "lumac" && $0.isUpdatable }) {
                Button("下载 lumac 新版") {
                    if let url = URL(string: UpdateChecker.lumacReleasesURL) { NSWorkspace.shared.open(url) }
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(app.manualChecks.map(\.line).joined(separator: "\n"))
        }
        .alert("mole 有新版本", isPresented: $app.showingMoleUpdate, presenting: app.moleUpdate) { update in
            if Brew.isInstalled {
                Button("用 Homebrew 更新") { app.updateMole() }
            }
            Button("知道了", role: .cancel) {}
        } message: { update in
            Text("mole 命令行工具有新版本：\(update.current) → \(update.latest)。"
                 + (Brew.isInstalled ? "\n可直接用 Homebrew 更新，或在终端运行 mo update。"
                                     : "\n在终端运行 mo update 即可更新。"))
        }
        .sheet(isPresented: Binding(
            get: { !app.didOnboard },
            set: { if !$0 { app.didOnboard = true } })
        ) {
            OnboardingView()
        }
        .sheet(isPresented: $app.showingSettings) {
            SettingsView()
        }
    }
}

// MARK: - Navigation layer

/// The floating glass navigation bar. One capsule holds the brand button and the
/// segmented tabs, per the two-layer rule: the bar is glass, the content is not.
private struct NavBar: View {
    var body: some View {
        NavPill()
            .frame(maxWidth: .infinity)
            .frame(height: 62)
    }
}

/// Each tab reports its frame here so one capsule can be positioned over the
/// selected tab and animated between positions.
private struct TabFrameKey: PreferenceKey {
    static let defaultValue: [TopTab: CGRect] = [:]
    static func reduce(value: inout [TopTab: CGRect], nextValue: () -> [TopTab: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct NavPill: View {
    @Environment(AppState.self) private var app
    @State private var frames: [TopTab: CGRect] = [:]

    private var selectedTab: TopTab? {
        TopTab.allCases.first { $0.children.contains(app.screen) }
    }

    var body: some View {
        HStack(spacing: 4) {
            BrandButton()
            // A hair of space so the brand reads as its own control inside the pill.
            Spacer().frame(width: 3)
            ForEach(TopTab.allCases) { tab in
                TabSegment(tab: tab)
            }
        }
        // One capsule, positioned over the selected tab. Because only its frame
        // and offset change when the selection moves, `.animation` slides it
        // smoothly from one tab to the next instead of blinking.
        .background(alignment: .topLeading) {
            if let tab = selectedTab, let rect = frames[tab] {
                Capsule()
                    .fill(Palette.selBg)
                    .frame(width: rect.width, height: rect.height)
                    .offset(x: rect.minX, y: rect.minY)
            }
        }
        .coordinateSpace(name: "navpill")
        .onPreferenceChange(TabFrameKey.self) { frames = $0 }
        .padding(5)
        .glassEffect(.regular, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
        .animation(.spring(response: 0.34, dampingFraction: 0.8), value: app.screen)
    }
}

/// The mole button. Opens the app-level menu: settings, history, update check.
private struct BrandButton: View {
    @Environment(AppState.self) private var app
    @State private var hovering = false

    var body: some View {
        Menu {
            Button { app.showingSettings = true } label: {
                Label("设置", systemImage: "gearshape")
            }
            Button { app.screen = .history } label: {
                Label("操作记录", systemImage: "clock.arrow.circlepath")
            }
            Divider()
            Button { app.checkNow() } label: {
                Label("检查更新", systemImage: "arrow.down.circle")
            }
        } label: {
            Circle()
                .fill(Palette.selBg)
                .frame(width: 32, height: 32)
                .overlay(
                    MoonCrescent(color: Palette.selFg)
                        .frame(width: 17, height: 17)
                        .rotationEffect(.degrees(-18))
                )
                .overlay(
                    Circle().strokeBorder(Palette.fgDecoration(hovering ? 0.22 : 0), lineWidth: 1)
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { hovering = $0 }
        .help("lumac · 设置与操作记录")
    }
}

/// One tab. Navigates on click; lights up while its screen (or, for 软件, any
/// of its switcher screens) is showing.
private struct TabSegment: View {
    @Environment(AppState.self) private var app
    let tab: TopTab
    @State private var hovering = false

    private var selected: Bool { tab.children.contains(app.screen) }

    var body: some View {
        Button {
            // Clicking the section you are already in is a no-op, so returning
            // to 软件 keeps whichever sub-screen you left it on.
            if !selected { app.screen = tab.primary }
        } label: {
            Text(tab.title)
                .font(.system(size: 13, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.selFg : (hovering ? Palette.fg : Palette.fg(0.62)))
                .padding(.horizontal, 15)
                .frame(height: 32)
                // The selected fill is the shared sliding capsule in NavPill; a
                // tab only paints its own hover tint.
                .background {
                    if !selected && hovering {
                        Capsule().fill(Palette.fgDecoration(0.07))
                    }
                }
                // Report this tab's frame so the sliding capsule can sit on it.
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(
                            key: TabFrameKey.self,
                            value: [tab: geo.frame(in: .named("navpill"))])
                    }
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Content layer

/// Content layer — opaque enough to separate from the glass above it, with the
/// slight translucency the handoff asks for so the wallpaper tints it.
private struct ContentArea: View {
    @Environment(AppState.self) private var app

    var body: some View {
        // No page title, and no second `Palette.content` fill here: the window
        // already paints that layer once in RootView, and painting it again
        // made this region a shade darker than the nav band — the "divider" the
        // eye caught was that step, not an actual line.
        VStack(spacing: 0) {
            if app.didOnboard && !app.fdaGranted {
                FDABanner()
            }
            screenBody
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(.top, 12)
    }

    @ViewBuilder
    private var screenBody: some View {
        // 软件 owns three sub-screens reached from an in-page switcher, so it is
        // handled before the generic cleanup/placeholder routing.
        if TopTab.owning(app.screen) == .software {
            SoftwareSection()
        } else if app.screen == .optimize {
            // 系统优化 runs maintenance steps rather than trashing paths, so it
            // has its own view instead of the shared cleanup flow.
            OptimizeView()
        } else if let command = app.screen.cleanupCommand {
            CleanupView(command: command)
        } else {
            switch app.screen {
            case .status:  StatusView()
            case .analyze: AnalyzeView()
            case .history: HistoryView()
            default:       PlaceholderView(screen: app.screen)
            }
        }
    }
}

// MARK: - 软件 section

/// The 软件 destination: a segmented switcher over 卸载 / 更新 / 启动项, with the
/// chosen sub-screen below it. The page header above already names the active
/// sub-screen, so the switcher only has to move between them.
private struct SoftwareSection: View {
    @Environment(AppState.self) private var app
    private let screens = TopTab.software.children

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SoftwareSwitcher(screens: screens, current: app.screen) { app.screen = $0 }
                Spacer()
            }
            .padding(.horizontal, Metrics.contentPadding)
            .padding(.bottom, 14)

            child
        }
    }

    @ViewBuilder
    private var child: some View {
        // 卸载应用 / 启动项 / 应用更新 have their own flows; 项目产物 (purge) uses
        // the shared cleanup flow.
        if app.screen == .uninstall {
            UninstallView()
        } else if app.screen == .login {
            LoginView()
        } else if app.screen == .updates {
            UpdatesView()
        } else if let command = app.screen.cleanupCommand {
            CleanupView(command: command)
        } else {
            PlaceholderView(screen: app.screen)
        }
    }
}

/// Content-layer segmented control. Mirrors the top bar's selected-pill styling
/// at a smaller size; it is not glass, since it sits on the content layer.
private struct SoftwareSwitcher: View {
    let screens: [Screen]
    let current: Screen
    let select: (Screen) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(screens) { screen in
                Segment(screen: screen, on: screen == current) { select(screen) }
            }
        }
        .padding(3)
        .background(Palette.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
    }

    private struct Segment: View {
        let screen: Screen
        let on: Bool
        let action: () -> Void
        @State private var hovering = false

        var body: some View {
            Button(action: action) {
                HStack(spacing: 6) {
                    Image(systemName: screen.symbol)
                        .font(.system(size: 11))
                    Text(Self.short(screen))
                        .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                }
                .foregroundStyle(on ? Palette.selFg : (hovering ? Palette.fg : Palette.fg(0.7)))
                .padding(.horizontal, 13)
                .frame(height: 28)
                .background {
                    if on {
                        Capsule().fill(Palette.selBg)
                    } else if hovering {
                        Capsule().fill(Palette.fgDecoration(0.06))
                    }
                }
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }
        }

        /// Short labels, so the switcher stays compact next to the page header.
        static func short(_ screen: Screen) -> String {
            switch screen {
            case .uninstall: return "卸载"
            case .updates:   return "更新"
            case .login:     return "启动项"
            case .purge:     return "项目产物"
            default:         return screen.title
            }
        }
    }
}

/// Slim reminder shown when Full Disk Access is missing — scans are incomplete
/// without it. Sits above the page content, out of the way but always visible.
private struct FDABanner: View {
    @Environment(AppState.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .font(.system(size: 12))
                .foregroundStyle(Palette.danger)
            Text("未开启完全磁盘访问，部分缓存扫描不到。")
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.82))
            Spacer()
            Button("去开启") { FullDiskAccess.openSettings() }
                .buttonStyle(.plain)
                .font(Typo.aux.weight(.medium))
                .foregroundStyle(Palette.accentText)
            Button { app.refreshFDA() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Palette.fg(0.58))
            .help("重新检查")
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.vertical, 8)
        .background(Palette.danger.opacity(0.08))
        .overlay(alignment: .bottom) { Hairline() }
    }
}

/// Stand-in for screens that are not built yet.
struct PlaceholderView: View {
    var screen: Screen

    var body: some View {
        VStack(spacing: 12) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.panel)
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: screen.symbol)
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.fg(0.58))
                )
            Text("\(screen.title) · 尚未实现")
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Reaches the hosting `NSWindow` to drop the title-bar separator line macOS
/// draws under the (hidden) title bar. There is no SwiftUI modifier for it.
private struct WindowConfigurator: NSViewRepresentable {
    @Environment(AppState.self) private var app

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titlebarSeparatorStyle = .none
            // Remember the window so the menu bar can raise it, and so the
            // close observer knows which window is the main one.
            window.identifier = NSUserInterfaceItemIdentifier("main")
            app.mainWindow = window
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            nsView.window?.titlebarSeparatorStyle = .none
        }
    }
}

enum LumacVersion {
    /// Bare version, e.g. "0.1" — compared against GitHub release tags.
    static let number = "0.1"
    static let display = "v" + number
}
