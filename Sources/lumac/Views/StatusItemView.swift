import AppKit
import QuartzCore

/// The menu bar item's content: the live memory-usage percentage plus two lines
/// of transfer rates.
///
/// Drawn with Core Animation rather than SwiftUI. An `NSHostingView` inside a
/// status item re-lays-out the whole item on every change, which measured at
/// roughly 1% CPU per frame; plain `CATextLayer`s are effectively free.
@MainActor
final class StatusItemView: NSView {

    private enum Layout {
        static let padding: CGFloat = 6
        static let gap: CGFloat = 7
        static let ramFontSize: CGFloat = 14
        static let ramWidth: CGFloat = 37
        static let rateFontSize: CGFloat = 10
        static let rateWidth: CGFloat = 62
    }

    private let ramLayer = CATextLayer()
    private let downLayer = CATextLayer()
    private let upLayer = CATextLayer()

    /// Kept so the colour can be reapplied when the appearance changes.
    private var lastRam: Double = 0

    var onClick: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        buildLayers()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Layout.padding * 2 + Layout.ramWidth + Layout.gap + Layout.rateWidth,
               height: NSStatusBar.system.thickness)
    }

    // MARK: - Layers

    private func buildLayers() {
        guard let root = layer else { return }

        ramLayer.font = NSFont.monospacedDigitSystemFont(ofSize: Layout.ramFontSize, weight: .semibold)
        ramLayer.fontSize = Layout.ramFontSize
        ramLayer.alignmentMode = .right
        ramLayer.truncationMode = .none
        root.addSublayer(ramLayer)

        for textLayer in [downLayer, upLayer] {
            textLayer.fontSize = Layout.rateFontSize
            textLayer.font = NSFont.monospacedSystemFont(ofSize: Layout.rateFontSize, weight: .bold)
            textLayer.alignmentMode = .left
            textLayer.foregroundColor = NSColor.white.cgColor
            textLayer.truncationMode = .none
            root.addSublayer(textLayer)
        }
    }

    override func layout() {
        super.layout()
        let height = bounds.height
        let scale = window?.backingScaleFactor ?? 2
        [ramLayer, downLayer, upLayer].forEach { $0.contentsScale = scale }

        // Memory number on the left, vertically centred.
        let ramHeight = Layout.ramFontSize + 3
        ramLayer.frame = CGRect(x: Layout.padding, y: (height - ramHeight) / 2,
                                width: Layout.ramWidth, height: ramHeight)

        // Two stacked rate lines to its right.
        let textX = Layout.padding + Layout.ramWidth + Layout.gap
        let lineHeight = Layout.rateFontSize + 1.5
        downLayer.frame = CGRect(x: textX, y: height / 2,
                                 width: Layout.rateWidth, height: lineHeight)
        upLayer.frame = CGRect(x: textX, y: height / 2 - lineHeight,
                               width: Layout.rateWidth, height: lineHeight)
    }

    // MARK: - Content

    /// `ram` is a percentage; rates arrive in mebibytes per second. Strings are
    /// fixed-width so the item does not jitter as the numbers change.
    func update(ram: Double, down: Double, up: Double) {
        lastRam = ram
        ramLayer.string = String(format: "%.0f%%", ram)
        ramLayer.foregroundColor = Self.ramColour(ram).cgColor
        downLayer.string = "↓ " + Self.format(down)
        upLayer.string = "↑ " + Self.format(up)
    }

    /// White while there is memory headroom, warming through amber to red as it
    /// fills: white < 60%, red ≥ 80%, a white→amber→red ramp in between.
    private static func ramColour(_ pct: Double) -> NSColor {
        let red = NSColor(srgbRed: 0.85, green: 0.26, blue: 0.17, alpha: 1)
        if pct < 60 { return .white }
        if pct >= 80 { return red }

        let t = (pct - 60) / 20            // 0…1 across the middle band
        let amber = (r: 1.0, g: 0.62, b: 0.0)
        if t < 0.5 {                       // white → amber
            let k = t / 0.5
            return NSColor(srgbRed: 1,
                           green: 1 + (amber.g - 1) * k,
                           blue: 1 + (amber.b - 1) * k,
                           alpha: 1)
        } else {                           // amber → red
            let k = (t - 0.5) / 0.5
            return NSColor(srgbRed: amber.r + (0.85 - amber.r) * k,
                           green: amber.g + (0.26 - amber.g) * k,
                           blue: amber.b + (0.17 - amber.b) * k,
                           alpha: 1)
        }
    }

    /// Full units, matching Stats: "0 KB/s", "12 KB/s", "1.5 MB/s". `mbs` is
    /// mebibytes per second.
    private static func format(_ mbs: Double) -> String {
        if mbs >= 1024 { return String(format: "%.1f GB/s", mbs / 1024) }
        if mbs >= 1 { return String(format: "%.1f MB/s", mbs) }
        return String(format: "%.0f KB/s", mbs * 1024)
    }

    // MARK: - Appearance

    /// The rate lines are always pure white; the memory number keeps its usage
    /// colour. Reapplied on appearance changes, since a `CALayer` holds a fixed
    /// `cgColor`.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
            guard let self else { return }
            self.downLayer.foregroundColor = NSColor.white.cgColor
            self.upLayer.foregroundColor = NSColor.white.cgColor
            self.ramLayer.foregroundColor = Self.ramColour(self.lastRam).cgColor
        }
    }

    // MARK: - Input

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }
}
