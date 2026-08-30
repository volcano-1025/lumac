import SwiftUI

/// Hairline divider — 0.5px everywhere.
struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle()
            .fill(Palette.line)
            .frame(width: vertical ? Metrics.hairline : nil,
                   height: vertical ? nil : Metrics.hairline)
    }
}

/// Opaque content-layer card. The navigation layer uses glass; content does not,
/// so the two layers stay visually separated.
struct Card<Content: View>: View {
    var padding: CGFloat = 14
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.bg, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Palette.line, lineWidth: Metrics.hairline)
            )
    }
}

struct CardTitle: View {
    var text: String
    var trailing: String?

    var body: some View {
        HStack(spacing: 8) {
            Text(text)
                .font(Typo.cardTitle)
                .foregroundStyle(Palette.fg)
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(Typo.aux)
                    .foregroundStyle(Palette.fg(0.58))
            }
        }
    }
}

/// Thin progress/meter bar used by the metric cards, list rows and run steps.
struct MeterBar: View {
    /// 0...1
    var value: Double
    var height: CGFloat = 4
    var tint: Color = Palette.selBg

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fgDecoration(0.08))
                Capsule()
                    .fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
                    .animation(.easeOut(duration: 0.3), value: value)
            }
        }
        .frame(height: height)
    }
}

/// Small rounded label: risk level, source, category.
struct Badge: View {
    var text: String
    var tint: Color = Palette.accentText
    var fill: Color = Palette.accentSoft

    var body: some View {
        Text(text)
            .font(Typo.badge)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Primary action button — filled with the selection colour.
struct PrimaryButton: View {
    var title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Palette.selFg)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(Palette.selBg, in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// A primary button that is also the progress indicator for the work it is
/// waiting on.
///
/// The uninstall preview has exactly one control and exactly one thing the user
/// is waiting for, so the wait belongs on the control rather than in a dialog
/// over the list they are trying to read.
struct ProgressPrimaryButton: View {
    var title: String
    /// 0...1.
    var progress: Double

    var body: some View {
        Text(title)
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Palette.selFg)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .frame(minWidth: 150)
            .background {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Palette.selBg.opacity(0.35))
                        Capsule()
                            .fill(Palette.selBg)
                            .frame(width: geo.size.width * max(0, min(1, progress)))
                    }
                }
            }
            .clipShape(Capsule())
            .animation(.easeOut(duration: 0.3), value: progress)
    }
}

/// Secondary action — outlined, sits on the content layer.
struct SecondaryButton: View {
    var title: String
    var destructive = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12.5))
                .foregroundStyle(destructive ? Palette.danger : Palette.fg(0.8))
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay(Capsule().strokeBorder(Palette.line, lineWidth: Metrics.hairline))
        }
        .buttonStyle(.plain)
    }
}

/// The lumac crescent, drawn as a vector so it stays crisp at any size — an
/// outer disc with an offset disc punched out, matching the app icon's motif.
/// Used on the round brand button and the onboarding splash.
struct MoonCrescent: View {
    var color: Color = .white
    /// How far the cut disc is shifted, as a fraction of the diameter. Larger =
    /// thinner crescent. 0.28 mirrors the app icon's geometry.
    var thinness: CGFloat = 0.28

    var body: some View {
        GeometryReader { geo in
            let d = min(geo.size.width, geo.size.height)
            ZStack {
                Circle().fill(color)
                Circle().fill(color)
                    .offset(x: d * thinness)
                    .blendMode(.destinationOut)
            }
            .frame(width: d, height: d)
            .compositingGroup()
        }
        .aspectRatio(1, contentMode: .fit)
    }
}

/// Ring gauge — health score and the accessory battery rings.
struct Ring: View {
    var value: Double          // 0...1
    var size: CGFloat
    var lineWidth: CGFloat
    var tint: Color = Palette.selBg
    var label: String?

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Palette.fgDecoration(0.10), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0, min(1, value)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                .animation(.easeOut(duration: 0.4), value: value)
            if let label {
                Text(label)
                    .font(Typo.mono(size * 0.26, .medium))
                    .foregroundStyle(Palette.fg)
            }
        }
        .frame(width: size, height: size)
    }
}
