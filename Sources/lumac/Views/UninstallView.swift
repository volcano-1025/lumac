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
            PreviewBody(model: model,
                        preview: preview,
                        source: model.previewSource,
                        verifying: model.verifying,
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
    var model: UninstallModel
    var preview: UninstallPreview
    var source: UninstallModel.PreviewSource
    var verifying: Bool
    @Binding var confirming: Bool
    var onExecute: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("已选 \(preview.selectedItems.count)/\(preview.leftovers.count) 项")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                VerifyStatus(source: source, verifying: verifying)
                Spacer()
                Text("可释放 \(Size.format(preview.selectedBytes))")
                    .font(Typo.mono(13, .medium))
                    .foregroundStyle(Palette.accentText)
            }

            if let vendor = model.vendorUninstaller {
                VendorUninstallerBanner(uninstaller: vendor)
            }

            Card(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        // 自动选中 — unambiguously this app's, and removable.
                        if !preview.auto.isEmpty {
                            SectionHeader(
                                title: "自动选中",
                                detail: "\(preview.auto.count) 项 · \(Size.format(UninstallPreview.bytes(of: preview.auto)))",
                                note: nil,
                                checked: model.allSelected(in: .auto),
                                showsToggle: true,
                                onToggle: { model.setTier(.auto, !model.allSelected(in: .auto)) })
                            ForEach(preview.auto) { item in
                                LeftoverRow(item: item) { model.toggle(item) }
                                Hairline()
                            }
                        }

                        // 需要确认 — everything the user has to rule on. Two
                        // things live here for different reasons: rows lumac
                        // *can* remove but that may be shared with another app,
                        // and rows it cannot remove at all. Each says which.
                        if !preview.needsReview.isEmpty {
                            SectionHeader(
                                title: reviewTitle(preview),
                                detail: "\(preview.needsReview.count) 项 · \(Size.format(UninstallPreview.bytes(of: preview.needsReview)))",
                                note: reviewNote(preview),
                                checked: model.allSelected(in: .confirm),
                                showsToggle: preview.leftovers.contains { $0.tier == .confirm },
                                onToggle: { model.setTier(.confirm, !model.allSelected(in: .confirm)) })
                            ForEach(preview.needsReview) { item in
                                LeftoverRow(item: item) { model.toggle(item) }
                                Hairline()
                            }
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack {
                Spacer()
                // While mo re-checks, the one control on the page carries the
                // wait: it is already the thing being waited for, and a dialog
                // over the draft only hid the list the user came to read.
                if verifying {
                    ProgressPrimaryButton(
                        title: model.verifyPhase?.label ?? "正在复核归属…",
                        progress: model.verifyProgress)
                        .help("mo 还在复核归属，复核完成后才能删除")
                } else {
                    PrimaryButton(title: "移入废纸篓") { confirming = true }
                        .disabled(!model.canExecute)
                        .opacity(model.canExecute ? 1 : 0.4)
                }
            }
        }
        .confirmationDialog("确认卸载", isPresented: $confirming) {
            Button("移入废纸篓", role: .destructive) { onExecute() }
            Button("再看看", role: .cancel) {}
        } message: {
            Text(confirmMessage(preview))
        }
    }

    /// Says what will be left behind as well as what will go. Without it the
    /// dialog reads as "everything listed above is handled", when the item that
    /// actually matters — 25.5 MB of program under /Library for fuse-t — is one
    /// lumac cannot touch at all.
    private func confirmMessage(_ preview: UninstallPreview) -> String {
        var text = "勾选的 \(preview.selectedItems.count) 项会移入废纸篓，可以随时还原。"
        let left = preview.leftovers.filter { $0.locked || !$0.selected }
        if !left.isEmpty {
            text += "\n另有 \(left.count) 项（\(Size.format(UninstallPreview.bytes(of: left)))）不会被删除，会留在原处。"
        }
        return text
    }

    /// The second section holds two different situations, and calling both of
    /// them 需要确认 was wrong: when every row is locked there is nothing for
    /// the user to confirm — lumac cannot act on them at all. The heading says
    /// which case this is.
    private func reviewTitle(_ preview: UninstallPreview) -> String {
        preview.leftovers.contains { $0.tier == .confirm } ? "需要确认" : "lumac 无法删除"
    }

    private func reviewNote(_ preview: UninstallPreview) -> String {
        let tickable = preview.leftovers.contains { $0.tier == .confirm }
        let locked = preview.leftovers.contains { $0.tier == .locked }
        if tickable && locked { return "默认不选中；带锁的几项 lumac 无法删除，仅作展示。" }
        if tickable { return "默认不选中，移除前请逐项确认。" }
        return "仅列出来让你知道卸载后会留下什么。"
    }
}

/// Says whose list is on screen. Which app a file belongs to is the one thing
/// this page can get dangerously wrong, so the answer is stated rather than
/// implied — and while mo is still working, the list already visible is
/// explicitly labelled as a draft.
private struct VerifyStatus: View {
    var source: UninstallModel.PreviewSource
    var verifying: Bool

    var body: some View {
        HStack(spacing: 6) {
            // Progress lives in the overlay dialog, not here — while it runs
            // there is nothing to act on, so a line of text competing with the
            // draft list only adds noise.
            if verifying {
                EmptyView()
            } else {
                switch source {
                case .verified:
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.accentText)
                    Text("已按 mo 的归属规则复核")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                case .unavailable(let why):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.danger)
                    Text("\(why)，下面是本机扫描的结果，可能不完整")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                case .native:
                    EmptyView()
                }
            }
        }
    }
}

/// Surfaces an uninstaller the app shipped with itself.
///
/// It is the most authoritative list there is — fuse-t's own script removes
/// four `/usr/local` items no bundle-id sweep finds, and pointedly leaves its
/// framework alone because other software links it. lumac does not run it:
/// it is arbitrary vendor code, and the ones that matter demand root that
/// lumac has no way to grant. So it is shown, and the command is handed over.
private struct VendorUninstallerBanner: View {
    var uninstaller: VendorUninstaller
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 12))
                .foregroundStyle(Palette.accentText)
            VStack(alignment: .leading, spacing: 2) {
                Text("这个应用自带官方卸载程序，通常比通用扫描更完整")
                    .font(Typo.aux.weight(.medium))
                    .foregroundStyle(Palette.fg(0.82))
                Text(Trash.abbreviate(uninstaller.path))
                    .font(Typo.mono(10))
                    .foregroundStyle(Palette.fg(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            SecondaryButton(title: copied ? "已复制 ✓" : "复制命令") {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(uninstaller.command, forType: .string)
                copied = true
            }
            SecondaryButton(title: "在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting(
                    [URL(fileURLWithPath: uninstaller.path)])
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Palette.accentSoft,
                    in: RoundedRectangle(cornerRadius: Radius.list, style: .continuous))
    }
}

/// A section divider carrying its own count, size and select-all box.
private struct SectionHeader: View {
    var title: String
    var detail: String
    var note: String?
    var checked: Bool
    /// Hidden when the section holds nothing tickable — a 需要确认 list made up
    /// entirely of locked rows would otherwise show a select-all that does
    /// nothing.
    var showsToggle: Bool
    var onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(title)
                    .font(Typo.body.weight(.semibold))
                    .foregroundStyle(Palette.fg)
                Text(detail)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                Spacer()
                if showsToggle {
                    Button(action: onToggle) {
                        Image(systemName: checked ? "checkmark.square.fill" : "square")
                            .font(.system(size: 14))
                            .foregroundStyle(checked ? Palette.selBg : Palette.fg(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            if let note {
                Text(note)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.5))
            }
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.panel)
        .overlay(alignment: .top) { Hairline() }
    }
}

/// One leftover: checkbox, what it is in plain Chinese, the path, the size —
/// and, when there is a decision to make, the reason underneath.
private struct LeftoverRow: View {
    var item: UninstallLeftover
    var onToggle: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Locked rows get a padlock where the checkbox would be: lumac
            // cannot remove them, so offering a tick would be a lie.
            Group {
                if item.locked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.fg(0.35))
                        .help("lumac 无法删除这一项")
                } else {
                    Button(action: onToggle) {
                        Image(systemName: item.selected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(item.selected ? Palette.selBg : Palette.fg(0.35))
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 16, height: 16)

            Text(item.kind.label)
                .font(Typo.aux.weight(.medium))
                .foregroundStyle(Palette.fg(item.locked ? 0.5 : 0.82))
                .frame(width: 96, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(Trash.abbreviate(item.path))
                    .font(Typo.mono(11))
                    .foregroundStyle(Palette.fg(item.locked ? 0.5 : 0.7))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let caution = item.caution {
                    Text(caution)
                        .font(Typo.badge)
                        .foregroundStyle(Palette.fg(0.5))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 12)

            Text(Size.format(item.bytes))
                .font(Typo.mono(11, .medium))
                .foregroundStyle(Palette.fg(item.locked ? 0.5 : 0.7))
                .frame(width: 62, alignment: .trailing)
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 8)
        .background(hovering && !item.locked ? Palette.hover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !item.locked { onToggle() } }
        .onHover { hovering = $0 }
    }
}

// MARK: - Running / Done

private struct RunningStage: View {
    var model: UninstallModel

    var body: some View {
        VStack(spacing: 12) {
            if model.elevating {
                // Root-owned app handed to mo — it does its own ~40s leftover
                // scan, no parseable progress, so the bar is indeterminate.
                Text("正在通过管理员权限删除…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.fg)
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(Palette.selBg)
                    .frame(width: 260)
            } else {
                Text("正在移入废纸篓…")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Palette.fg)
                ProgressView(value: model.progress)
                    .progressViewStyle(.linear)
                    .tint(Palette.selBg)
                    .frame(width: 260)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DoneStage: View {
    var model: UninstallModel
    @State private var copied = false
    @State private var elevateNote: String?

    var body: some View {
        let outcome = model.outcome
        let trashedCount = outcome?.trashed.count ?? 0
        let failed = outcome?.failed ?? []
        // A failed uninstall is either: nothing moved at all, or — the case that
        // used to slip through as "success" — the app *bundle itself* failed
        // while only small leftovers got trashed. Removing the app is the whole
        // point, so if its bundle is still on disk, this is not a success.
        let appPath = model.selected?.path
        let appBundleFailed = appPath.map { p in failed.contains { $0.path == p } } ?? false
        let allFailed = (trashedCount == 0 && !failed.isEmpty) || appBundleFailed
        // Files owned by root can't be trashed by a self-signed, non-elevated
        // app however the TCC switches are set — the block is Unix ownership,
        // not Full Disk Access. Steer these to Terminal + sudo instead of the
        // (useless here) "go enable permissions" advice.
        let rootPaths = rootOwnedPaths(failed)
        let rootBlocked = !rootPaths.isEmpty

        return VStack(spacing: 12) {
            Image(systemName: allFailed ? "xmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 30))
                .foregroundStyle(allFailed ? Palette.danger : Palette.accentText)

            Text(allFailed ? "卸载未完成"
                           : "已移入废纸篓 \(Size.format(outcome?.freedBytes ?? 0))")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Palette.fg)

            if allFailed {
                // Surface the real reason — root ownership vs. a missing grant.
                Text(reason(failed, rootPaths: rootPaths))
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
                if allFailed && rootBlocked {
                    // The app is root-owned — FDA can't help. Hand it to mo,
                    // which elevates through its own Touch ID + sudoers rule;
                    // keep the manual command as a fallback.
                    SecondaryButton(title: model.elevating ? "正在删除…" : "用管理员权限删除") {
                        elevate()
                    }
                    .disabled(model.elevating)
                    SecondaryButton(title: copied ? "已复制 ✓" : "复制命令") {
                        copySudoCommand(rootPaths)
                    }
                } else if allFailed {
                    SecondaryButton(title: "去开启完全磁盘访问") { FullDiskAccess.openSettings() }
                } else {
                    SecondaryButton(title: "打开废纸篓") { Trash.openTrash() }
                }
                PrimaryButton(title: "返回列表") { model.reset() }
            }
            .padding(.top, 4)
        }
        .alert("提权删除", isPresented: Binding(
            get: { elevateNote != nil }, set: { if !$0 { elevateNote = nil } }
        )) {
            Button("好", role: .cancel) {}
        } message: {
            Text(elevateNote ?? "")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Removes the root-owned app via mo (Touch ID + its sudoers rule), then
    /// surfaces any failure. On success the view flips to "已移入废纸篓" on its
    /// own, since the app leaves `failed`.
    private func elevate() {
        Task {
            if let error = await model.uninstallViaMo() {
                elevateNote = error
            }
        }
    }

    /// Failed paths owned by another user (in practice root). lumac can't trash
    /// these as the logged-in user, but it can remove them through a one-shot
    /// admin authorization (see `elevate`), so they get their own message and
    /// buttons.
    private func rootOwnedPaths(_ failed: [(path: String, reason: String)]) -> [String] {
        let me = getuid()
        return failed.compactMap { f in
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: f.path),
                  let owner = attrs[.ownerAccountID] as? NSNumber,
                  owner.uint32Value != me else { return nil }
            return f.path
        }
    }

    /// A plain-language explanation built from the failure reasons.
    private func reason(_ failed: [(path: String, reason: String)], rootPaths: [String]) -> String {
        let raw = failed.first?.reason ?? ""

        // Root-owned files: TCC grants are irrelevant, elevation is the only way.
        if !rootPaths.isEmpty {
            let cmd = sudoCommand(rootPaths)
            let noun = rootPaths.count == 1 ? "这个文件属于系统（root）" : "这些文件属于系统（root）"
            return "\(noun)，需要管理员权限。点下面「用管理员权限删除」授权一次即可移入废纸篓；也可在终端手动：\n\(cmd)"
        }

        let permissionish = raw.localizedCaseInsensitiveContains("permission")
            || raw.localizedCaseInsensitiveContains("权限")
            || raw.contains("513") || raw.contains("257")
        if permissionish {
            return "没有权限移动这些文件。请在「系统设置 › 隐私与安全性」里给 lumac 开启完全磁盘访问，以及在「App 管理」里允许 lumac，然后重试。\n（\(raw)）"
        }
        return raw.isEmpty ? "没有文件被移除。" : raw
    }

    /// A `sudo mv … ~/.Trash/` line covering every root-owned path, each quoted.
    /// Moving to the Trash keeps the removal recoverable; the moved bundle stays
    /// root-owned, which only matters when the user later empties the Trash.
    /// `~` expands in the user's shell before sudo runs, so it points at the
    /// real user's Trash, not root's.
    private func sudoCommand(_ paths: [String]) -> String {
        "sudo mv " + paths.map { "\"\($0)\"" }.joined(separator: " ") + " ~/.Trash/"
    }

    private func copySudoCommand(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(sudoCommand(paths), forType: .string)
        copied = true
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
