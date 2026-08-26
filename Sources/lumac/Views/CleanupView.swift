import SwiftUI

/// The shared four-stage page behind 深度清理 / 卸载应用 / 项目产物 / 安装包 / 系统优化.
struct CleanupView: View {
    @Environment(AppState.self) private var app
    var command: CleanupCommand

    var body: some View {
        let model = app.cleanup(for: command)

        VStack(spacing: 0) {
            Group {
                switch model.phase {
                case .idle:            IdleStage(model: model)
                case .scanning:        ScanningStage(model: model)
                case .ready:           ReadyStage(model: model)
                case .running:         RunningStage(model: model)
                case .done:            DoneStage(model: model)
                case .empty:           EmptyStage(model: model)
                case .failed(let why): FailedStage(model: model, reason: why)
                case .unsupported:     UnsupportedStage(command: model.command)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if app.showSummaryBar, model.phase == .ready, model.canExecute {
                SummaryBar(model: model)
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
    }
}

// MARK: - 空闲

private struct IdleStage: View {
    var model: CleanupModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 14) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.panel)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: Screen(rawValue: model.command.rawValue)?.symbol ?? "trash")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Palette.fg(0.62))
                    )
                Text(model.command.idleHeadline)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(model.command.idleDetail)
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 420)
                PrimaryButton(title: model.command.startButtonTitle) { model.scan() }
                    .padding(.top, 4)
            }
            Spacer()
        }
    }
}

// MARK: - 扫描中

private struct ScanningStage: View {
    var model: CleanupModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Text("正在检查…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.fg)
                // The dry run does not stream progress, so this is an
                // indeterminate bar rather than an invented percentage.
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.selBg)
                    .frame(width: 260)
                Text("扫描过程不会改动任何东西")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                SecondaryButton(title: "取消") { model.cancel() }
                    .padding(.top, 6)
            }
            Spacer()
        }
    }
}

// MARK: - 待确认列表

private struct ReadyStage: View {
    @Environment(AppState.self) private var app
    var model: CleanupModel
    @State private var confirming = false
    /// Categories the user has expanded to inspect their individual paths.
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(model.allSelected ? "全不选" : "全选") {
                    model.setAll(!model.allSelected)
                }
                .buttonStyle(.plain)
                .font(Typo.body)
                .foregroundStyle(Palette.accentText)

                Text("共 \(model.result.items.count) 类")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))

                Spacer()

                if model.needsPrivileges {
                    Badge(text: "部分系统缓存需要授权后才能扫描",
                          tint: Palette.danger,
                          fill: Palette.danger.opacity(0.10))
                }

                Text("可释放 \(Size.format(model.result.totalBytes))")
                    .font(Typo.mono(13, .medium))
                    .foregroundStyle(Palette.accentText)
            }

            Card(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.result.items) { item in
                            ScanRow(item: item,
                                    share: share(of: item),
                                    expanded: expanded.contains(item.id),
                                    onToggle: { model.toggle(item) },
                                    onExpand: { toggleExpand(item) })
                            if expanded.contains(item.id) {
                                ForEach(item.entries) { entry in
                                    EntryRow(entry: entry,
                                             share: entryShare(entry, in: item)) {
                                        model.toggleEntry(item, entry)
                                    }
                                }
                            }
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                if !model.result.skipped.isEmpty {
                    Text("\(model.result.skipped.count) 项因为无法访问被跳过")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .help(model.result.skipped.joined(separator: "\n"))
                }
                Spacer()
                SecondaryButton(title: "重新检查") { model.scan() }
                PrimaryButton(title: "清理所选") {
                    if app.requireConfirm && model.selectionIsRisky {
                        confirming = true
                    } else {
                        runExecute()
                    }
                }
                .disabled(!model.canExecute)
                .opacity(model.canExecute ? 1 : 0.4)
            }
        }
        .confirmationDialog("确认清理", isPresented: $confirming) {
            Button("移入废纸篓", role: .destructive) { runExecute() }
            Button("再看看", role: .cancel) {}
        } message: {
            Text("其中有需要确认的项目。所有内容都会移入废纸篓，可以随时还原。")
        }
    }

    /// Runs the Touch ID gate (when enabled) before trashing the selection.
    private func runExecute() {
        Task {
            if await app.confirmBiometric("确认清理所选项目") { model.execute() }
        }
    }

    private func toggleExpand(_ item: ScanItem) {
        if expanded.contains(item.id) { expanded.remove(item.id) }
        else { expanded.insert(item.id) }
    }

    private func share(of item: ScanItem) -> Double {
        let largest = model.result.items.map(\.bytes).max() ?? 0
        guard largest > 0 else { return 0 }
        return Double(item.bytes) / Double(largest)
    }

    private func entryShare(_ entry: ScanEntry, in item: ScanItem) -> Double {
        let largest = item.entries.map(\.bytes).max() ?? 0
        guard largest > 0 else { return 0 }
        return Double(entry.bytes) / Double(largest)
    }
}

/// A category row: a tri-state checkbox for the whole group, and a chevron that
/// expands the individual paths underneath.
private struct ScanRow: View {
    var item: ScanItem
    var share: Double
    var expanded: Bool
    var onToggle: () -> Void
    var onExpand: () -> Void
    @State private var hovering = false

    /// none / some / all — the checkbox glyph reflects partial selection.
    private var checkbox: String {
        if item.allSelected { return "checkmark.square.fill" }
        if item.anySelected { return "minus.square.fill" }
        return "square"
    }

    var body: some View {
        HStack(spacing: 0) {
            // A leading marker when anything in the category is selected.
            Rectangle()
                .fill(item.anySelected ? Palette.selBg : Color.clear)
                .frame(width: 2.5)

            HStack(spacing: 11) {
                // The checkbox toggles the whole category; it does not expand.
                Button(action: onToggle) {
                    Image(systemName: checkbox)
                        .font(.system(size: 14))
                        .foregroundStyle(item.anySelected ? Palette.selBg : Palette.fg(0.35))
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(Typo.body)
                            .foregroundStyle(Palette.fg)
                        if item.risk > .safe {
                            Badge(text: item.risk.label,
                                  tint: Palette.danger,
                                  fill: Palette.danger.opacity(0.10))
                        }
                    }
                    Text(subtitle)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                MeterBar(value: share, height: 4)
                    .frame(width: 92)

                Text(Size.format(item.bytes))
                    .font(Typo.mono(12, .medium))
                    .foregroundStyle(Palette.fg)
                    .frame(width: 68, alignment: .trailing)

                // Chevron shows the row can open to reveal its paths.
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.fg(0.4))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    .frame(width: 12)
            }
            .padding(.horizontal, Metrics.rowPaddingH)
            .padding(.vertical, Metrics.rowPaddingV)
        }
        .background(hovering ? Palette.hover : Color.clear)
        .contentShape(Rectangle())
        // Tapping the row (outside the checkbox) expands it.
        .onTapGesture(perform: onExpand)
        .onHover { hovering = $0 }
    }

    /// While collapsed, show how many of the paths are selected.
    private var subtitle: String {
        let count = item.pathCount
        if item.selectedCount == count { return item.detail }
        return "\(item.detail) · 已选 \(item.selectedCount)/\(count)"
    }
}

/// One path inside an expanded category, individually tickable.
private struct EntryRow: View {
    var entry: ScanEntry
    var share: Double
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: entry.selected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(entry.selected ? Palette.selBg : Palette.fg(0.35))

            Text(Trash.abbreviate(entry.path))
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.82))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            MeterBar(value: share, height: 3)
                .frame(width: 64)

            Text(Size.format(entry.bytes))
                .font(Typo.mono(11))
                .foregroundStyle(Palette.fg(0.7))
                .frame(width: 60, alignment: .trailing)
        }
        // Indented under the category, so the hierarchy reads at a glance.
        .padding(.leading, Metrics.rowPaddingH + 30)
        .padding(.trailing, Metrics.rowPaddingH)
        .padding(.vertical, 8)
        .background((hovering ? Palette.hover : Palette.panel).opacity(hovering ? 1 : 0.4))
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
    }
}

/// Plain-language consequences, shown only while a selection exists.
private struct SummaryBar: View {
    var model: CleanupModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "trash")
                .font(.system(size: 11))
                .foregroundStyle(Palette.accentText)
            Text(model.summaryText)
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.82))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Palette.accentSoft, in: RoundedRectangle(cornerRadius: Radius.list, style: .continuous))
        .padding(.top, 10)
    }
}

// MARK: - 执行中

private struct RunningStage: View {
    var model: CleanupModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Text("正在移入废纸篓…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.fg)
                MeterBar(value: model.progress, height: 5)
                    .frame(width: 300)
                Text(model.currentPath.isEmpty ? " " : model.currentPath)
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.fg(0.58))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: 420)
                SecondaryButton(title: "取消") { model.cancel() }
                    .padding(.top, 6)
                Text("已经移走的内容不会退回原处，可以在废纸篓里还原")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
            }
            Spacer()
        }
    }
}

// MARK: - 完成

private struct DoneStage: View {
    var model: CleanupModel

    var body: some View {
        let outcome = model.outcome
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Text(Size.format(outcome?.freedBytes ?? 0))
                    .font(Typo.mono(40, .semibold))
                    .foregroundStyle(Palette.accentText)
                Text("已移入废纸篓")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text("共 \(outcome?.trashed.count ?? 0) 个位置，需要的话可以从废纸篓还原")
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))

                if let failed = outcome?.failed, !failed.isEmpty {
                    Text("\(failed.count) 项没能移走")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.danger)
                        .help(failed.prefix(10).map { "\(Trash.abbreviate($0.path))：\($0.reason)" }
                            .joined(separator: "\n"))
                }

                HStack(spacing: 10) {
                    SecondaryButton(title: "打开废纸篓") { Trash.openTrash() }
                    PrimaryButton(title: "再检查一次") { model.scan() }
                }
                .padding(.top, 4)
            }
            Spacer()
        }
    }
}

// MARK: - 空态与失败

private struct EmptyStage: View {
    var model: CleanupModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.panel)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: "checkmark")
                            .font(.system(size: 24, weight: .light))
                            .foregroundStyle(Palette.fg(0.62))
                    )
                Text("没什么可清理的")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text("这台 Mac 目前很干净，过段时间再来看看。")
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))
                SecondaryButton(title: "重新检查") { model.scan() }
                    .padding(.top, 4)
            }
            Spacer()
        }
    }
}

private struct FailedStage: View {
    var model: CleanupModel
    var reason: String

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(Palette.danger)
                Text("检查没能完成")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(reason)
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                SecondaryButton(title: "重试") { model.scan() }
                    .padding(.top, 4)
            }
            Spacer()
        }
    }
}

/// Shown for the four pages whose scanner is not built yet.
///
/// The CLI cannot supply their file lists non-interactively, so each needs its
/// own scanner before it can offer anything to tick. Showing this beats showing
/// a list assembled from another command's results.
private struct UnsupportedStage: View {
    var command: CleanupCommand

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: 12) {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .fill(Palette.panel)
                    .frame(width: 62, height: 62)
                    .overlay(
                        Image(systemName: "hammer")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(Palette.fg(0.62))
                    )
                Text("这个页面还没做完")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Palette.fg)
                Text(reason)
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))
                    .multilineTextAlignment(.center)
                    .lineSpacing(3)
                    .frame(maxWidth: 430)
            }
            Spacer()
        }
    }

    private var reason: String {
        switch command {
        case .uninstall, .installer:
            return "命令行工具在这一步需要键盘操作，拿不到可以直接使用的清单，\n这个页面需要自己实现扫描。"
        case .purge:
            return "还需要自己实现构建产物的扫描。"
        case .optimize:
            return "系统优化不是删文件，需要单独的执行流程。"
        case .clean:
            return ""
        }
    }
}
