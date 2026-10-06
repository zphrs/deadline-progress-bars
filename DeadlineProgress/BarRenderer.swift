import AppKit

enum BarRenderer {
    /// Glass washes tints out, so push saturation up and brightness down a little to keep the hue visible.
    static func glassTint(_ color: NSColor, saturationBoost: CGFloat = 1.5) -> NSColor {
        guard let c = color.usingColorSpace(.sRGB) else { return color }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return NSColor(hue: h, saturation: min(1, s * saturationBoost), brightness: b * 0.92, alpha: a)
    }

    static let defaultFormat = "{time} | {percent}%"

    /// Fills the user's label template. `{time}` is Notion's time-left text, `{percent}` is the progress to one decimal.
    static func label(timeLeft: String, percent: Double) -> String {
        let time = timeLeft.split(separator: " ").joined(separator: " ")
        let template = Settings.labelFormat.isEmpty ? defaultFormat : Settings.labelFormat
        return template
            .replacingOccurrences(of: "{time}", with: time)
            .replacingOccurrences(of: "{percent}", with: String(format: "%.1f", percent))
    }

    struct Style {
        var fontSize: CGFloat = 11
        var barHeight: CGFloat = 16
        var canvasHeight: CGFloat = 22
    }

    static func naturalWidth(text: String, style: Style = Style()) -> CGFloat {
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .medium)
        return ceil((text as NSString).size(withAttributes: [.font: font]).width) + 14
    }

    /// A bar with the label drawn inside: black or white over the filled part, normal over the rest.
    /// `width` defaults to the width needed by the text.
    static func image(text: String, percent: Double, colors: BarColors,
                      style: Style = Style(), width: CGFloat? = nil, prefix: String = "",
                      prefixWidth: CGFloat? = nil) -> NSImage {
        let clamped = min(max(percent, 0), 100)
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .medium)
        let size = (text as NSString).size(withAttributes: [.font: font])
        let height = style.canvasHeight
        let barHeight = style.barHeight
        let width = width ?? naturalWidth(text: text, style: style)
        let fill = colors.color(at: clamped)
        let prefixFont = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        let prefixAttrs: [NSAttributedString.Key: Any] = [.font: prefixFont, .foregroundColor: NSColor.labelColor]
        let prefixSize = (prefix as NSString).size(withAttributes: prefixAttrs)
        let offset = prefix.isEmpty ? 0 : (prefixWidth ?? ceil(prefixSize.width)) + 4
        return NSImage(size: NSSize(width: offset + width, height: height), flipped: false) { _ in
            if !prefix.isEmpty {
                (prefix as NSString).draw(at: NSPoint(x: 0, y: (height - prefixSize.height) / 2), withAttributes: prefixAttrs)
            }
            NSGraphicsContext.current?.cgContext.translateBy(x: offset, y: 0)
            let track = NSRect(x: 0, y: (height - barHeight) / 2, width: width, height: barHeight)
            let shape = NSBezierPath(roundedRect: track, xRadius: barHeight / 3, yRadius: barHeight / 3)
            NSGradient(starting: NSColor.labelColor.withAlphaComponent(0.10),
                       ending: NSColor.labelColor.withAlphaComponent(0.26))?.draw(in: shape, angle: -90)

            let split = width * clamped / 100
            let origin = NSPoint(x: (width - size.width) / 2, y: (height - size.height) / 2)
            func drawText(_ color: NSColor, clippedTo clip: NSRect) {
                NSGraphicsContext.saveGraphicsState()
                shape.addClip()
                NSBezierPath(rect: clip).addClip()
                (text as NSString).draw(at: origin, withAttributes: [.font: font, .foregroundColor: color])
                NSGraphicsContext.restoreGraphicsState()
            }

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            // highlight/shadow drop the alpha, so a transparent stop would turn opaque black.
            let alpha = fill.alphaComponent
            NSGradient(starting: (fill.highlight(withLevel: 0.3) ?? fill).withAlphaComponent(alpha),
                       ending: (fill.shadow(withLevel: 0.12) ?? fill).withAlphaComponent(alpha))?
                .draw(in: NSRect(x: 0, y: track.minY, width: split, height: barHeight), angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            NSColor.labelColor.withAlphaComponent(0.3).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let rim = NSBezierPath(roundedRect: track.insetBy(dx: 0.75, dy: 0.75),
                                   xRadius: barHeight / 3, yRadius: barHeight / 3)
            NSColor.white.withAlphaComponent(0.45).setStroke()
            rim.lineWidth = 0.75
            rim.stroke()
            NSGraphicsContext.restoreGraphicsState()

            // Runs at draw time, so currentDrawing() is the status button's (menu bar's) appearance.
            let backdrop = NSAppearance.menuBarBackdrop(for: NSAppearance.currentDrawing())
            drawText(fill.contrastingText(over: backdrop), clippedTo: NSRect(x: 0, y: 0, width: split, height: height))
            drawText(.labelColor, clippedTo: NSRect(x: split, y: 0, width: width - split, height: height))
            return true
        }
    }

    /// Two equal-width bars, one above the other, in a single menu-bar image.
    static func stacked(top: (text: String, percent: Double, colors: BarColors, prefix: String),
                        bottom: (text: String, percent: Double, colors: BarColors, prefix: String)) -> NSImage {
        let style = Style(fontSize: 10, barHeight: 10, canvasHeight: 11)
        let width = max(naturalWidth(text: top.text, style: style), naturalWidth(text: bottom.text, style: style))
        let font = NSFont.monospacedDigitSystemFont(ofSize: style.fontSize, weight: .regular)
        let prefixWidth = ceil(([top.prefix, bottom.prefix].max(by: { $0.count < $1.count })! as NSString)
            .size(withAttributes: [.font: font]).width)
        let a = image(text: top.text, percent: top.percent, colors: top.colors, style: style, width: width,
                      prefix: top.prefix, prefixWidth: prefixWidth)
        let b = image(text: bottom.text, percent: bottom.percent, colors: bottom.colors, style: style,
                      width: width, prefix: bottom.prefix, prefixWidth: prefixWidth)
        return NSImage(size: NSSize(width: a.size.width, height: 22), flipped: false) { _ in
            a.draw(at: NSPoint(x: 0, y: 11), from: .zero, operation: .sourceOver, fraction: 1)
            b.draw(at: NSPoint(x: 0, y: 0), from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
    }
}
