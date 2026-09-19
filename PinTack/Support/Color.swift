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

/// The six preset note colors from the prototype. SPEC.md §5.3.
enum NotePalette {
    static let presets: [(name: String, hex: String)] = [
        ("Butter",   "#FFE38A"),
        ("Peach",    "#FFBA94"),
        ("Mint",     "#A8EBC8"),
        ("Sky",      "#A3D5FF"),
        ("Lilac",    "#CEB8FF"),
        ("Graphite", "#2C2C32"),
    ]
}
