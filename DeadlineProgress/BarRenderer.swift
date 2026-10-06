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
}
