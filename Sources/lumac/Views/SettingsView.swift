import SwiftUI
import AppKit

/// 设置 — presented as a centered sheet. Appearance, the cleanup switches, the
/// scan/whitelist config, permissions, and an About group.
struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var moPath: String?

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            // Sheet title bar with a close action.
            HStack {
                Text("设置")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                Spacer()
                Button("完成") { dismiss() }
                    .buttonStyle(.plain)
                    .font(Typo.body.weight(.medium))
                    .foregroundStyle(Palette.accentText)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            Hairline()

            ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Section(title: "外观") {
                    SettingRow(label: "主题", detail: "窗口与菜单栏跟随这里的选择") {
                        ThemePicker(theme: $app.theme)
                    }
                }

                Section(title: "清理") {
                    SettingRow(label: "危险操作前需要确认",
                               detail: "清理含「需确认 / 高风险」项目时先弹出确认") {
                        Switch(isOn: $app.requireConfirm)
                    }
                    Hairline()
                    SettingRow(label: "显示底部状态条",
                               detail: "在待确认列表下方用大白话说明这次操作的后果") {
                        Switch(isOn: $app.showSummaryBar)
                    }
                }

                Section(title: "扫描与白名单") {
                    PathListEditor(
                        caption: "「项目产物」会扫描这些目录里的 node_modules、dist 等构建产物。",
                        emptyText: "还没有自定义扫描目录",
                        entries: app.configModel.purgePaths,
                        onAdd: { pickDirectory { app.configModel.addPurgePath($0) } },
                        onRemove: { app.configModel.removePurgePath($0) })
                    Hairline()
                    PathListEditor(
                        caption: "白名单里的路径不会被清理，clean 会跳过它们。",
                        emptyText: "白名单为空",
                        entries: app.configModel.whitelist,
                        onAdd: { pickDirectory(files: true) { app.configModel.addWhitelist($0) } },
                        onRemove: { app.configModel.removeWhitelist($0) })
                }

                Section(title: "权限与安全") {
                    SettingRow(label: "完全磁盘访问",
                               detail: app.fdaGranted ? "已授权，扫描可以覆盖全部缓存"
                                                       : "未授权时部分缓存扫描不到") {
                        if app.fdaGranted {
                            Badge(text: "已授权")
                        } else {
                            SecondaryButton(title: "去开启") { FullDiskAccess.openSettings() }
                        }
                    }
                    if Biometric.available {
                        Hairline()
                        SettingRow(label: "危险操作用 Touch ID 确认",
                                   detail: "清理、卸载前先验证 Touch ID 或登录密码") {
                            Switch(isOn: $app.requireBiometric)
                        }
                    }
                    Hairline()
                    SettingRow(label: "重新查看引导", detail: "再走一遍首次启动的介绍与授权") {
                        SecondaryButton(title: "查看") { app.didOnboard = false }
                    }
                }

                Section(title: "关于") {
                    SettingRow(label: "lumac 版本") {
                        Text(LumacVersion.display)
                            .font(Typo.mono(12, .medium))
                            .foregroundStyle(Palette.fg(0.82))
                    }
                    Hairline()
                    SettingRow(label: "mo 命令行",
                               detail: moPath ?? "把 mo 装到 PATH 上即可启用清理功能") {
                        Badge(text: moPath == nil ? "未检测到" : "已安装",
                              tint: moPath == nil ? Palette.danger : Palette.accentText,
                              fill: moPath == nil ? Palette.danger.opacity(0.10) : Palette.accentSoft)
                    }
                    Hairline()
                    SettingRow(label: "废纸篓", detail: "清理移入的内容都在这里，可随时还原") {
                        SecondaryButton(title: "打开废纸篓") { Trash.openTrash() }
                    }
                    Hairline()
                    SettingRow(label: "检查更新") {
                        SecondaryButton(title: "检查") { app.showingUpdateCheck = true }
                    }
                }
            }
            .padding(20)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 600, height: 680)
        .background(Palette.content)
        .task {
            app.refreshFDA()
            app.configModel.loadIfNeeded()
            moPath = await MoCLI.shared.installedPath()
        }
    }

    /// Opens a folder (or file) picker and hands the chosen path back.
    private func pickDirectory(files: Bool = false, _ completion: @escaping (String) -> Void) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = files
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        if panel.runModal() == .OK, let url = panel.url {
            completion(url.path)
        }
    }
}

/// A titled list of paths with add (folder picker) and per-row remove.
private struct PathListEditor: View {
    var caption: String
    var emptyText: String
    var entries: [String]
    var onAdd: () -> Void
    var onRemove: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Text(caption)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(action: onAdd) {
                    Label("添加", systemImage: "plus")
                        .font(Typo.aux.weight(.medium))
                        .foregroundStyle(Palette.accentText)
                }
                .buttonStyle(.plain)
            }

            if entries.isEmpty {
                Text(emptyText)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.5))
            } else {
                VStack(spacing: 4) {
                    ForEach(entries, id: \.self) { entry in
                        HStack(spacing: 8) {
                            Image(systemName: "folder")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.fg(0.5))
                            Text(entry)
                                .font(Typo.aux)
                                .foregroundStyle(Palette.fg(0.82))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 8)
                            Button { onRemove(entry) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Palette.fg(0.35))
                            }
                            .buttonStyle(.plain)
                            .help("移除")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.panel, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
    }
}

// MARK: - Building blocks

/// A titled group rendered as one card, matching the content-layer card style.
private struct Section<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.fg(0.7))
                .padding(.leading, 2)
            Card(padding: 0) {
                VStack(spacing: 0) { content }
            }
        }
    }
}

/// One row: a label (with optional secondary line) on the left, a control right.
private struct SettingRow<Trailing: View>: View {
    var label: String
    var detail: String? = nil
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg)
                if let detail {
                    Text(detail)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
    }
}

/// System switch, tinted to the selection colour.
private struct Switch: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(Palette.selBg)
    }
}

/// 跟随系统 / 浅色 / 深色 segmented control.
private struct ThemePicker: View {
    @Binding var theme: ThemeMode

    var body: some View {
        HStack(spacing: 3) {
            ForEach(ThemeMode.allCases, id: \.self) { mode in
                let on = theme == mode
                Button { theme = mode } label: {
                    Text(mode.label)
                        .font(.system(size: 12, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Palette.selFg : Palette.fg(0.7))
                        .padding(.horizontal, 12)
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
