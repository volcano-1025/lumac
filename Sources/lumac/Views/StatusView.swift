import SwiftUI

/// 概览 — driven by `mo status` on a 2 second poll.
struct StatusView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        if app.cliMissing {
            CLIMissingView()
        } else if app.status == nil {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 12) {
                // 健康 fills the left column; to its right, one aligned 3×2 grid:
                //   网络  CPU  GPU
                //   电池  内存 磁盘
                // Every grid card is a fixed height, and 健康 is exactly two of
                // them tall, so the whole block has one clean top and bottom.
                HStack(alignment: .top, spacing: 12) {
                    HealthCard()
                        .frame(width: Metrics.dashLeftColumn, height: Metrics.dashGridHeight)
                        .clipped()
                    DashboardGrid()
                }
                ProcessTable()
            }
            .padding(.horizontal, Metrics.contentPadding)
            .padding(.bottom, Metrics.contentPadding)
        }
    }
}

private struct HealthCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let status = app.status
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "健康评分", trailing: status?.healthScoreMsg)
                HStack(alignment: .center, spacing: 14) {
                    Ring(value: Double(status?.healthScore ?? 0) / 100,
                         size: 74, lineWidth: 7,
                         tint: Palette.selBg)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(status?.healthScore ?? 0)")
                            .font(Typo.mono(34, .semibold))
                            .foregroundStyle(Palette.accentText)
                        Text("满分 100")
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                    }
                }
                Hairline()
                VStack(alignment: .leading, spacing: 5) {
                    InfoRow(label: "机型", value: status?.hardware?.model)
                    InfoRow(label: "芯片", value: status?.hardware?.cpuModel)
                    InfoRow(label: "内存", value: status?.hardware?.totalRam)
                    InfoRow(label: "系统", value: status?.hardware?.osVersion)
                    InfoRow(label: "已运行", value: status?.uptime)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxHeight: .infinity)
    }
}

private struct InfoRow: View {
    var label: String
    var value: String?

    var body: some View {
        HStack {
            Text(label)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
            Spacer(minLength: 8)
            Text(value ?? "—")
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.82))
        }
    }
}

/// The aligned 3×2 grid to the right of 健康:
///   网络  CPU  GPU
///   电池  内存 磁盘
private struct DashboardGrid: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let status = app.status
        let memory = status?.memory
        let disk = status?.primaryDisk

        Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                NetworkCard().modifier(GridCell())
                MetricCard(
                    label: "CPU",
                    value: String(format: "%.0f%%", status?.cpu?.usage ?? 0),
                    ratio: (status?.cpu?.usage ?? 0) / 100,
                    caption: coreCaption(status?.cpu)).modifier(GridCell())
                MetricCard(
                    label: "GPU",
                    value: app.gpu.utilization.map { String(format: "%.0f%%", $0) } ?? "—",
                    ratio: (app.gpu.utilization ?? 0) / 100,
                    caption: gpuCaption(status?.gpu?.first)).modifier(GridCell())
            }
            GridRow {
                BatteryCard().modifier(GridCell())
                MetricCard(
                    label: "内存",
                    value: String(format: "%.0f%%", memory?.usedPercent ?? 0),
                    ratio: (memory?.usedPercent ?? 0) / 100,
                    caption: "\(Size.format(memory?.used ?? 0)) / \(Size.format(memory?.total ?? 0))").modifier(GridCell())
                MetricCard(
                    label: "磁盘",
                    value: String(format: "%.0f%%", disk?.usedPercent ?? 0),
                    ratio: (disk?.usedPercent ?? 0) / 100,
                    caption: "剩余 \(Size.format((disk?.total ?? 0) - (disk?.used ?? 0)))").modifier(GridCell())
            }
        }
    }

    private func coreCaption(_ cpu: StatusSnapshot.CPU?) -> String {
        guard let cpu else { return "—" }
        if let p = cpu.pCoreCount, let e = cpu.eCoreCount, p > 0 {
            return "\(p) 性能核 · \(e) 能效核"
        }
        return "\(cpu.coreCount ?? 0) 核"
    }

    /// The name and core count still come from the CLI; only the live
    /// utilisation is read from IOKit.
    private func gpuCaption(_ gpu: StatusSnapshot.GPU?) -> String {
        let name = gpu?.name ?? "GPU"
        if let memory = app.gpu.memoryInUse, memory > 0 {
            return "\(name) · \(Size.format(memory))"
        }
        return name
    }
}

/// Fixes every grid card to one width-flexible, height-locked cell, so all six
/// align exactly regardless of how much content each holds.
private struct GridCell: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity)
            .frame(height: Metrics.dashCardHeight)
            // Insurance: even if some card's content ever exceeds the fixed
            // height, it is contained rather than bleeding over the gap below.
            .clipped()
    }
}

private struct MetricCard: View {
    var label: String
    var value: String
    var ratio: Double
    var caption: String

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Text(label)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                    Spacer()
                    Text(value)
                        .font(Typo.mono(15, .medium))
                        .foregroundStyle(Palette.fg)
                }
                // Absorbs the extra height so the meter + caption settle at the
                // bottom of the (stretched) card and the label stays at the top.
                Spacer(minLength: 8)
                MeterBar(value: ratio)
                Text(caption)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NetworkCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let interface = app.status?.primaryInterface
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "网络", trailing: interface?.name)
                // Rolling window of local samples; `mo status` only reports the
                // current rate, so history is accumulated by the app. The graph
                // flexes to fill the card so there is no dead space beneath it.
                NetGraph(rx: app.rxHistory, tx: app.txHistory)
                    .frame(minHeight: 26, maxHeight: .infinity)
                HStack(spacing: 18) {
                    RateLabel(symbol: "arrow.down", value: interface?.rxRateMbs ?? 0)
                    RateLabel(symbol: "arrow.up", value: interface?.txRateMbs ?? 0)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

private struct RateLabel: View {
    var symbol: String
    /// Megabytes per second, as reported by the CLI.
    var value: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(Palette.fg(0.58))
            Text(format(value))
                .font(Typo.mono(12, .medium))
                .foregroundStyle(Palette.fg)
        }
    }

    private func format(_ mbs: Double) -> String {
        mbs >= 1 ? String(format: "%.1f MB/s", mbs) : String(format: "%.0f KB/s", mbs * 1024)
    }
}

private struct NetGraph: View {
    var rx: [Double]
    var tx: [Double]

    var body: some View {
        GeometryReader { geo in
            let peak = max(rx.max() ?? 0, tx.max() ?? 0, 0.05)
            let count = max(rx.count, 1)
            let barWidth = geo.size.width / CGFloat(max(count, 20))
            HStack(alignment: .bottom, spacing: 1) {
                ForEach(Array(rx.enumerated()), id: \.offset) { index, value in
                    let up = index < tx.count ? tx[index] : 0
                    VStack(spacing: 1) {
                        Capsule()
                            .fill(Palette.selBg.opacity(0.45))
                            .frame(height: max(1, geo.size.height * 0.4 * (up / peak)))
                        Capsule()
                            .fill(Palette.selBg)
                            .frame(height: max(1, geo.size.height * 0.55 * (value / peak)))
                    }
                    .frame(width: max(1, barWidth - 1))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        }
    }
}

private struct BatteryCard: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let battery = app.status?.batteries?.first
        let accessories = (app.status?.bluetooth ?? []).filter { $0.batteryPercent != nil }

        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardTitle(text: "电池", trailing: battery?.status == "AC" ? "接通电源" : battery?.timeLeft)
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(battery?.percent ?? 0)%")
                            .font(Typo.mono(28, .semibold))
                            .foregroundStyle(lowBattery(battery) ? Palette.danger : Palette.fg)
                        // Two short lines rather than one long one, so the narrow
                        // card never has to truncate 健康度 away.
                        Text("循环 \(battery?.cycleCount ?? 0) 次")
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                            .fixedSize()
                        Text("健康度 \(battery?.capacity ?? 0)%")
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                            .fixedSize()
                    }
                    Spacer(minLength: 8)
                    HStack(spacing: 10) {
                        ForEach(accessories.prefix(3), id: \.name) { device in
                            VStack(spacing: 4) {
                                Ring(value: Double(device.batteryPercent ?? 0) / 100,
                                     size: 38, lineWidth: 3.5,
                                     tint: (device.batteryPercent ?? 100) <= 20 ? Palette.danger : Palette.selBg,
                                     label: "\(device.batteryPercent ?? 0)")
                                Text(shortName(device.name ?? ""))
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Palette.fg(0.58))
                                    .lineLimit(1)
                                    .frame(width: 50)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func lowBattery(_ battery: StatusSnapshot.Battery?) -> Bool {
        guard let percent = battery?.percent else { return false }
        return percent <= 20 && battery?.status != "AC"
    }

    private func shortName(_ name: String) -> String {
        name.count <= 8 ? name : String(name.prefix(8)) + "…"
    }
}

/// Memory-ranked application list, styled like the menu-bar HUD: app icon +
/// name + process-count badge + memory, grouped per app (`appsByMemory`).
private struct ProcessTable: View {
    @Environment(AppState.self) private var app

    var body: some View {
        Card(padding: 0) {
            VStack(spacing: 0) {
                Text("内存占用最高的应用")
                    .font(Typo.cardTitle)
                    .foregroundStyle(Palette.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Metrics.rowPaddingH)
                    .padding(.vertical, 11)
                Hairline()

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(app.appsByMemory) { usage in
                            AppRow(usage: usage)
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxHeight: .infinity)
    }
}

/// One merged application, matching the HUD's row at window scale.
private struct AppRow: View {
    @Environment(AppState.self) private var app
    var usage: AppUsage
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let icon = AppIcons.icon(forBundle: usage.bundlePath) {
                    icon.resizable()
                } else {
                    // A friendly service uses its symbol; anything else falls back
                    // to a neutral gear so the column stays aligned.
                    Image(systemName: usage.symbol ?? "gearshape")
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .foregroundStyle(Palette.fg(usage.symbol == nil ? 0.45 : 0.62))
                        .padding(2)
                }
            }
            .frame(width: 22, height: 22)

            Text(usage.name)
                .font(Typo.body)
                .foregroundStyle(Palette.fg)
                .lineLimit(1)
                .truncationMode(.middle)

            // Only worth saying when it stands for more than one process.
            if usage.processCount > 1 {
                Text("\(usage.processCount)")
                    .font(Typo.mono(10))
                    .foregroundStyle(Palette.fg(0.5))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Palette.fgDecoration(0.08), in: Capsule())
            }

            Spacer(minLength: 12)

            Text(Size.format(usage.memoryBytes))
                .font(Typo.mono(12, .medium))
                .foregroundStyle(Palette.fg(0.82))

            Button {
                ProcessLister.terminate(usage, in: app.processes)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Palette.danger)
                    .frame(width: 22)
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("结束 \(usage.name)")
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 8)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
    }
}

/// Shown when the `mo` binary cannot be located — the app is a front end, so
/// this is a hard dependency and the message says so plainly.
struct CLIMissingView: View {
    var body: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .fill(Palette.panel)
                .frame(width: 58, height: 58)
                .overlay(
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(Palette.fg(0.58))
                )
            Text("没有找到 mo")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.fg)
            Text("lumac 依赖 mo 命令行工具来完成扫描和清理。")
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.58))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
