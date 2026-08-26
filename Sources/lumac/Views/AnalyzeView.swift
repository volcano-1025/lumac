import SwiftUI
import AppKit

/// 磁盘分析 — `mo analyze -json`. Browse the disk by size, drill into folders,
/// reveal anything in Finder, and move a stray file to the Trash.
struct AnalyzeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.analyzeModel
        VStack(spacing: 12) {
            if case .failed(let why) = model.phase {
                FailedBlock(reason: why) { model.rescan() }
            } else if model.phase == .loaded {
                // Only a completed listing is shown; while a scan or drill is in
                // flight the loading block stands in, so stale sizes never read
                // as the current directory's.
                Header(model: model)
                EntryList(model: model)
                FootNote()
            } else {
                LoadingBlock()
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
        .task { model.loadIfNeeded() }
    }
}

// MARK: - Header (breadcrumb + mode + rescan)

private struct Header: View {
    var model: AnalyzeModel

    var body: some View {
        HStack(spacing: 10) {
            Breadcrumb(model: model)
            Spacer(minLength: 12)
            if let total = model.result.totalSize, model.atRoot {
                Text("共 \(Size.format(total))")
                    .font(Typo.mono(12, .medium))
                    .foregroundStyle(Palette.accentText)
            }
            ModePicker(mode: model.mode) { model.mode = $0 }
            SecondaryButton(title: "重新扫描") { model.rescan() }
        }
    }
}

private struct Breadcrumb: View {
    var model: AnalyzeModel

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(model.trail.enumerated()), id: \.offset) { index, crumb in
                if index > 0 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Palette.fg(0.35))
                }
                Button { model.jump(to: index) } label: {
                    Text(crumb.name)
                        .font(Typo.body)
                        .foregroundStyle(index == model.trail.count - 1
                                         ? Palette.fg : Palette.accentText)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .disabled(index == model.trail.count - 1)
            }
        }
    }
}

/// 按目录 / 大文件 segmented control, matching the content-layer pill styling.
private struct ModePicker: View {
    var mode: AnalyzeModel.Mode
    var select: (AnalyzeModel.Mode) -> Void

    var body: some View {
        HStack(spacing: 3) {
            segment("按目录", .directories)
            segment("大文件", .files)
        }
        .padding(3)
        .background(Palette.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
    }

    private func segment(_ title: String, _ value: AnalyzeModel.Mode) -> some View {
        let on = mode == value
        return Button { select(value) } label: {
            Text(title)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Palette.selFg : Palette.fg(0.7))
                .padding(.horizontal, 13)
                .frame(height: 26)
                .background { if on { Capsule().fill(Palette.selBg) } }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - List

private struct EntryList: View {
    var model: AnalyzeModel
    @State private var pendingTrash: AnalyzeEntry?

    var body: some View {
        Card(padding: 0) {
            if model.rows.isEmpty {
                Text(model.mode == .files ? "这个位置没有单独的大文件" : "这个位置是空的")
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.58))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .frame(minHeight: 200)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, entry in
                            EntryRow(entry: entry,
                                     rank: index + 1,
                                     share: share(of: entry),
                                     onOpen: { open(entry) },
                                     onTrash: { pendingTrash = entry })
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .alert("移入废纸篓", isPresented: .init(
            get: { pendingTrash != nil },
            set: { if !$0 { pendingTrash = nil } })
        ) {
            Button("移入废纸篓", role: .destructive) {
                if let entry = pendingTrash { trash(entry) }
                pendingTrash = nil
            }
            Button("取消", role: .cancel) { pendingTrash = nil }
        } message: {
            Text("将「\(pendingTrash?.name ?? "")」移入废纸篓，可以随时还原。")
        }
    }

    private func share(of entry: AnalyzeEntry) -> Double {
        let largest = model.maxSize
        return largest > 0 ? Double(entry.size) / Double(largest) : 0
    }

    /// Directories drill in; files are revealed in Finder.
    private func open(_ entry: AnalyzeEntry) {
        if entry.isDir {
            model.open(entry)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.path)])
        }
    }

    private func trash(_ entry: AnalyzeEntry) {
        Task {
            _ = await Trash.run(paths: [entry.path]) { _, _ in }
            // Refresh the current listing so the removed row disappears.
            model.jump(to: model.trail.count - 1)
        }
    }
}

private struct EntryRow: View {
    var entry: AnalyzeEntry
    var rank: Int
    var share: Double
    var onOpen: () -> Void
    var onTrash: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Text("\(rank)")
                .font(Typo.mono(11))
                .foregroundStyle(Palette.fg(0.4))
                .frame(width: 22, alignment: .trailing)

            Image(systemName: entry.isDir ? "folder" : "doc")
                .font(.system(size: 13))
                .foregroundStyle(Palette.accentText)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.name)
                        .font(Typo.body)
                        .foregroundStyle(Palette.fg)
                        .lineLimit(1)
                    if entry.insight == true {
                        Badge(text: "可清理")
                    }
                }
                if let sub = subtitle {
                    Text(sub)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            // A trash affordance appears on hover; browsing stays the default.
            if hovering {
                Button(action: onTrash) {
                    Image(systemName: "trash")
                        .font(.system(size: 12))
                        .foregroundStyle(Palette.danger)
                }
                .buttonStyle(.plain)
                .help("移入废纸篓")
            }

            MeterBar(value: share, height: 4)
                .frame(width: 92)

            Text(Size.format(entry.size))
                .font(Typo.mono(12, .medium))
                .foregroundStyle(Palette.fg)
                .frame(width: 68, alignment: .trailing)

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(entry.isDir ? Palette.fg(0.35) : Color.clear)
                .frame(width: 10)
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
        .background(hovering ? Palette.hover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
        .help(entry.path)
    }

    /// Files show when they were last opened; directories show their path.
    private var subtitle: String? {
        if entry.isDir { return Trash.abbreviate(entry.path) }
        guard let iso = entry.lastAccess, let days = Self.daysAgo(iso) else {
            return Trash.abbreviate(entry.path)
        }
        if days <= 0 { return "今天用过" }
        if days == 1 { return "昨天用过" }
        if days < 30 { return "\(days) 天前用过" }
        if days < 365 { return "\(days / 30) 个月前用过" }
        return "超过一年没用过"
    }

    private static func daysAgo(_ iso: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return nil }
        return Calendar.current.dateComponents([.day], from: date, to: Date()).day
    }
}

// MARK: - Supporting states

private struct FootNote: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(Palette.fg(0.5))
            Text("点击文件夹可以继续深入，点击文件在访达中显示；移入废纸篓后可随时还原。")
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
            Spacer()
        }
    }
}

private struct LoadingBlock: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.small)
            Text("正在统计磁盘占用…")
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.58))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct FailedBlock: View {
    var reason: String
    var retry: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.danger)
            Text("扫描没有完成")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.fg)
            Text(reason)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            SecondaryButton(title: "重试") { retry() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
