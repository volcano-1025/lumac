import SwiftUI
import AppKit

/// The design system, and now its only home: every value below was
/// transcribed from the original design handoff, which has since been
/// removed (it described pages that no longer exist and a data flow the app
/// does not use). Recover it from git if the visual reference is ever needed:
/// `git show 9a0ad1e:design_handoff_mole_ui/README.md`.
/// Colors are dynamic (NSColor providers) so light/dark switch without view churn.

private func dyn(_ light: NSColor, _ dark: NSColor) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    })
}

private extension NSColor {
    /// #rrggbb or #rrggbb with alpha, in sRGB.
    convenience init(hex: UInt32, alpha: CGFloat = 1) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: alpha)
    }
}

enum Palette {
    /// Card / popover base.
    static let bg = dyn(NSColor(hex: 0xfbfbfc), NSColor(hex: 0x1c1e21))
    /// Content layer — slightly translucent so the wallpaper tints it.
    static let content = dyn(NSColor(hex: 0xfbfbfc, alpha: 0.80), NSColor(hex: 0x1f1e1c, alpha: 0.74))
    /// Secondary panels, empty-state icon wells.
    static let panel = dyn(NSColor(hex: 0xeceef1), NSColor(hex: 0x17191c))
    /// Row hover.
    static let hover = dyn(NSColor(hex: 0xf2f4f6), NSColor(hex: 0x24272b))
    /// Primary text.
    static let fg = dyn(NSColor(hex: 0x1b1d21), NSColor(hex: 0xe8eaee))
    /// Selection and primary buttons.
    static let selBg = dyn(NSColor(hex: 0x4a5763), NSColor(hex: 0x7d8b99))
    static let selFg = dyn(NSColor(hex: 0xffffff), NSColor(hex: 0x16181b))
    /// Accent text — holds >= 4.5:1 on both content layers.
    static let accentText = dyn(NSColor(hex: 0x3c4855), NSColor(hex: 0xa8b6c4))
    static let accentSoft = dyn(NSColor(hex: 0x4a5763, alpha: 0.10), NSColor(hex: 0x7d8b99, alpha: 0.18))
    /// Destructive: delete, low battery, high-risk tags. Same in both themes.
    static let danger = Color(nsColor: NSColor(hex: 0xa8412c))
    /// Hairline separators.
    static let line = dyn(NSColor(hex: 0x1b1d21, alpha: 0.09), NSColor(hex: 0xe8eaee, alpha: 0.10))

    /// Foreground at reduced opacity. The README floors low-contrast text at .58.
    static func fg(_ alpha: Double) -> Color { fg.opacity(max(alpha, 0.58)) }
    /// Explicitly allows going below the .58 floor for non-text decoration only.
    static func fgDecoration(_ alpha: Double) -> Color { fg.opacity(alpha) }
}

/// Concentric corner radii: window 19 -> popover 18 -> capsule 15 -> card 14 -> list 13 -> sidebar item 9.
enum Radius {
    static let window: CGFloat = 19
    static let popover: CGFloat = 18
    static let capsule: CGFloat = 15
    static let card: CGFloat = 14
    static let list: CGFloat = 13
    static let sidebarItem: CGFloat = 9
}

enum Metrics {
    static let windowWidth: CGFloat = 1180
    static let windowHeight: CGFloat = 772
    static let toolbarHeight: CGFloat = 52
    static let sidebarWidth: CGFloat = 232
    static let sidebarItemHeight: CGFloat = 34
    static let contentPadding: CGFloat = 26
    /// Fixed left-column width of the 健康 card.
    static let dashLeftColumn: CGFloat = 250
    /// Fixed height of every card in the 网络/CPU/GPU · 电池/内存/磁盘 grid, so all
    /// six align exactly. Tall enough that no card's content overflows and bleeds
    /// into the gaps. 健康 spans two of these plus the row gap.
    static let dashCardHeight: CGFloat = 120
    static var dashGridHeight: CGFloat { dashCardHeight * 2 + 12 }
    static let rowPaddingH: CGFloat = 15
    static let rowPaddingV: CGFloat = 14
    static let hairline: CGFloat = 0.5
    static let hudWidth: CGFloat = 296
}

enum Typo {
    static let pageTitle = Font.system(size: 20, weight: .semibold)
    static let pageSub = Font.system(size: 12)
    static let cardTitle = Font.system(size: 13, weight: .medium)
    static let body = Font.system(size: 12.5)
    static let aux = Font.system(size: 11)
    static let badge = Font.system(size: 10.5, weight: .medium)

    /// Numerals and byte sizes use SF Mono (the original prototype used JetBrains Mono).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
