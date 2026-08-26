import SwiftUI

/// 操作记录 — lumac's own log of operations it actually carried out. Not `mo
/// history`, which also records dry-run previews (fired just by opening a scan
/// page) and never sees lumac's own Trash operations.
struct HistoryView: View {
    private var records: [HistoryRecord] { HistoryStore.shared.records }

    var body: some View {
        VStack(spacing: 12) {
            if records.isEmpty {
                MessageBlock(symbol: "clock.arrow.circlepath",
                             title: "还没有操作记录",
                             detail: "在这里可以看到 lumac 每一次清理、卸载与优化，以及释放了多少空间。")
            } else {
                Header(count: records.count)
                Card(padding: 0) {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(records) { record in
                                HistoryRow(record: record)
                                Hairline()
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                }
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
    }
}

private struct Header: View {
    var count: Int

    var body: some View {
        HStack {
            Text("最近 \(count) 次操作")
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
            Spacer()
            SecondaryButton(title: "打开废纸篓") { Trash.openTrash() }
        }
    }
}

private struct HistoryRow: View {
    var record: HistoryRecord
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: HistoryLabel.symbol(record.command))
                .font(.system(size: 13))
                .foregroundStyle(Palette.accentText)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(HistoryLabel.title(record.command))
                        .font(Typo.body)
                        .foregroundStyle(Palette.fg)
                    if let note = record.note, !note.isEmpty {
                        Text(note)
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                            .lineLimit(1)
                    } else if record.itemCount > 0 {
                        Text("\(record.itemCount) 项")
                            .font(Typo.aux)
                            .foregroundStyle(Palette.fg(0.58))
                    }
                }
                Text(HistoryLabel.time(record.date))
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
            }

            Spacer(minLength: 12)

            if record.freedBytes > 0 {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(Size.format(record.freedBytes))
                        .font(Typo.mono(13, .medium))
                        .foregroundStyle(Palette.accentText)
                    Text("释放")
                        .font(Typo.badge)
                        .foregroundStyle(Palette.fg(0.5))
                }
                .frame(width: 74, alignment: .trailing)
            }
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, Metrics.rowPaddingV)
        .background(hovering ? Palette.hover : Color.clear)
        .onHover { hovering = $0 }
    }
}

private struct MessageBlock: View {
    var symbol: String
    var title: String
    var detail: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.fg(0.5))
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(Palette.fg)
            Text(detail)
                .font(Typo.aux)
                .foregroundStyle(Palette.fg(0.58))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Maps a raw command name to the app's vocabulary and icon.
enum HistoryLabel {
    static func title(_ command: String) -> String {
        switch command {
        case "clean":     return "深度清理"
        case "uninstall": return "卸载应用"
        case "purge":     return "项目产物"
        case "installer": return "安装包清理"
        case "optimize":  return "系统优化"
        case "analyze":   return "磁盘分析"
        default:          return command
        }
    }

    static func symbol(_ command: String) -> String {
        switch command {
        case "clean":     return "trash"
        case "uninstall": return "square.grid.2x2"
        case "purge":     return "folder.badge.gearshape"
        case "installer": return "arrow.down.doc"
        case "optimize":  return "slider.horizontal.3"
        case "analyze":   return "chart.pie"
        default:          return "clock"
        }
    }

    /// A short, localized date-time like "08-26 20:41".
    static func time(_ date: Date) -> String {
        let out = DateFormatter()
        out.dateFormat = "MM-dd HH:mm"
        return out.string(from: date)
    }
}
