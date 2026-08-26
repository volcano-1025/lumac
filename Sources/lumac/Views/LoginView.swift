import SwiftUI
import AppKit

/// 启动项 — the launchd agents and daemons that start at login or boot. User
/// agents can be switched off here; system items are shown read-only.
struct LoginView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.loginModel
        VStack(spacing: 10) {
            if model.loading && model.items.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("共 \(model.items.count) 个启动项")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                    Spacer()
                    SecondaryButton(title: "刷新") { model.reload() }
                }

                Card(padding: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.items) { item in
                                LoginRow(item: item) { model.toggle(item) }
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
                    Text("关闭用户启动项在下次登录时生效；系统级项目需在「系统设置」中管理。")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
        .task { model.loadIfNeeded() }
    }
}

private struct LoginRow: View {
    var item: LoginItem
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            icon
                .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(Typo.body)
                        .foregroundStyle(item.disabled ? Palette.fg(0.58) : Palette.fg)
                        .lineLimit(1)
                    if item.domain != .userAgent {
                        Badge(text: item.domain.label)
                    }
                    if item.disabled {
                        Badge(text: "已关闭", tint: Palette.fg(0.58), fill: Palette.fgDecoration(0.08))
                    }
                }
                Text(item.program.isEmpty ? item.label : Trash.abbreviate(item.program))
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 12)

            if item.domain.togglable {
                Toggle("", isOn: Binding(get: { !item.disabled }, set: { _ in onToggle() }))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(Palette.selBg)
                    .controlSize(.small)
            } else {
                Image(systemName: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.fg(0.35))
                    .help("系统级启动项需要在「系统设置」中管理")
            }
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 11)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
    }

    @ViewBuilder
    private var icon: some View {
        if let iconPath = item.iconPath {
            Image(nsImage: NSWorkspace.shared.icon(forFile: iconPath))
                .resizable()
                .interpolation(.high)
        } else {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Palette.panel)
                .overlay(
                    Image(systemName: item.domain == .systemDaemon ? "gearshape.2" : "person.badge.clock")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.fg(0.5)))
        }
    }
}
