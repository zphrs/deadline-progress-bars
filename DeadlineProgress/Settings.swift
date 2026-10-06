import AppKit
import Foundation
import Security

struct ColorStop: Codable, Equatable {
    var from: Double
    var hex: String  // "#RRGGBBAA", sRGB
}

struct BarColors: Codable, Equatable {
    var stops: [ColorStop]  // sorted by `from`; first stop is always 0
    var blend: Bool

    static let deadlineDefault = BarColors(stops: [
        ColorStop(from: 0, hex: "#86B59EFF"),
        ColorStop(from: 33, hex: "#DCA11DFF"),
        ColorStop(from: 66, hex: "#FF8C54FF"),
    ], blend: false)

    static let dailyDefault = BarColors(
        stops: deadlineDefault.stops + [ColorStop(from: 100, hex: "#00000000")], blend: false)

    func color(at percent: Double) -> NSColor {
        guard let first = stops.first else { return .systemGray }
        let idx = stops.lastIndex(where: { $0.from <= percent }) ?? 0
        let base = NSColor(hex: stops[idx].hex) ?? .systemGray
        guard blend, percent > first.from, idx + 1 < stops.count,
              let next = NSColor(hex: stops[idx + 1].hex) else { return base }
        let span = stops[idx + 1].from - stops[idx].from
        guard span > 0 else { return base }
        return base.blended(withFraction: (percent - stops[idx].from) / span, of: next) ?? base
    }
}

extension NSColor {
    convenience init?(hex: String) {
        var h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if h.count == 6 { h += "FF" }
        guard h.count == 8, let v = UInt32(h, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat(v >> 24) / 255, green: CGFloat((v >> 16) & 0xFF) / 255,
                  blue: CGFloat((v >> 8) & 0xFF) / 255, alpha: CGFloat(v & 0xFF) / 255)
    }

    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", b(c.redComponent), b(c.greenComponent), b(c.blueComponent), b(c.alphaComponent))
    }

    /// Black or white, whichever has the higher APCA contrast against this color alpha-blended over `backdrop`.
    /// (WCAG 2 picks black on mid-tone oranges, where white reads better.)
    /// A clear fill shows the menu bar through it, so its text matches the rest of the menu bar.
    func contrastingText(over backdrop: NSColor) -> NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let bg = backdrop.usingColorSpace(.sRGB) ?? backdrop
        let a = c.alphaComponent
        if a == 0 { return .labelColor }
        func lin(_ x: CGFloat, _ b: CGFloat) -> CGFloat { pow(min(max(x * a + b * (1 - a), 0), 1), 2.4) }
        var y = 0.2126729 * lin(c.redComponent, bg.redComponent)
            + 0.7151522 * lin(c.greenComponent, bg.greenComponent)
            + 0.0721750 * lin(c.blueComponent, bg.blueComponent)
        if y < 0.022 { y += pow(0.022 - y, 1.414) }
        let black = pow(pow(0.022, 1.414), 0.57)  // soft-clamped luminance of black text
        // Scale and offset are the same for both polarities, so compare the raw terms.
        return pow(y, 0.56) - black >= 1 - pow(y, 0.65) ? .black : .white
    }
}

extension NSAppearance {
    /// What shows through a translucent fill: black under a dark menu bar, white under a light one.
    static func menuBarBackdrop(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
    }
}

enum Settings {
    static var deadlineColors: BarColors {
        get { loadColors("deadlineColors") ?? .deadlineDefault }
        set { saveColors(newValue, "deadlineColors") }
    }

    static var dailyColors: BarColors {
        get { loadColors("dailyColors") ?? .dailyDefault }
        set { saveColors(newValue, "dailyColors") }
    }

    private static func loadColors(_ key: String) -> BarColors? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let colors = try? JSONDecoder().decode(BarColors.self, from: data),
              !colors.stops.isEmpty else { return nil }
        return colors
    }

    private static func saveColors(_ colors: BarColors, _ key: String) {
        UserDefaults.standard.set(try? JSONEncoder().encode(colors), forKey: key)
    }

    private static let service = "dev.zphrs.DeadlineProgress"
    private static let account = "notion-token"
    private static let selectedKey = "selectedDeadlineID"

    static var token: String? {
        get {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
            ]
            var out: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
                  let data = out as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        }
        set {
            let base: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(base as CFDictionary)
            guard let newValue, !newValue.isEmpty else { return }
            var add = base
            add[kSecValueData as String] = Data(newValue.utf8)
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    /// Accepts a bare ID or a pasted Notion URL (uses the trailing 32 hex digits before any query string).
    private static func notionID(from input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let hex = trimmed.split(separator: "?").first.map { $0.replacingOccurrences(of: "-", with: "") } ?? ""
        return hex.count >= 32 ? String(hex.suffix(32)) : trimmed
    }

    /// A data source ID, or a database ID / pasted database URL that `Notion` resolves to all of its data sources.
    static var dataSourceID: String {
        get { UserDefaults.standard.string(forKey: "dataSourceID") ?? "" }
        set { UserDefaults.standard.set(notionID(from: newValue), forKey: "dataSourceID") }
    }

    static var dailyPageID: String {
        get { UserDefaults.standard.string(forKey: "dailyPageID") ?? "" }
        set { UserDefaults.standard.set(notionID(from: newValue), forKey: "dailyPageID") }
    }

    /// Label template; empty means `BarRenderer.defaultFormat`.
    static var labelFormat: String {
        get { UserDefaults.standard.string(forKey: "labelFormat") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "labelFormat") }
    }

    /// Defaults to on when never set.
    static var showLabels: Bool {
        get { UserDefaults.standard.object(forKey: "showLabels") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "showLabels") }
    }

    static var dailyOnTop: Bool {
        get { UserDefaults.standard.bool(forKey: "dailyOnTop") }
        set { UserDefaults.standard.set(newValue, forKey: "dailyOnTop") }
    }

    /// Experimental Liquid Glass rendering.
    static var useGlass: Bool {
        get { UserDefaults.standard.bool(forKey: "useGlass") }
        set { UserDefaults.standard.set(newValue, forKey: "useGlass") }
    }

    static var stackBars: Bool {
        get { UserDefaults.standard.bool(forKey: "stackBars") }
        set { UserDefaults.standard.set(newValue, forKey: "stackBars") }
    }

    static var selectedDeadlineID: String? {
        get { UserDefaults.standard.string(forKey: selectedKey) }
        set { UserDefaults.standard.set(newValue, forKey: selectedKey) }
    }
}
