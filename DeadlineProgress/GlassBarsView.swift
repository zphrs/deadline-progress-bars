import AppKit

struct BarRow {
    var text: String
    var percent: Double
    var colors: BarColors
    var prefix: String
}

/// Experimental: draws the bars as live Liquid Glass views (macOS 26+) instead of a flat image.
final class GlassBarsView: NSView {
    static let saturationBoost: CGFloat = 1.5
    static let contentOpacity: CGFloat = 0.6

    private(set) var contentWidth: CGFloat = 0
    private var rows: [BarRow] = []

    override func hitTest(_ point: NSPoint) -> NSView? { nil }  // let the status button take clicks

    // The fill-text color is computed once per build, so rebuild when the menu bar tint flips.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        update(rows: rows)
    }

    func update(rows: [BarRow]) {
        self.rows = rows
        subviews.forEach { $0.removeFromSuperview() }
        let stacked = rows.count > 1
        let style = stacked ? BarRenderer.Style(fontSize: 10, barHeight: 10, canvasHeight: 11) : BarRenderer.Style()
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        let prefixFont = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        let prefixWidth = rows.map { ceil(($0.prefix as NSString).size(withAttributes: [.font: prefixFont]).width) }.max() ?? 0
        let offset: CGFloat = prefixWidth > 0 ? prefixWidth + 4 : 0
        let barWidth = rows.map { BarRenderer.naturalWidth(text: $0.text, style: style) }.max() ?? 0
        contentWidth = offset + barWidth
        frame = NSRect(x: 0, y: 0, width: contentWidth, height: 22)

        for (i, row) in rows.enumerated() {
            let y = CGFloat(rows.count - 1 - i) * style.canvasHeight
            addRow(row, y: y, style: style, font: font, prefixFont: prefixFont, offset: offset, barWidth: barWidth)
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.sizeToFit()
        return field
    }

    private func addRow(_ row: BarRow, y: CGFloat, style: BarRenderer.Style, font: NSFont,
                        prefixFont: NSFont, offset: CGFloat, barWidth: CGFloat) {
        let h = style.barHeight
        let barY = y + (style.canvasHeight - h) / 2
        let percent = min(max(row.percent, 0), 100)
        let split = barWidth * percent / 100
        let radius = h / 3

        if !row.prefix.isEmpty {
            let prefix = label(row.prefix, font: prefixFont, color: .labelColor)
            prefix.setFrameOrigin(NSPoint(x: 0, y: y + (style.canvasHeight - prefix.frame.height) / 2))
            addSubview(prefix)
        }

        // Track and tinted fill share one container so the glass views blend instead of the fill vanishing.
        let barFrame = NSRect(x: offset, y: barY, width: barWidth, height: h)
        let container = NSGlassEffectContainerView(frame: barFrame)
        container.spacing = h
        let stack = NSView(frame: NSRect(origin: .zero, size: barFrame.size))

        let track = NSGlassEffectView(frame: stack.bounds)
        track.cornerRadius = radius
        stack.addSubview(track)

        let base = row.colors.color(at: percent)
        let tint = BarRenderer.glassTint(base, saturationBoost: Self.saturationBoost)
        let shown = tint.withAlphaComponent(Self.contentOpacity * base.alphaComponent)
        if split > 0 {
            let inset: CGFloat = 2
            let fillRadius = max(0, radius - inset)
            let fill = NSGlassEffectView(frame: NSRect(x: inset, y: inset, width: max(h, split) - 2 * inset, height: h - 2 * inset))
            fill.cornerRadius = fillRadius
            fill.tintColor = BarRenderer.glassTint(base, saturationBoost: Self.saturationBoost)

            // tintColor alone renders gray in the status-bar window, so also colour the glass's content.
            let color = NSView(frame: fill.bounds)
            color.wantsLayer = true
            color.layer?.backgroundColor = shown.cgColor
            color.layer?.cornerRadius = fillRadius
            fill.contentView = color
            stack.addSubview(fill)
        }
        container.contentView = stack
        addSubview(container)

        // Text: black or white over the filled part, normal over the rest.
        let sample = label(row.text, font: font, color: .labelColor)
        let textOrigin = NSPoint(x: (barWidth - sample.frame.width) / 2, y: (style.canvasHeight - sample.frame.height) / 2)
        func clipped(_ color: NSColor, x: CGFloat, width: CGFloat) {
            let clip = NSView(frame: NSRect(x: offset + x, y: y, width: width, height: style.canvasHeight))
            clip.wantsLayer = true
            clip.layer?.masksToBounds = true
            let text = label(row.text, font: font, color: color)
            text.setFrameOrigin(NSPoint(x: textOrigin.x - x, y: textOrigin.y))
            clip.addSubview(text)
            addSubview(clip)
        }
        clipped(tint.contrastingText(over: NSAppearance.menuBarBackdrop(for: effectiveAppearance)), x: 0, width: max(h, split))
        clipped(.labelColor, x: max(h, split), width: barWidth - max(h, split))
    }
}
