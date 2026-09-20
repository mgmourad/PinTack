import AppKit

extension NSColor {

    convenience init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((v >> 16) & 0xFF) / 255.0,
                  green:   CGFloat((v >> 8) & 0xFF) / 255.0,
                  blue:    CGFloat(v & 0xFF) / 255.0,
                  alpha:   1.0)
    }

    var hexString: String {
        guard let c = usingColorSpace(.sRGB) else { return "#FF9F0A" }
        return String(format: "#%02X%02X%02X",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()))
    }

    /// WCAG relative luminance, used to decide light vs dark text. SPEC.md §9.
    var relativeLuminance: CGFloat {
        guard let c = usingColorSpace(.sRGB) else { return 1 }
        func lin(_ v: CGFloat) -> CGFloat {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent)
             + 0.7152 * lin(c.greenComponent)
             + 0.0722 * lin(c.blueComponent)
    }

    /// CSS `rgba()` string for handing colors to the editor webview.
    func css(alpha: CGFloat? = nil) -> String {
        guard let c = usingColorSpace(.sRGB) else { return "#000" }
        let a = alpha ?? c.alphaComponent
        return String(format: "rgba(%d, %d, %d, %.3f)",
                      Int((c.redComponent * 255).rounded()),
                      Int((c.greenComponent * 255).rounded()),
                      Int((c.blueComponent * 255).rounded()), a)
    }
}

/// Note color presets, in three modes. SPEC.md §5.3.
///
/// A note's `theme` is its palette mode: `auto` is the standard set, `dark` swaps
/// the swatches for deeper versions and `light` for paler ones. Text color is NEVER a
/// user choice: it always flips light/dark from the background's luminance, so no
/// color can be unreadable. The mode only changes which swatches are offered.
enum NotePalette {

    typealias Swatch = (name: String, hex: String)

    static let auto: [Swatch] = [
        ("Butter",   "#FFE38A"),
        ("Peach",    "#FFBA94"),
        ("Mint",     "#A8EBC8"),
        ("Sky",      "#A3D5FF"),
        ("Lilac",    "#CEB8FF"),
        ("Graphite", "#2C2C32"),
    ]

    static let light: [Swatch] = [
        ("Butter",   "#FFF1B8"),
        ("Peach",    "#FFD9C4"),
        ("Mint",     "#D4F5E3"),
        ("Sky",      "#D2E9FF"),
        ("Lilac",    "#E6DBFF"),
        ("Cloud",    "#F5F5F7"),
    ]

    static let dark: [Swatch] = [
        ("Butter",   "#A88418"),
        ("Peach",    "#B8623C"),
        ("Mint",     "#2E7D5B"),
        ("Sky",      "#2F62A3"),
        ("Lilac",    "#6B4FB0"),
        ("Graphite", "#1F1F24"),
    ]

    /// The standard set, used by Settings and the menu.
    static var presets: [Swatch] { auto }

    static func set(for mode: String) -> [Swatch] {
        switch mode {
        case "dark":  return dark
        case "light": return light
        default:      return auto
        }
    }

    /// Switching mode carries a preset color across to the same-named swatch in the new
    /// set, so pressing Dark actually darkens a Butter note. A custom color is left alone.
    static func remap(_ hex: String, toMode mode: String) -> String? {
        for source in [auto, light, dark] {
            if let i = source.firstIndex(where: { $0.hex.caseInsensitiveCompare(hex) == .orderedSame }) {
                return set(for: mode)[i].hex
            }
        }
        return nil
    }

    private static var lastHue: Double?

    /// A random pastel: any hue on the wheel, fixed soft saturation and high brightness (so the
    /// automatic text color is always dark and readable). Consecutive notes are forced at least
    /// 60° apart on the color wheel, so you never get two near-identical notes in a row, which a
    /// pick from five fixed colors did constantly.
    static var randomPastel: String {
        var hue = Double.random(in: 0..<1)
        if let last = lastHue {
            var tries = 0
            while tries < 20, min(abs(hue - last), 1 - abs(hue - last)) < 60.0 / 360.0 {
                hue = Double.random(in: 0..<1); tries += 1
            }
        }
        lastHue = hue
        var saturation = Double.random(in: 0.28...0.42)
        let brightness = Double.random(in: 0.94...1.0)
        var color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        // Blues and purples are darker at the same saturation. Wash them out until the note takes
        // dark text (luminance above the 0.45 rule in Note.isDarkText), so a random note is never
        // white text on a mid-tone.
        while color.relativeLuminance < 0.5 && saturation > 0.08 {
            saturation *= 0.88
            color = NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1)
        }
        return color.hexString
    }
}

/// PinTack's own accent for its app chrome (Settings, All Notes, popovers). Deliberately NOT the
/// user's note-outline color: choosing a dark outline used to turn labels and buttons in Settings
/// dark red on a dark window. Orange reads on both light and dark windows.
enum Brand {
    static let accentNS = NSColor(srgbRed: 1.0, green: 0.62, blue: 0.04, alpha: 1)      // #FF9F0A
}
