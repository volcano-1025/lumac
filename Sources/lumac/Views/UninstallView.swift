import SwiftUI
import AppKit

/// 卸载应用 — `mo uninstall`. Pick an app, preview everything removing it would
/// delete, then move the app and its user-space leftovers to the Trash.
struct UninstallView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.uninstallModel
        Group {
            switch model.stage {
            case .list:               AppListStage(model: model)
            case .preview:            PreviewStage(model: model)
            case .running:            RunningStage(model: model)
            case .done:               DoneStage(model: model)
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
        .task { model.loadListIfNeeded() }
    }
}

/// The app's real icon, read from disk.
private struct AppIcon: View {
    var path: String
    var size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}

// MARK: - List

private struct AppListStage: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(spacing: 10) {
            if model.listLoading && model.apps.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在扫描已安装的应用…")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 10) {
                    SearchField(text: $model.query)
                    Text("共 \(model.filteredApps.count) 个应用")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                    Spacer()
                    SortPicker(sort: model.sort) { model.sort = $0 }
                    SecondaryButton(title: "刷新") { model.reloadList() }
                }

                Card(padding: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.filteredApps) { item in
                                AppRow(app: item) { model.select(item) }
                                Hairline()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
    }
}

private struct AppRow: View {
    var app: InstalledApp
    var onSelect: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 11) {
                AppIcon(path: app.path, size: 30)

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(Typo.body)
                        .foregroundStyle(Palette.fg)
                        .lineLimit(1)
                    Text("\(app.bundleId) · \(app.lastUsedText)")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                Text(app.sizeText)
                    .font(Typo.mono(12, .medium))
                    .foregroundStyle(Palette.fg)
                    .frame(width: 68, alignment: .trailing)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.fg(0.35))
            }
            .padding(.horizontal, Metrics.rowPaddingH)
            .padding(.vertical, Metrics.rowPaddingV)
            .background(hovering ? Palette.hover : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Preview

private struct PreviewStage: View {
    @Environment(AppState.self) private var app
    @Bindable var model: UninstallModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // App header with a back button.
            HStack(spacing: 11) {
                Button { model.backToList() } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Palette.accentText)
                        .frame(width: 28, height: 28)
                        .background(Palette.panel, in: Circle())
                }
                .buttonStyle(.plain)
                .help("返回列表")

                if let selected = model.selected {
                    AppIcon(path: selected.path, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(selected.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Palette.fg)
                        Text(selected.bundleId)
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                    }
                }
                Spacer()
            }

            content
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.previewLoading {
            VStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("正在分析这个应用会留下哪些文件…")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let preview = model.preview {
            PreviewBody(preview: preview,
                        confirming: $confirming,
                        onExecute: {
                            Task {
                                if await app.confirmBiometric("确认卸载这个应用") { model.execute() }
                            }
                        })
                .environment(app)
        }
    }
}

private struct PreviewBody: View {
    @Environment(AppState.self) private var app
    var preview: UninstallPreview
    @Binding var confirming: Bool
    var onExecute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("将移入废纸篓 \(preview.trashable.count) 项")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                Spacer()
                Text("可释放 \(Size.format(preview.trashableBytes))")
                    .font(Typo.mono(13, .medium))
                    .foregroundStyle(Palette.accentText)
            }

            Card(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(preview.trashable) { item in
                            LeftoverRow(item: item)
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            // Privileged /Library items lumac cannot trash itself yet.
            if !preview.privileged.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                    Text("另有 \(preview.privileged.count) 项系统级文件需要授权，本版本暂不处理，可用终端的 mo uninstall 完成。")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                    Spacer()
                }
            }

            HStack {
                Spacer()
                PrimaryButton(title: "移入废纸篓") { confirming = true }
                    .disabled(preview.trashable.isEmpty)
                    .opacity(preview.trashable.isEmpty ? 0.4 : 1)
            }
        }
        .confirmationDialog("确认卸载", isPresented: $confirming) {
            Button("移入废纸篓", role: .destructive) { onExecute() }
            Button("再看看", role: .cancel) {}
        } message: {
            Text("应用和它的用户数据会移入废纸篓，可以随时还原。")
        }
    }
}

private struct LeftoverRow: View {
    var item: UninstallLeftover

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: iconName)
                .font(.system(size: 12))
                .foregroundStyle(Palette.fg(0.5))
                .frame(width: 16)
            Text(Trash.abbreviate(item.path))
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.82))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 12)
            Text(Size.format(item.bytes))
                .font(Typo.mono(11, .medium))
                .foregroundStyle(Palette.fg(0.7))
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 10)
    }

    private var iconName: String {
        if item.path.hasSuffix(".app") { return "app" }
        if item.path.hasSuffix(".plist") { return "doc.text" }
        return "folder"
    }
}

// MARK: - Running / Done

private struct RunningStage: View {
    var model: UninstallModel

    var body: some View {
        VStack(spacing: 12) {
            Text("正在移入废纸篓…")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.fg)
            ProgressView(value: model.progress)
                .progressViewStyle(.linear)
                .tint(Palette.selBg)
                .frame(width: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DoneStage: View {
    var model: UninstallModel

    var body: some View {
        let outcome = model.outcome
        let trashedCount = outcome?.trashed.count ?? 0
        let failed = outcome?.failed ?? []
        // Nothing moved but things failed → this is a failure, not a success.
        let allFailed = trashedCount == 0 && !failed.isEmpty

        return VStack(spacing: 12) {
            Image(systemName: allFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(allFailed ? Palette.danger : Palette.accentText)

            Text(allFailed ? "卸载未完成"
                           : "已移入废纸篓 \(Size.format(outcome?.freedBytes ?? 0))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.fg)

            if allFailed {
                // Surface the real reason — usually a missing permission.
                Text(reason(failed))
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.7))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .help(failed.map { "\($0.path)：\($0.reason)" }.joined(separator: "\n"))
            } else if !failed.isEmpty {
                Text("其中 \(failed.count) 项未能移除")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.danger)
                    .help(failed.map { "\($0.path)：\($0.reason)" }.joined(separator: "\n"))
            }

            HStack(spacing: 10) {
                if allFailed {
                    SecondaryButton(title: "去开启完全磁盘访问") { FullDiskAccess.openSettings() }
                } else {
                    SecondaryButton(title: "打开废纸篓") { Trash.openTrash() }
                }
                PrimaryButton(title: "返回列表") { model.reset() }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A plain-language explanation built from the first failure reason.
    private func reason(_ failed: [(path: String, reason: String)]) -> String {
        let raw = failed.first?.reason ?? ""
        let permissionish = raw.localizedCaseInsensitiveContains("permission")
            || raw.localizedCaseInsensitiveContains("权限")
            || raw.contains("513") || raw.contains("257")
        if permissionish {
            return "没有权限移动这些文件。请在「系统设置 › 隐私与安全性」里给 lumac 开启完全磁盘访问，以及在「App 管理」里允许 lumac，然后重试。\n（\(raw)）"
        }
        return raw.isEmpty ? "没有文件被移除。" : raw
    }
}

// MARK: - Shared

private struct SearchField: View {
    @Binding var text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(Palette.fg(0.5))
            TextField("搜索应用", text: $text)
                .textFieldStyle(.plain)
                .font(Typo.body)
                .frame(width: 180)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Palette.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
    }
}

/// 大小 / 最近使用 / 名称 sort control, matching the content-layer pill styling.
private struct SortPicker: View {
    var sort: UninstallModel.SortKey
    var select: (UninstallModel.SortKey) -> Void

    var body: some View {
        HStack(spacing: 3) {
            ForEach(UninstallModel.SortKey.allCases, id: \.self) { key in
                let on = sort == key
                Button { select(key) } label: {
                    Text(key.label)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.selFg : Palette.fg(0.7))
                        .padding(.horizontal, 11)
                        .frame(height: 26)
                        .background { if on { Capsule().fill(Palette.selBg) } }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(Palette.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
    }
}
