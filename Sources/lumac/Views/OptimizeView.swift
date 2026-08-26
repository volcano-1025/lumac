import SwiftUI

/// 系统优化 — `mo optimize`. Previews the maintenance steps, runs them on demand,
/// and shows the outcome. Nothing here deletes personal files.
struct OptimizeView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        let model = app.optimizeModel
        Group {
            switch model.phase {
            case .loading:
                Loading(text: "正在检查可优化的项目…")
            case .failed(let why):
                Failed(reason: why) { model.preview() }
            case .ready:
                StepList(model: model, running: false)
            case .running:
                StepList(model: model, running: true)
            case .done:
                StepList(model: model, running: false, done: true)
            }
        }
        .padding(.horizontal, Metrics.contentPadding)
        .padding(.bottom, Metrics.contentPadding)
        .task { model.loadIfNeeded() }
    }
}

private struct StepList: View {
    var model: OptimizeModel
    var running: Bool
    var done = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Header(model: model, running: running, done: done)

            Card(padding: 0) {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.result.tasks) { task in
                            StepRow(task: task)
                            Hairline()
                        }
                    }
                }
                .scrollIndicators(.hidden)
            }

            HStack(spacing: 8) {
                Image(systemName: "leaf")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.accentText)
                Text("只重建缓存、刷新服务与索引，不会删除任何个人文件。")
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
                Spacer()

                if done {
                    SecondaryButton(title: "再次检查") { model.preview() }
                } else {
                    PrimaryButton(title: running ? "优化中…" : "开始优化") { confirming = true }
                        .disabled(running)
                        .opacity(running ? 0.5 : 1)
                }
            }
        }
        .confirmationDialog("开始系统优化", isPresented: $confirming) {
            Button("开始优化") { model.optimize() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将重建缓存、刷新服务与索引。这不会删除个人文件，过程可能需要一会儿。")
        }
    }
}

private struct Header: View {
    var model: OptimizeModel
    var running: Bool
    var done: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.fg)
                if let summary = model.result.summary, done {
                    Text(summary)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                } else {
                    Text("共 \(model.result.tasks.count) 项维护检查")
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                }
            }
            Spacer()
            if running { ProgressView().controlSize(.small) }
        }
    }

    private var title: String {
        if done { return "优化完成" }
        if running { return "正在优化…" }
        return "这些维护项会执行"
    }
}

private struct StepRow: View {
    var task: OptimizeTask

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(task.title)
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg)
                // The detail lines are phrased as accomplished facts ("已刷新"),
                // so they only make sense after a real run — in the preview they
                // would read as if the work were already done.
                if task.outcome != .plan, !task.detail.isEmpty {
                    Text(task.detail)
                        .font(Typo.aux)
                        .foregroundStyle(Palette.fg(0.58))
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, Metrics.rowPaddingH)
        .padding(.vertical, 11)
    }

    private var icon: String {
        switch task.outcome {
        case .plan: return "circle"
        case .ok:   return "checkmark.circle.fill"
        case .warn: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch task.outcome {
        case .plan: return Palette.fg(0.4)
        case .ok:   return Palette.accentText
        case .warn: return Palette.danger
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

private struct Failed: View {
    var reason: String
    var retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(Palette.danger)
            Text("检查失败")
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
