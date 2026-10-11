import SwiftUI
import AppKit

/// 应用更新 — checks Homebrew for outdated packages and upgrades them. Coverage
/// is limited to what brew manages; the empty and no-brew states say so plainly.
struct UpdatesView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.updatesModel
        VStack(spacing: 10) {
            switch model.phase {
            case .loading:
                Loading(text: "正在通过 Homebrew 检查更新…")
            case .noBrew:
                Message(symbol: "shippingbox", tint: Palette.fg(0.5),
                        title: "未检测到 Homebrew",
                        detail: "应用更新目前依赖 Homebrew 检查。装好 brew 后就能在这里看到可更新的应用。",
                        retry: nil)
            case .empty:
                Message(symbol: "checkmark.seal", tint: Palette.accentText,
                        title: "都是最新的",
                        detail: "Homebrew 管理的应用都已经是最新版本。",
                        retry: { model.reload() })
            case .failed(let why):
                Message(symbol: "exclamationmark.triangle", tint: Palette.danger,
                        title: "检查失败", detail: why, retry: { model.reload() })
            case .loaded:
                LoadedList(model: model)
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
        .task { model.loadIfNeeded() }
    }
}

private struct LoadedList: View {
    var model: UpdatesModel

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                Text("\(model.items.count) 个可更新")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                Spacer()
                // 刷新 cancels the model's task and resets per-item state, so
                // it must stay out of reach while 全部更新 is mid-run.
                SecondaryButton(title: "刷新") { model.reload(force: true) }
                    .disabled(model.allRunning)
                    .opacity(model.allRunning ? 0.5 : 1)
                PrimaryButton(title: "全部更新") { model.upgradeAll() }
                    .disabled(model.allRunning)
                    .opacity(model.allRunning ? 0.5 : 1)
            }

            // Overall progress while 全部更新 runs, or a completion banner after.
            if model.allRunning {
                ProgressBanner(text: "正在更新 \(model.allDone)/\(model.allTotal)"
                               + (model.current.isEmpty ? "" : " · \(model.current)"),
                               progress: model.allProgress)
            } else if let summary = model.summary {
                DoneBanner(text: summary)
            }

            Card(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.items) { item in
                            UpdateRow(item: item, state: model.state(item)) {
                                model.upgrade(item)
                            }
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fg(0.5))
                Text("目前只覆盖 Homebrew 管理的应用；App Store 和自更新应用暂不支持。")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                Spacer()
            }
        }
    }
}

private struct ProgressBanner: View {
    var text: String
    var progress: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(text)
                .font(Typo.aux)
                .foregroundStyle(Palette.accentText)
            MeterBar(value: progress, height: 5)
        }
        .padding(10)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.list, style: .continuous))
    }
}

private struct DoneBanner: View {
    var text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 13))
                .foregroundStyle(Palette.accentText)
            Text(text)
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.82))
            Spacer()
        }
        .padding(10)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.list, style: .continuous))
    }
}

private struct UpdateRow: View {
    var item: BrewUpdate
    var state: UpdatesModel.ItemState
    var onUpgrade: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            icon.frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(Typo.body)
                        .foregroundStyle(Palette.fg)
                        .lineLimit(1)
                    Badge(text: item.kind.label)
                }
                HStack(spacing: 5) {
                    Text(item.current)
                        .font(Typo.mono(11))
                        .foregroundStyle(Palette.fg(0.58))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(Palette.fg(0.4))
                    Text(item.latest)
                        .font(Typo.mono(11, .medium))
                        .foregroundStyle(Palette.accentText)
                }
            }

            Spacer(minLength: 12)

            trailing
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 11)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        // Casks show the installed app's real icon; formulae show a terminal glyph.
        if let appPath = item.appPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: appPath))
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.panel)
                .overlay(
                    Image(systemName: item.kind == .cask ? "app.dashed" : "terminal")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.fg(0.5)))
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch state {
        case .idle:
            SecondaryButton(title: "更新") { onUpgrade() }
        case .updating:
            ProgressView().controlSize(.small)
        case .done:
            Label("已更新", systemImage: "checkmark.circle.fill")
                .labelStyle(.titleAndIcon)
                .font(Typo.aux)
                .foregroundStyle(Palette.accentText)
        case .failed:
            HStack(spacing: 8) {
                Text("失败")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.danger)
                SecondaryButton(title: "重试") { onUpgrade() }
            }
        }
    }
}

private struct Loading: View {
    var text: String
    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text(text).font(Typo.aux).foregroundStyle(Palette.fg(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct Message: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var retry: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.fg)
            Text(detail)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let retry {
                SecondaryButton(title: "重新检查") { retry() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
