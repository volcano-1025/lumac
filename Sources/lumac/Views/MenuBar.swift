import SwiftUI
import AppKit

/// The always-on menu bar item.
///
/// Built on `NSStatusItem` rather than SwiftUI's `MenuBarExtra`: it shows a
/// coloured memory-usage percentage next to two lines of live transfer rates.
/// `MenuBarExtra` renders only simple labels reliably and does not track
/// observable changes in its label, which a per-second monitor needs.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let app: AppState
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var itemView: StatusItemView?

    init(app: AppState) {
        self.app = app
        super.init()
        install()
        observeStatus()
    }

    private func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item.button else { return }

        let view = StatusItemView(frame: .zero)
        view.onClick = { [weak self] in self?.togglePopover() }
        view.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            view.topAnchor.constraint(equalTo: button.topAnchor),
            view.bottomAnchor.constraint(equalTo: button.bottomAnchor),
        ])
        item.length = view.intrinsicContentSize.width

        self.itemView = view
        self.statusItem = item
        refreshItem()
    }

    /// Pushes new numbers into the status item whenever the poll lands.
    ///
    /// The item is plain AppKit, so it cannot pick up `@Observable` changes on
    /// its own; the tracking closure re-arms itself after each change.
    private func observeStatus() {
        // `app` is read out first so the tracking closure doesn't implicitly
        // capture self strongly alongside the weak capture in `onChange`.
        let app = self.app
        withObservationTracking {
            _ = app.status
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refreshItem()
                self?.observeStatus()
            }
        }
    }

    private func refreshItem() {
        guard let itemView else { return }
        let interface = app.status?.primaryInterface
        itemView.update(
            ram: app.status?.memory?.usedPercent ?? 0,
            down: interface?.rxRateMbs ?? 0,
            up: interface?.txRateMbs ?? 0)
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }

        let popover = self.popover ?? makePopover()
        self.popover = popover
        // Lets the poll loop resume `mo status` and the process list, which it
        // skips while nothing but the menu bar item is on screen.
        app.hudVisible = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        // Bring the HUD forward without activating the whole app, so clicking
        // the menu bar does not raise the main window.
        popover.contentViewController?.view.window?.makeKey()
    }

    private func makePopover() -> NSPopover {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        popover.contentViewController = NSHostingController(
            rootView: MenuBarHUD().environment(app))
        popover.contentSize = NSSize(width: Metrics.hudWidth, height: 420)
        return popover
    }

    func popoverDidClose(_ notification: Notification) {
        app.hudVisible = false
    }
}

/// The 296pt HUD behind the menu bar item.
struct MenuBarHUD: View {
    @Environment(AppState.self) private var app
    /// Which app row currently shows its ✕. At most one, so tapping another row
    /// puts the last one away.
    @State private var armedApp: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("健康评分")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.fg)
                Spacer()
                Text("\(app.status?.healthScore ?? 0)")
                    .font(Typo.mono(20, .semibold))
                    .foregroundStyle(Palette.accentText)
            }

            VStack(spacing: 7) {
                HUDMetric(label: "CPU", ratio: (app.status?.cpu?.usage ?? 0) / 100)
                HUDMetric(label: "内存", ratio: (app.status?.memory?.usedPercent ?? 0) / 100)
                HUDMetric(label: "磁盘", ratio: (app.status?.primaryDisk?.usedPercent ?? 0) / 100)
            }

            Hairline()

            Text("内存占用最高的应用")
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))

            VStack(spacing: 0) {
                ForEach(app.appsByMemory.prefix(12)) { usage in
                    HUDAppRow(
                        usage: usage,
                        armed: armedApp == usage.id,
                        onTap: {
                            withAnimation(.easeOut(duration: 0.15)) {
                                armedApp = (armedApp == usage.id) ? nil : usage.id
                            }
                        },
                        onKill: {
                            ProcessLister.terminate(usage, in: app.processes)
                            withAnimation { armedApp = nil }
                        })
                }
            }

            Hairline()

            HStack {
                Button("打开 lumac") {
                    app.openMainWindow()
                }
                .buttonStyle(.plain)
                .font(Typo.aux)
                .foregroundStyle(Palette.accentText)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .buttonStyle(.plain)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
            }
        }
        .padding(16)
        .frame(width: Metrics.hudWidth)
        .task { app.startPolling() }
        // Auto-collapse the ✕ five seconds after it is armed. `.task(id:)`
        // cancels and restarts whenever the armed row changes.
        .task(id: armedApp) {
            guard armedApp != nil else { return }
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            withAnimation { armedApp = nil }
        }
    }
}

private struct HUDMetric: View {
    var label: String
    var ratio: Double

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
                .frame(width: 30, alignment: .leading)
            MeterBar(value: ratio, height: 3)
            Text(String(format: "%.0f%%", ratio * 100))
                .font(Typo.mono(10))
                .foregroundStyle(Palette.fg(0.82))
                .frame(width: 32, alignment: .trailing)
        }
    }
}

/// One merged application in the HUD list.
///
/// Tapping the row arms it: a ✕ appears ahead of the icon, and tapping that ends
/// the application. Arming is owned by the HUD, so only one row shows its ✕ at a
/// time and it auto-collapses after five seconds.
private struct HUDAppRow: View {
    var usage: AppUsage
    var armed: Bool
    var onTap: () -> Void
    var onKill: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            if armed {
                Button(action: onKill) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.danger)
                        .frame(width: 15, height: 15)
                }
                .buttonStyle(.plain)
                .help("结束 \(usage.name)")
                .transition(.opacity)
            }

            Group {
                if let icon = AppIcons.icon(forBundle: usage.bundlePath) {
                    icon.resizable()
                } else {
                    Image(systemName: usage.symbol ?? "gearshape")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Palette.fg(usage.symbol == nil ? 0.45 : 0.62))
                        .padding(1)
                }
            }
            .frame(width: 15, height: 15)

            Text(usage.name)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.82))
                .lineLimit(1)
                .truncationMode(.middle)

            // Only worth saying when it stands for more than one process.
            if usage.processCount > 1 {
                Text("\(usage.processCount)")
                    .font(Typo.mono(9))
                    .foregroundStyle(Palette.fg(0.45))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Palette.fgDecoration(0.07), in: Capsule())
            }

            Spacer(minLength: 8)

            Text(Size.format(usage.memoryBytes))
                .font(Typo.mono(10))
                .foregroundStyle(Palette.fg(0.7))
        }
        .padding(.vertical, 3.5)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}
