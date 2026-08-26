import SwiftUI

/// First-run guide: what lumac is, the one permission it needs to see everything,
/// and the optional Touch ID gate. Shown once; re-openable from 设置.
struct OnboardingView: View {
    @Environment(AppState.self) private var app
    @State private var step = 0

    private var lastStep: Int { 2 }

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 32)
                .padding(.top, 36)

            Divider().overlay(Palette.line)

            HStack {
                // Step dots.
                HStack(spacing: 6) {
                    ForEach(0...lastStep, id: \.self) { i in
                        Circle()
                            .fill(i == step ? Palette.selBg : Palette.fgDecoration(0.18))
                            .frame(width: 6, height: 6)
                    }
                }
                Spacer()
                if step < lastStep {
                    if step > 0 {
                        Button("上一步") { step -= 1 }
                            .buttonStyle(.plain)
                            .font(Typo.body)
                            .foregroundStyle(Palette.fg(0.7))
                            .padding(.trailing, 6)
                    }
                    PrimaryButton(title: "下一步") { step += 1 }
                } else {
                    PrimaryButton(title: "开始使用") { app.didOnboard = true }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 520, height: 420)
        .background(Palette.bg)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case 0:  WelcomeStep()
        case 1:  FDAStep()
        default: FinishStep()
        }
    }
}

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Circle()
                .fill(Palette.selBg)
                .frame(width: 66, height: 66)
                .overlay(
                    MoonCrescent(color: Palette.selFg)
                        .frame(width: 34, height: 34)
                        .rotationEffect(.degrees(-18)))
            Text("欢迎使用 lumac")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Palette.fg)
            Text("监控这台 Mac 的状态，安全地清理缓存、卸载应用、释放空间。\n所有删除都会移入废纸篓，可以随时还原。")
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 400)
            Spacer()
        }
    }
}

private struct FDAStep: View {
    @Environment(AppState.self) private var app

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Palette.accentText)
            Text("开启完全磁盘访问")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.fg)
            Text("没有这个权限，扫描会漏掉邮件、浏览器和其他应用的缓存——能清的空间会少很多。\n在「系统设置 › 隐私与安全性 › 完全磁盘访问」里把 lumac 打开。")
                .font(Typo.body)
                .foregroundStyle(Palette.fg(0.7))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .frame(maxWidth: 420)

            HStack(spacing: 8) {
                if app.fdaGranted {
                    Label("已授权", systemImage: "checkmark.circle.fill")
                        .font(Typo.body)
                        .foregroundStyle(Palette.accentText)
                } else {
                    PrimaryButton(title: "打开系统设置") { FullDiskAccess.openSettings() }
                    SecondaryButton(title: "重新检查") { app.refreshFDA() }
                }
            }
            .padding(.top, 4)
            Spacer()
        }
    }
}

private struct FinishStep: View {
    @Environment(AppState.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 14) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 34))
                .foregroundStyle(Palette.accentText)
            Text("准备就绪")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Palette.fg)

            if Biometric.available {
                Text("删除类操作可以先用 Touch ID 确认，多一层保护。之后也能在设置里改。")
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.7))
                    .multilineTextAlignment(.center)
                    .lineSpacing(4)
                    .frame(maxWidth: 420)
                Toggle(isOn: $app.requireBiometric) {
                    Text("危险操作前用 Touch ID 确认")
                        .font(Typo.body)
                        .foregroundStyle(Palette.fg)
                }
                .toggleStyle(.switch)
                .tint(Palette.selBg)
                .frame(maxWidth: 320)
                .padding(.top, 2)
            } else {
                Text("一切就绪，开始体验吧。")
                    .font(Typo.body)
                    .foregroundStyle(Palette.fg(0.7))
            }
            Spacer()
        }
    }
}
