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
                    Text("\(model.result.skipped.count) 项被跳过 · 悬停查看原因")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .help(model.result.skipped.joined(separator: "\n"))
                }
                Spacer()
                EmptyTrashButton()
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
                    // Right after a cleanup the Trash has just grown — offer to
                    // empty it here, where the user actually lands.
                    EmptyTrashButton()
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

/// Empties the Trash — a permanent, non-undoable delete kept deliberately apart
/// from the move-to-Trash cleanup. Self-contained so both the ready and empty
/// stages can drop it in: size probe (off-main), confirmation, Touch ID gate,
/// and a note when root-owned items can't be removed without sudo. Shows nothing
/// when the Trash is empty.
private struct EmptyTrashButton: View {
    @Environment(AppState.self) private var app
    @State private var trashBytes: Int64 = 0
    @State private var confirming = false
    @State private var emptying = false
    @State private var progress: Double = 0
    @State private var note: String?
    /// Full paths the plain empty couldn't remove (root-owned), kept so the
    /// alert's elevate button knows what to delete.
    @State private var rootFailed: [String] = []

    var body: some View {
        // The else branch renders a real (zero-size) view rather than an
        // EmptyView, so `.task` always has a host to fire on — an empty Group
        // silently drops the task, leaving trashBytes stuck at 0 forever and
        // the button never appearing.
        stack
        .confirmationDialog("清空废纸篓", isPresented: $confirming) {
            Button("永久清空", role: .destructive) { run() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("废纸篓里的 \(Size.format(trashBytes)) 将被永久删除，无法还原。")
        }
        .alert("废纸篓", isPresented: Binding(
            get: { note != nil }, set: { if !$0 { note = nil } }
        )) {
            // Root-owned leftovers can't be cleared by lumac (TCC guards
            // ~/.Trash and the items need root). Finder is entitled to empty
            // them, so send the user there to finish manually.
            if !rootFailed.isEmpty {
                Button("打开废纸篓") { Trash.openTrash() }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(note ?? "")
        }
        .task { await refresh() }
    }

    @ViewBuilder private var stack: some View {
        if emptying {
            // Emptying can take a while for a large Trash — show live progress
            // in place of the button rather than freezing on a tapped control.
            HStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(width: 90)
                Text("清空中 \(Int(progress * 100))%")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.7))
            }
        } else if trashBytes > 0 {
            SecondaryButton(title: "清空废纸篓 \(Size.format(trashBytes))",
                            destructive: true) { confirming = true }
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// A large Trash is slow to walk, so size it off the main actor.
    private func refresh() async {
        trashBytes = await Task.detached(priority: .utility) { Trash.trashSize() }.value
    }

    private func run() {
        Task {
            guard await app.confirmBiometric("确认清空废纸篓") else { return }
            emptying = true
            progress = 0
            let result = await Trash.emptyTrash { self.progress = $0 }
            emptying = false
            await refresh()
            rootFailed = result.failed
            // Confirm completion; when root-owned items remain, the alert grows a
            // "打开废纸篓" button (see body) so the user can finish in Finder,
            // which is entitled to empty them.
            if result.failed.isEmpty {
                note = "已清空 \(Size.format(result.freedBytes))。"
            } else {
                note = "已清空 \(Size.format(result.freedBytes))，还有 \(result.failed.count) 项属于系统（root），lumac 删不了。请打开废纸篓，在访达里手动清空。"
            }
        }
    }
}

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
                // A scan can come back empty *because* everything it found was
                // out of the trash guard's range (a project on an external
                // volume, say). Without this the page claimed there was nothing
                // to clean when there was.
                if !model.result.skipped.isEmpty {
                    Text("另有 \(model.result.skipped.count) 项被跳过 · 悬停查看原因")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.5))
                        .help(model.result.skipped.joined(separator: "\n"))
                }
                // The Trash can still be full even when nothing is cleanable —
                // e.g. right after a cleanup — so the empty action lives here too.
                HStack(spacing: 10) {
                    EmptyTrashButton()
                    SecondaryButton(title: "重新检查") { model.scan() }
                }
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
